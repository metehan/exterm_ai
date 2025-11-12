defmodule Exterm.Llm.Chat do
  @moduledoc """
  GenServer that manages chat sessions with LLM providers, maintaining conversation history
  and providing stateful chat interactions.
  """

  use GenServer
  alias Exterm.Llm.ReqClient, as: LLMClient
  alias Exterm.Llm.Tools
  alias Exterm.Llm.ChatLogger

  @default_provider :openrouter

  # Client API

  @doc """
  Starts a new chat server with optional configuration.

  ## Options
    - `:provider` - LLM provider (:groq, :deepinfra, :openrouter)
    - `:model` - Model to use, defaults to provider's default
    - `:temperature` - Sampling temperature, default: 0.7
    - `:max_tokens` - Max tokens in response, default: 2048
    - `:system_prompt` - Initial system message
    - `:tools` - List of available tools for function calling
    - `:chat_socket_pid` - PID of the chat socket for tool context
    - `:name` - Process name for registration
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a message to the chat and returns the response while maintaining conversation history.
  """
  def chat(server, message) when is_binary(message) do
    # Increased to 2 minutes for complex tool chains
    GenServer.call(server, {:chat, message}, 120_000)
  end

  @doc """
  Streams a chat response, returning a stream of chunks while maintaining conversation history.
  """
  def stream_chat(server, message) when is_binary(message) do
    # Increased to 2 minutes
    GenServer.call(server, {:stream_chat, message}, 120_000)
  end

  @doc """
  Streams a continuation response using existing conversation context without adding to history.
  """
  def stream_continuation(server, prompt) when is_binary(prompt) do
    GenServer.call(server, {:stream_continuation, prompt}, 120_000)
  end

  @doc """
  Gets the current conversation history.
  """
  def get_history(server) do
    GenServer.call(server, :get_history)
  end

  @doc """
  Clears the conversation history.
  """
  def clear_history(server) do
    GenServer.cast(server, :clear_history)
  end

  @doc """
  Adds a system message to the conversation.
  """
  def add_system_message(server, content) when is_binary(content) do
    GenServer.call(server, {:add_system_message, content})
  end

  @doc """
  Adds a message with specified role to the conversation.
  """
  def add_role_message(server, role, content) when is_binary(role) and is_binary(content) do
    GenServer.call(server, {:add_role_message, role, content})
  end

  @doc """
  Handle an assistant message that may contain tool calls.
  This is used for streaming mode where the assistant message with tool calls
  needs to be processed after streaming is complete.
  """
  def handle_assistant_with_tools(pid, assistant_message, opts \\ []) do
    GenServer.call(pid, {:handle_assistant_with_tools, assistant_message, opts}, 60_000)
  end

  @doc """
  Updates the chat configuration.
  """
  def update_config(server, opts) when is_list(opts) do
    GenServer.call(server, {:update_config, opts})
  end

  @doc """
  Gets the current chat configuration.
  """
  def get_config(server) do
    GenServer.call(server, :get_config)
  end

  @doc """
  Exports the conversation history as a list of messages.
  """
  def export_conversation(server) do
    GenServer.call(server, :export_conversation)
  end

  @doc """
  Imports a conversation history from a list of messages.
  """
  def import_conversation(server, messages) when is_list(messages) do
    GenServer.call(server, {:import_conversation, messages})
  end

  # Server Implementation

  @impl true
  def init(opts) do
    provider = Keyword.get(opts, :provider, @default_provider)
    system_prompt = Keyword.get(opts, :system_prompt)
    tools = Keyword.get(opts, :tools, [])
    chat_socket_pid = Keyword.get(opts, :chat_socket_pid)

    initial_messages =
      if system_prompt do
        [%{role: "system", content: system_prompt}]
      else
        []
      end

    state = %{
      provider: provider,
      messages: initial_messages,
      tools: tools,
      chat_socket_pid: chat_socket_pid,
      last_activity: DateTime.utc_now(),
      config: opts |> Keyword.drop([:provider, :system_prompt, :tools, :chat_socket_pid]),
      session_id: generate_session_id()
    }

    # Log session start
    ChatLogger.log_chat_event(state.session_id, :session_start, %{
      provider: provider,
      tools: length(tools),
      system_prompt: if(system_prompt, do: String.slice(system_prompt, 0, 100), else: nil),
      config: config_to_map(state.config)
    })

    {:ok, state}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Helper to convert config keyword list to a JSON-safe map
  defp config_to_map(config) do
    config
    |> Enum.into(%{})
    |> Enum.map(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
    |> Enum.into(%{})
  end

  @impl true
  def handle_call({:chat, message}, _from, state) do
    # Send thinking status when starting to process user message
    GenServer.cast(state.chat_socket_pid, {:send_ai_status, "thinking"})

    state = add_message(state, "user", message)

    # Add tools to the request if available
    opts = [previous_messages: state.messages] ++ state.config

    opts =
      if is_list(state.tools) and length(state.tools) > 0 do
        Keyword.put(opts, :functions, state.tools)
      else
        opts
      end

    case LLMClient.chat(state.provider, message, opts) do
      %{"choices" => [%{"message" => assistant_message} | _]} = _response ->
        case handle_assistant_message(assistant_message, state) do
          {:ok, final_content, new_state} ->
            {:reply, {:ok, final_content}, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end

      error ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:stream_chat, message}, _from, state) do
    state = add_message(state, "user", message)

    # Add tools to the request if available (same as regular chat)
    opts = [previous_messages: state.messages] ++ state.config

    opts =
      if is_list(state.tools) and length(state.tools) > 0 do
        Keyword.put(opts, :functions, state.tools)
      else
        opts
      end

    try do
      stream = LLMClient.stream_chat(state.provider, message, opts)
      {:reply, {:ok, stream}, state}
    rescue
      error ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:stream_continuation, prompt}, _from, state) do
    # Stream continuation by sending the continuation prompt directly
    # The tool results should already be in the conversation history

    ChatLogger.log_continuation_attempt(state.session_id, prompt, length(state.messages))
    ChatLogger.log_message_history(state.session_id, state.messages)

    IO.puts("Chat: Stream continuation called with prompt: #{prompt}")
    IO.puts("Chat: Current message history length: #{length(state.messages)}")

    # Show last few messages for debugging
    last_messages = Enum.take(state.messages, -3)
    IO.puts("Chat: Last messages: #{inspect(last_messages, limit: :infinity)}")

    opts = [previous_messages: state.messages] ++ state.config

    # Don't include tools for continuation since we're just analyzing previous results
    try do
      ChatLogger.log_stream_event(state.session_id, "continuation", "request_start", %{
        # Full prompt, no truncation!
        prompt: prompt,
        options: config_to_map(opts |> Keyword.drop([:previous_messages])),
        message_count: length(state.messages)
      })

      stream = LLMClient.stream_chat(state.provider, prompt, opts)

      ChatLogger.log_stream_event(state.session_id, "continuation", "request_success")
      {:reply, {:ok, stream}, state}
    rescue
      error ->
        ChatLogger.log_stream_event(state.session_id, "continuation", "request_error", %{
          error: inspect(error)
        })

        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call({:add_system_message, content}, _from, state) do
    state = add_message(state, "system", content)
    state = update_activity(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_role_message, role, content}, _from, state) do
    state = add_message(state, role, content)
    state = update_activity(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:handle_assistant_with_tools, assistant_message, opts}, _from, state) do
    streaming_mode = Keyword.get(opts, :streaming, false)

    case handle_assistant_message(assistant_message, state, streaming_mode) do
      {:ok, content, new_state} ->
        {:reply, {:ok, content}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:update_config, opts}, _from, state) do
    state =
      Enum.reduce(opts, state, fn
        {:provider, provider}, acc -> %{acc | provider: provider}
        {:model, model}, acc -> %{acc | model: model}
        {:temperature, temp}, acc -> %{acc | temperature: temp}
        {:max_tokens, tokens}, acc -> %{acc | max_tokens: tokens}
        _, acc -> acc
      end)

    state = update_activity(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    config = %{
      provider: state.provider,
      model: Keyword.get(state.config, :model),
      temperature: Keyword.get(state.config, :temperature, 0.7),
      max_tokens: Keyword.get(state.config, :max_tokens, 2048),
      created_at: Map.get(state, :created_at),
      last_activity: state.last_activity,
      message_count: length(state.messages)
    }

    {:reply, config, state}
  end

  @impl true
  def handle_call(:get_model, _from, state) do
    model = Keyword.get(state.config, :model, "#{state.provider} default")

    IO.puts(
      "ChatSocket: get_model returning: #{inspect(model)} from config: #{inspect(state.config)}"
    )

    {:reply, {:ok, model}, state}
  end

  @impl true
  def handle_call(:export_conversation, _from, state) do
    conversation = %{
      messages: state.messages,
      config: %{
        provider: state.provider,
        model: state.model,
        temperature: state.temperature,
        max_tokens: state.max_tokens
      },
      metadata: %{
        created_at: state.created_at,
        last_activity: state.last_activity,
        message_count: length(state.messages)
      }
    }

    {:reply, conversation, state}
  end

  @impl true
  def handle_call({:import_conversation, messages}, _from, state) do
    # Validate messages format
    valid_messages =
      Enum.filter(messages, fn
        %{role: role, content: content}
        when role in ["system", "user", "assistant"] and is_binary(content) ->
          true

        _ ->
          false
      end)

    state = %{state | messages: valid_messages, last_activity: DateTime.utc_now()}
    {:reply, {:ok, length(valid_messages)}, state}
  end

  @impl true
  def handle_cast(:clear_history, state) do
    {:noreply, %{state | messages: []}}
  end

  # Helper functions

  defp handle_assistant_message(
         assistant_message,
         state,
         streaming_mode \\ false
       ) do
    # Check if the assistant message has function calls
    case Map.get(assistant_message, "tool_calls") do
      nil ->
        # No function calls, just add the regular message
        content = Map.get(assistant_message, "content", "")
        new_state = add_message(state, "assistant", content)

        # Send ready status when completing response
        GenServer.cast(state.chat_socket_pid, {:send_ai_status, "ready"})

        {:ok, content, new_state}

      tool_calls when is_list(tool_calls) ->
        # Handle function calls
        handle_function_calls(assistant_message, tool_calls, state, streaming_mode)
    end
  end

  defp handle_function_calls(assistant_message, tool_calls, state, streaming_mode) do
    # Add the assistant message with tool calls to history
    # For tool calls, content should be string (can be empty) and include tool_calls
    assistant_msg = %{
      role: "assistant",
      content: Map.get(assistant_message, "content", ""),
      tool_calls: tool_calls
    }

    state = %{state | messages: state.messages ++ [assistant_msg]}

    # Send tool usage notification to chat
    tool_names =
      Enum.map(tool_calls, fn tool_call ->
        get_in(tool_call, ["function", "name"])
      end)

    tool_summary =
      case length(tool_names) do
        1 ->
          tool_call = hd(tool_calls)
          tool_name = get_in(tool_call, ["function", "name"])
          generate_friendly_tool_summary(tool_name, tool_call)

        n ->
          "Using #{n} tools: #{Enum.join(tool_names, ", ")}"
      end

    send_tool_usage_message(state.chat_socket_pid, tool_summary, tool_calls)

    # Send AI status update to indicate working
    GenServer.cast(state.chat_socket_pid, {:send_ai_status, "working"})

    # Don't send a thinking message - let the AI respond directly with results

    # Execute each tool call
    tool_results =
      Enum.map(tool_calls, fn tool_call ->
        tool_name = get_in(tool_call, ["function", "name"])

        IO.puts(
          "Chat: Starting tool execution: #{tool_name} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
        )

        start_time = System.monotonic_time(:millisecond)
        result = execute_tool_call(tool_call, state)
        execution_time = System.monotonic_time(:millisecond) - start_time

        IO.puts("Chat: Tool #{tool_name} execution completed in #{execution_time}ms")

        # Send tool result notification
        send_start_time = System.monotonic_time(:millisecond)
        send_tool_result_message(state.chat_socket_pid, tool_name, tool_call, result)
        send_time = System.monotonic_time(:millisecond) - send_start_time

        IO.puts("Chat: Tool result sent in #{send_time}ms")

        result
      end)

    # Add tool results to messages
    state =
      Enum.reduce(tool_results, state, fn result, acc_state ->
        # Use the result directly - it's already in the correct format
        %{acc_state | messages: acc_state.messages ++ [result]}
      end)

    # Process tool results and potentially continue with more autonomous actions
    GenServer.cast(state.chat_socket_pid, {:send_ai_status, "thinking"})

    # In streaming mode, skip the continuation call to avoid blocking
    # Instead, notify the chat socket to handle continuation streaming
    IO.puts("Chat: Checking streaming_mode: #{streaming_mode}")

    if streaming_mode do
      IO.puts("Chat: Entering streaming mode branch")
      # For streaming mode, don't send additional messages since tools send their own
      # Just process tool results for internal state but don't send to UI
      _response_content = process_tool_results(tool_results, state)

      # Create continuation prompt for the chat socket to stream
      # Instead of a complex prompt, use a simple continuation instruction
      # The tool results are already in the conversation history

      continuation_prompt = """
      Please analyze the tool results above and provide a comprehensive answer to the user's question. If search results are not enough to provide correct data continue using tools as needed.
      """

      # Debug logging
      IO.puts(
        "Chat: Starting continuation stream - chat_socket_pid: #{inspect(state.chat_socket_pid)}"
      )

      IO.puts("Chat: Continuation prompt: #{continuation_prompt}")

      # Send message to chat socket to start a continuation stream
      IO.puts(
        "Chat: Sending :start_continuation_stream message to #{inspect(state.chat_socket_pid)}"
      )

      IO.puts("Chat: Process exists? #{Process.alive?(state.chat_socket_pid)}")
      send(state.chat_socket_pid, {:start_continuation_stream, continuation_prompt})
      IO.puts("Chat: Message sent successfully")

      final_state = add_message(state, "assistant", "")
      {:ok, "", final_state}
    else
      # Make a follow-up LLM call with tools enabled to continue autonomously
      # Add a prompt that encourages the AI to continue if the user's request isn't fully satisfied
      continuation_prompt = """
      Based on the tool results above, continue to fully answer the user's original question. 
      If the user asked for file contents or analysis and you only listed files, read those files now.
      If the user asked for analysis and you only read files, provide that analysis now.
      Continue taking actions until you've completely fulfilled the user's request.

      Original user request: #{get_last_user_message(state)}
      """

      opts = [previous_messages: state.messages] ++ state.config

      # Re-enable tools for autonomous continuation
      opts =
        if is_list(state.tools) and length(state.tools) > 0 do
          Keyword.put(opts, :functions, state.tools)
        else
          opts
        end

      case LLMClient.chat(state.provider, continuation_prompt, opts) do
        %{"choices" => [%{"message" => continuation_message} | _]} ->
          # Handle the continuation response (might include more tool calls)
          case handle_assistant_message(continuation_message, state) do
            {:ok, final_content, new_state} ->
              {:ok, final_content, new_state}

            {:error, reason, new_state} ->
              {:error, reason, new_state}
          end

        _error ->
          # Fallback: just process the tool results directly
          response_content = process_tool_results(tool_results, state)

          if state.chat_socket_pid and response_content != "" do
            # Get model name for display
            model_name = Keyword.get(state.config, :model, "#{state.provider} default")

            ai_message = %{
              type: "ai_message",
              content: response_content,
              model: format_model_name(model_name),
              timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            send(state.chat_socket_pid, {:send_message, ai_message})
          end

          final_state = add_message(state, "assistant", response_content)
          GenServer.cast(state.chat_socket_pid, {:send_ai_status, "ready"})
          {:ok, response_content, final_state}
      end
    end
  end

  # Format model names for better display
  defp format_model_name(model) when is_binary(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_model_name(_), do: "AI"

  defp execute_tool_call(tool_call, state) do
    function = get_in(tool_call, ["function"])
    function_name = get_in(function, ["name"])
    arguments_json = get_in(function, ["arguments"])

    IO.puts("Chat: execute_tool_call started for #{function_name}")

    case Jason.decode(arguments_json || "{}") do
      {:ok, arguments} ->
        IO.puts("Chat: JSON decode successful, calling Tools.execute_tool")
        tool_start = System.monotonic_time(:millisecond)

        # Execute the tool with the chat socket PID for context
        # For summarize_chat, pass the conversation state directly to avoid deadlock
        result =
          case function_name do
            "summarize_chat" ->
              Tools.execute_tool(function_name, arguments, state.chat_socket_pid, state.messages)

            _ ->
              Tools.execute_tool(function_name, arguments, state.chat_socket_pid)
          end

        tool_time = System.monotonic_time(:millisecond) - tool_start
        IO.puts("Chat: Tools.execute_tool completed in #{tool_time}ms")

        json_start = System.monotonic_time(:millisecond)
        json_result = Jason.encode!(result)
        json_time = System.monotonic_time(:millisecond) - json_start

        IO.puts(
          "Chat: JSON encoding completed in #{json_time}ms, result size: #{String.length(json_result)} chars"
        )

        %{
          role: "tool",
          tool_call_id: Map.get(tool_call, "id"),
          content: json_result
        }

      {:error, _} ->
        IO.puts("Chat: JSON decode failed for arguments")

        %{
          role: "tool",
          tool_call_id: Map.get(tool_call, "id"),
          content: Jason.encode!(%{"error" => "Invalid function arguments"})
        }
    end
  end

  # Helper functions

  defp process_tool_results(tool_results, _state) do
    # Extract and format tool results into a meaningful response
    results_summary =
      Enum.map(tool_results, fn result ->
        case Jason.decode(result.content) do
          {:ok, decoded_result} ->
            format_tool_result(decoded_result)

          {:error, _} ->
            "Tool execution completed with: #{result.content}"
        end
      end)
      |> Enum.join("\n\n")

    if String.trim(results_summary) == "" do
      "I've completed the requested action."
    else
      results_summary
    end
  end

  defp format_tool_result(result) when is_map(result) do
    cond do
      # Handle file listing results
      Map.has_key?(result, "files") ->
        files = Map.get(result, "files", [])

        if Enum.empty?(files) do
          "No files found."
        else
          file_list =
            Enum.map(files, fn file ->
              case file do
                %{"name" => name, "size" => size, "modified" => modified} ->
                  "- #{name} (#{size} bytes, modified: #{modified})"

                %{"name" => name} ->
                  "- #{name}"

                name when is_binary(name) ->
                  "- #{name}"

                _ ->
                  "- #{inspect(file)}"
              end
            end)
            |> Enum.join("\n")

          "Found #{length(files)} file(s):\n#{file_list}"
        end

      # Handle command execution results  
      Map.has_key?(result, "output") ->
        output = Map.get(result, "output", "")

        if String.trim(output) == "" do
          "Command executed successfully (no output)."
        else
          "Command output:\n```\n#{output}\n```"
        end

      # Handle file content results
      Map.has_key?(result, "content") ->
        content = Map.get(result, "content", "")

        if String.length(content) > 500 do
          preview = String.slice(content, 0, 500)
          "File content (showing first 500 characters):\n```\n#{preview}...\n```"
        else
          "File content:\n```\n#{content}\n```"
        end

      # Handle error results
      Map.has_key?(result, "error") ->
        "Error: #{Map.get(result, "error")}"

      # Handle general success/status messages
      Map.has_key?(result, "message") ->
        Map.get(result, "message")

      # Default: try to show the result as is
      true ->
        case Jason.encode(result) do
          {:ok, json} -> "Result: #{json}"
          {:error, _} -> "Tool completed successfully."
        end
    end
  end

  defp format_tool_result(result) when is_binary(result) do
    if String.trim(result) == "" do
      "Operation completed successfully."
    else
      result
    end
  end

  defp format_tool_result(result) do
    "Result: #{inspect(result)}"
  end

  defp get_last_user_message(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == "user" end)
    |> case do
      %{content: content} -> content
      _ -> "the previous request"
    end
  end

  defp add_message(state, role, content) do
    message = %{role: role, content: content}
    %{state | messages: state.messages ++ [message]}
  end

  defp update_activity(state) do
    Map.put(state, :last_activity, DateTime.utc_now())
  end

  defp send_tool_usage_message(chat_socket_pid, summary, tool_calls) do
    if chat_socket_pid do
      message = %{
        type: "tool_usage",
        content: summary,
        tool_calls: tool_calls,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      send(chat_socket_pid, {:send_message, message})
    end
  end

  defp send_tool_result_message(chat_socket_pid, tool_name, tool_call, result) do
    if chat_socket_pid do
      message = %{
        type: "tool_result",
        tool_name: tool_name,
        tool_call: tool_call,
        result: result,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      send(chat_socket_pid, {:send_message, message})
    end
  end

  # Generate user-friendly tool summary messages
  defp generate_friendly_tool_summary(tool_name, tool_call) do
    case tool_name do
      "browse_web" ->
        url =
          get_in(tool_call, ["function", "arguments"])
          |> Jason.decode!()
          |> Map.get("url", "a web page")

        domain =
          if String.contains?(url, ".") do
            try do
              uri =
                URI.parse(if String.starts_with?(url, "http"), do: url, else: "https://#{url}")

              uri.host || url
            rescue
              _ -> url
            end
          else
            url
          end

        "Browsing web: #{domain}..."

      "search_web" ->
        query =
          get_in(tool_call, ["function", "arguments"])
          |> Jason.decode!()
          |> Map.get("query", "information")

        "Searching web for \"#{query}\"..."

      _ ->
        "Using #{tool_name} tool"
    end
  end

  # Handle metadata task messages from ReqLLM.StreamResponse
  @impl true
  def handle_info({_ref, %{status: _status, usage: _usage, headers: _headers}}, state) do
    # This is the metadata result from ReqLLM's async metadata_task
    # We can safely ignore it or log it if needed
    {:noreply, state}
  end

  # Handle DOWN message when metadata task completes
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    # Metadata task finished normally, ignore
    {:noreply, state}
  end

  # Catch-all for any other unexpected messages
  @impl true
  def handle_info(msg, state) do
    IO.puts("Chat: Ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
