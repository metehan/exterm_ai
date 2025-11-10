defmodule Exterm.ChatSocket do
  @moduledoc """
  WebSocket handler for chat functionality. Manages WebSocket connections
  and integrates with chat GenServer to provide AI assistance.
  Supports multiple concurrent AI chat sessions.
  """

  @behaviour :cowboy_websocket
  alias Exterm.Llm.{Chat, Tools, ChatLogger}
  alias Exterm.AppState

  def init(request, _state) do
    {:cowboy_websocket, request, %{}}
  end

  def websocket_init(_state) do
    # Generate unique session ID for this chat session
    session_id = generate_session_id()

    # Get current system information for context
    current_date = Date.utc_today() |> Date.to_iso8601()
    current_datetime = DateTime.utc_now() |> DateTime.to_iso8601()
    {os_family, os_name} = :os.type()
    system_arch = :erlang.system_info(:system_architecture) |> to_string()

    # Start a new chat session for this WebSocket connection with helpful system prompt
    system_prompt = """
    You are a helpful AI terminal assistant. You provide guidance and assistance to users working in their terminal environment.

    CURRENT CONTEXT:
    - Date: #{current_date}
    - Time: #{current_datetime}
    - Operating System: #{os_name} (#{os_family})
    - Architecture: #{system_arch}
    - Session ID: #{session_id}

    CORE MISSION: Help users understand their terminal, analyze outputs, and provide guidance when requested.

    BEHAVIOR GUIDELINES:
    - OBSERVE and ANALYZE terminal output when asked about it
    - EXPLAIN what's happening in the terminal when requested
    - SUGGEST helpful next steps when appropriate
    - PROVIDE information about files, processes, and system state
    - ASK for clarification before making major changes
    - RESPECT user intent and don't assume too much

    YOUR TOOLS:
    TERMINAL TOOLS:
    - read_terminal: Monitor current output and command history
    - send_to_terminal: Execute commands directly (use carefully!)
      * For fast commands (ls, docker images, ps, etc.), use sleep_seconds: 0.3 for quick results
      * For slow commands (compilation, downloads, etc.), use sleep_seconds: 2-5 as needed
      * Default sleep_seconds is 1.5 - adjust based on expected command speed
    - sleep: Wait for processes to complete
    - suggest_terminal_command: Suggest commands for approval
    - get_terminal_history: Analyze command patterns

    FILE TOOLS:
    - create_file: Create new files with content
    - read_file: Read and analyze file content  
    - update_file: Replace entire file content (ask first!)
    - append_to_file: Add content to files
    - delete_file: Remove files (ask first!)
    - edit_lines: Edit specific line ranges
    - list_files: Explore directory structure

    WEB BROWSING TOOLS:
    - search_web: Search the internet using DuckDuckGo (ALWAYS use this first before browsing!)
    - browse_web: Browse specific web pages (only use with confirmed URLs from search results)

    CHAT MANAGEMENT TOOLS:
    - summarize_chat: Summarize conversation history when switching topics or when chat becomes long
      * Use when user asks about something completely different from current conversation
      * Use when conversation has many topics and becomes hard to follow
      * Use "topic_change" reason when user switches to unrelated topic
      * Use "user_request" reason when user explicitly asks for summary
      * This helps maintain context while keeping conversation focused

    WEB BROWSING GUIDELINES:
    - ONLY search the web when users explicitly ask for current/recent information, specific websites, or news
    - For general knowledge questions (planets, science, history), use your existing knowledge first
    - NEVER guess or make up URLs - only browse URLs from search results or links in pages you visit
    - Make sure you are using well thought search queries to minimize irrelevant results
    - When user asks about a website/topic, search first, then browse the most relevant results
    - Refrain visiting more than five links in a single session to avoid going down rabbit holes
    - Use search_web to find current, existing content rather than assuming URLs exist
    - Follow links from search results to get accurate, up-to-date information

    WORKFLOW:
    1. LISTEN to what the user is asking for
    2. ANALYZE the situation if needed
    3. CONSIDER: If user is switching to a completely different topic, use summarize_chat first
    4. For web-related requests OR current information: SEARCH FIRST with search_web, then browse specific results
    5. For general knowledge: Use your existing knowledge and only search if asked for recent updates
    6. EXPLAIN what you found
    7. SUGGEST or ASK before taking major actions
    8. HELP the user achieve their goals step by step

    TOPIC MANAGEMENT:
    - If user asks about something unrelated to current conversation, consider summarizing first
    - Examples: switching from coding help to sports questions, from file work to web research
    - Use summarize_chat with reason="topic_change" to maintain context while focusing on new topic
    - Don't over-summarize - only when there's a clear topic shift

    NEVER:
    - Browse URLs without searching first (unless user provides a specific, confirmed URL)
    - Make up or guess website URLs
    - Assume websites exist without checking
    - Make files changes without clear user intent
    - Execute commands that could be destructive without asking
    - Assume complex workflows from simple requests
    - Work autonomously on tasks unless explicitly asked

    ALWAYS:
    - Search the web first before browsing specific sites
    - Use confirmed URLs from search results only
    - Explain what you're doing and why
    - Ask for confirmation on significant actions
    - Provide helpful information and context
    - Respect the user's working environment
    - Focus on being helpful, not autonomous

    REMEMBER: You are an assistant, not an autonomous agent. Help the user accomplish their goals with their guidance!
    """

    IO.puts("ChatSocket: Starting chat for session #{session_id} with system prompt and tools")

    # Check if AI is globally stopped first
    if AppState.ai_globally_stopped?() do
      error_msg = %{
        type: "error",
        content: "AI is globally stopped.",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        session_id: session_id
      }

      {:reply, {:text, Poison.encode!(error_msg)}, %{session_id: session_id, chat_pid: nil}}
    else
      case Chat.start_link(
             system_prompt: system_prompt,
             provider: :openrouter,
             model: System.get_env("LLM_MODEL") || "minimax/minimax-m2",
             tools: Tools.get_tools(),
             chat_socket_pid: self()
           ) do
        {:ok, chat_pid} ->
          IO.puts(
            "ChatSocket: Chat GenServer started successfully for session #{session_id}: #{inspect(chat_pid)}"
          )

          # Register this session in AppState
          AppState.create_ai_session(session_id, chat_pid, self())

          # Set up a heartbeat timer to keep connection alive (every 30 seconds)
          :timer.send_interval(30_000, self(), :heartbeat)

          # Check if API keys are configured
          api_key_status = check_api_keys()

          # Get system information
          current_date = Date.utc_today() |> Date.to_iso8601()
          current_time = DateTime.utc_now() |> DateTime.to_iso8601()
          {os_family, os_name} = :os.type()
          system_arch = :erlang.system_info(:system_architecture) |> to_string()

          # Send initial welcome message
          welcome_msg =
            case api_key_status do
              :ok ->
                %{
                  type: "system",
                  content:
                    "Chat system connected! I'm your AI assistant for session #{session_id}. I can help you with terminal commands and system administration.\n\n" <>
                      "**System Information:**\n" <>
                      "- Current Date: #{current_date}\n" <>
                      "- Current Time: #{current_time}\n" <>
                      "- Operating System: #{os_name} (#{os_family})\n" <>
                      "- Architecture: #{system_arch}\n" <>
                      "- Session ID: #{session_id}\n" <>
                      "- Elixir Terminal Environment: Ready for commands and assistance",
                  timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                  session_id: session_id
                }

              {:warning, message} ->
                %{
                  type: "system",
                  content: "Chat system connected with warnings: #{message}",
                  timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                  session_id: session_id
                }
            end

          IO.puts(
            "ChatSocket: Sending welcome message for session #{session_id}: #{inspect(welcome_msg)}"
          )

          {:reply, {:text, Poison.encode!(welcome_msg)},
           %{session_id: session_id, chat_pid: chat_pid}}

        {:error, reason} ->
          IO.puts(
            "ChatSocket: Failed to start chat GenServer for session #{session_id}: #{inspect(reason)}"
          )

          error_msg = %{
            type: "error",
            content: "Failed to initialize chat system: #{inspect(reason)}",
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
            session_id: session_id
          }

          {:reply, {:text, Poison.encode!(error_msg)}, %{session_id: session_id, chat_pid: nil}}
      end
    end
  end

  # Generate unique session ID
  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
    |> then(fn id -> "chat_#{id}" end)
  end

  def websocket_handle({:text, msg}, state) do
    session_id = state.session_id
    IO.puts("ChatSocket[#{session_id}]: Received WebSocket message: #{inspect(msg)}")

    case Poison.decode(msg) do
      {:ok, %{"type" => "chat_message", "content" => content}} when is_binary(content) ->
        IO.puts(
          "ChatSocket[#{session_id}]: Decoded chat_message with content: #{inspect(content)}"
        )

        handle_chat_message(content, state)

      {:ok, %{"type" => "ping"}} ->
        IO.puts("ChatSocket[#{session_id}]: Received ping")

        pong_msg = %{
          type: "pong",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          session_id: session_id
        }

        {:reply, {:text, Poison.encode!(pong_msg)}, state}

      {:ok, %{"type" => "clear_history"}} ->
        IO.puts("ChatSocket: Received clear_history")
        handle_clear_history(state)

      {:ok, %{"type" => "stop_ai"}} ->
        IO.puts("ChatSocket: Received stop_ai request")
        handle_stop_ai(state)

      {:ok, %{"type" => "start_ai"}} ->
        IO.puts("ChatSocket: Received start_ai request")
        handle_start_ai(state)

      {:error, reason} ->
        IO.puts(
          "ChatSocket: JSON decode error: #{inspect(reason)}, treating as plain text: #{inspect(msg)}"
        )

        # Handle plain text as chat message (backward compatibility)
        if String.trim(msg) != "" do
          handle_chat_message(String.trim(msg), state)
        else
          {:ok, state}
        end

      {:ok, unknown} ->
        IO.puts("ChatSocket: Unknown message type: #{inspect(unknown)}")

        error_msg = %{
          type: "error",
          content: "Unknown message type",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:reply, {:text, Poison.encode!(error_msg)}, state}
    end
  end

  def websocket_handle({:binary, _msg}, state) do
    # We don't handle binary messages for chat
    {:ok, state}
  end

  def websocket_handle({:pong, _data}, state) do
    {:ok, state}
  end

  def websocket_handle(_data, state) do
    {:ok, state}
  end

  def websocket_info(:heartbeat, state) do
    # Send a ping frame to keep the connection alive
    {:reply, {:ping, ""}, state}
  end

  def websocket_info({:chat_response, response}, state) do
    start_time = System.monotonic_time(:millisecond)
    current_time = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("ChatSocket[#{current_time}]: Received chat_response: #{inspect(response)}")

    # Get model information from the chat process
    model_name =
      case state.chat_pid do
        nil ->
          "AI"

        chat_pid ->
          try do
            # Get the model from the chat state
            case GenServer.call(chat_pid, :get_model) do
              {:ok, model} -> format_model_name(model)
              _ -> "AI"
            end
          catch
            :exit, _ -> "AI"
          end
      end

    # Handle response from the chat GenServer
    msg = %{
      type: "ai_message",
      content: response,
      model: model_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    process_time = System.monotonic_time(:millisecond) - start_time

    IO.puts(
      "ChatSocket[#{DateTime.utc_now() |> DateTime.to_iso8601()}]: Sending ai_message to frontend (processed in #{process_time}ms): #{inspect(msg)}"
    )

    {:reply, {:text, Poison.encode!(msg)}, state}
  end

  def websocket_info({:send_message, message}, state) do
    start_time = System.monotonic_time(:millisecond)
    current_time = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("ChatSocket[#{current_time}]: Sending tool message: #{inspect(message)}")

    encode_time = System.monotonic_time(:millisecond) - start_time

    IO.puts(
      "ChatSocket[#{DateTime.utc_now() |> DateTime.to_iso8601()}]: Message encoded and sent in #{encode_time}ms"
    )

    {:reply, {:text, Poison.encode!(message)}, state}
  end

  def websocket_info({:send_ai_status, status}, state) do
    current_time = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("ChatSocket[#{current_time}]: Sending AI status update: #{status}")
    msg = %{type: "ai_status", status: status}
    {:reply, {:text, Poison.encode!(msg)}, state}
  end

  def websocket_info({:stream_start, data}, state) do
    current_time = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("ChatSocket[#{current_time}]: Stream started: #{inspect(data)}")

    # Get model information from the chat process
    model_name =
      case state.chat_pid do
        nil ->
          "AI"

        chat_pid ->
          try do
            # Get the model from the chat state
            case GenServer.call(chat_pid, :get_model) do
              {:ok, model} -> format_model_name(model)
              _ -> "AI"
            end
          catch
            :exit, _ -> "AI"
          end
      end

    msg = %{
      type: "stream_start",
      model: model_name,
      session_id: data.session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:text, Poison.encode!(msg)}, state}
  end

  def websocket_info({:stream_chunk, data}, state) do
    # Only send chunk if content is not empty
    if String.trim(data.content) != "" do
      # Don't log every chunk to avoid spam
      msg = %{
        type: "stream_chunk",
        content: data.content,
        session_id: data.session_id,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Add role if present (for thinking chunks)
      msg =
        if Map.has_key?(data, :role) do
          Map.put(msg, :role, data.role)
        else
          msg
        end

      {:reply, {:text, Poison.encode!(msg)}, state}
    else
      # Skip empty chunks
      {:ok, state}
    end
  end

  def websocket_info({:stream_end, data}, state) do
    current_time = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.puts("ChatSocket[#{current_time}]: Stream ended: #{inspect(data)}")

    # Get model information from the chat process
    model_name =
      case state.chat_pid do
        nil ->
          "AI"

        chat_pid ->
          try do
            # Get the model from the chat state
            case GenServer.call(chat_pid, :get_model) do
              {:ok, model} -> format_model_name(model)
              _ -> "AI"
            end
          catch
            :exit, _ -> "AI"
          end
      end

    msg = %{
      type: "stream_end",
      reason: data.reason,
      model: model_name,
      session_id: data.session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:text, Poison.encode!(msg)}, state}
  end

  def websocket_info({:stream_error, data}, state) do
    IO.puts("ChatSocket: Stream error: #{inspect(data)}")

    msg = %{
      type: "stream_error",
      error: data.error,
      session_id: data.session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:text, Poison.encode!(msg)}, state}
  end

  def websocket_info({:start_continuation_stream, continuation_prompt}, state) do
    IO.puts("ChatSocket: !!!! websocket_info CALLED with :start_continuation_stream !!!!")
    IO.puts("ChatSocket: self() = #{inspect(self())}")
    IO.puts("ChatSocket: Starting continuation stream")
    IO.puts("ChatSocket: Continuation prompt length: #{String.length(continuation_prompt)} chars")

    # Start a new streaming session for the continuation prompt
    # This reuses the existing streaming logic
    websocket_pid = self()
    session_id = Map.get(state, :session_id)
    chat_pid = Map.get(state, :chat_pid)

    # Log continuation stream start
    ChatLogger.log_stream_event(session_id, "continuation", "websocket_info_called", %{
      prompt_length: String.length(continuation_prompt),
      prompt_preview: String.slice(continuation_prompt, 0, 100)
    })

    if chat_pid do
      Task.start(fn ->
        # Get the chat history and config from the Chat GenServer
        # This is necessary because the stream must be created in the same process that consumes it
        history = Chat.get_history(chat_pid)
        config_data = Chat.get_config(chat_pid)

        IO.puts(
          "ChatSocket: Got history length: #{length(history)}, provider: #{config_data.provider}"
        )

        # Prepare opts for streaming - reconstruct from config_data
        opts = [
          previous_messages: history,
          model: config_data.model,
          temperature: config_data.temperature,
          max_tokens: config_data.max_tokens
        ]

        # Create the stream directly in this Task process
        # This way HTTP chunks will be sent to THIS process, not the Chat GenServer
        ChatLogger.log_stream_event(session_id, "continuation", "creating_stream_in_task")

        stream = Exterm.Llm.ReqClient.stream_chat(config_data.provider, continuation_prompt, opts)

        IO.puts("ChatSocket: Continuation stream created in Task")
        ChatLogger.log_stream_event(session_id, "continuation", "stream_obtained")

        # Send stream start indicator
        send(websocket_pid, {:stream_start, %{session_id: session_id}})

        # Log that we're about to process the stream
        ChatLogger.log_stream_event(session_id, "continuation", "starting_enumeration")

        # Process the stream and send chunks immediately
        {_final_content, _tools_handled} =
          try do
            {accumulated_content, tool_calls} =
              stream
              |> Enum.reduce({"", []}, fn chunk, {content_acc, tool_acc} ->
                # Log each chunk for debugging
                ChatLogger.log_stream_event(session_id, "continuation", "chunk_received", %{
                  chunk: inspect(chunk),
                  content_acc_length: String.length(content_acc)
                })

                case chunk do
                  # Handle reasoning field (for models like Qwen3-VL-Thinking, DeepSeek-R1, OpenAI o1)
                  %{"choices" => [%{"delta" => %{"reasoning" => reasoning}} | _]}
                  when is_binary(reasoning) and reasoning != "" ->
                    ChatLogger.log_stream_event(session_id, "continuation", "reasoning_chunk", %{
                      reasoning: reasoning,
                      length: String.length(reasoning)
                    })

                    send(
                      websocket_pid,
                      {:stream_chunk, %{content: reasoning, role: "thinking", session_id: session_id}}
                    )

                    {content_acc, tool_acc}

                  %{"choices" => [%{"delta" => %{"content" => content, "role" => role}} | _]}
                  when is_binary(content) ->
                    # Send chunk immediately if content is not empty
                    if String.trim(content) != "" do
                      ChatLogger.log_stream_event(session_id, "continuation", "chunk_sent", %{
                        content: content,
                        role: role,
                        length: String.length(content)
                      })

                      send(
                        websocket_pid,
                        {:stream_chunk, %{content: content, role: role, session_id: session_id}}
                      )
                    end

                    {content_acc <> content, tool_acc}

                  %{"choices" => [%{"delta" => %{"content" => content}} | _]}
                  when is_binary(content) ->
                    # Send chunk immediately if content is not empty (no role specified)
                    if String.trim(content) != "" do
                      ChatLogger.log_stream_event(session_id, "continuation", "chunk_sent", %{
                        content: content,
                        length: String.length(content)
                      })

                      send(
                        websocket_pid,
                        {:stream_chunk, %{content: content, session_id: session_id}}
                      )
                    end

                    {content_acc <> content, tool_acc}

                  %{"choices" => [%{"delta" => %{"tool_calls" => delta_tool_calls}} | _]} ->
                    # Handle tool calls in continuation streaming mode
                    IO.puts(
                      "ChatSocket: Tool calls detected in continuation stream: #{inspect(delta_tool_calls)}"
                    )

                    ChatLogger.log_stream_event(
                      session_id,
                      "continuation",
                      "tool_calls_detected",
                      %{
                        delta_tool_calls: inspect(delta_tool_calls)
                      }
                    )

                    # Merge streaming tool calls
                    updated_tool_calls = merge_tool_calls(tool_acc, delta_tool_calls)

                    {content_acc, updated_tool_calls}

                  %{"choices" => [%{"finish_reason" => reason} | _]} when reason != nil ->
                    # Stream finished
                    ChatLogger.log_stream_event(
                      session_id,
                      "continuation",
                      "finish_reason",
                      %{
                        reason: reason,
                        total_content_length: String.length(content_acc)
                      }
                    )

                    {content_acc, tool_acc}

                  other ->
                    ChatLogger.log_stream_event(
                      session_id,
                      "continuation",
                      "unknown_chunk",
                      %{
                        chunk: inspect(other)
                      }
                    )

                    {content_acc, tool_acc}
                end
              end)

            # Check if we have tool calls to execute
            case tool_calls do
              [] ->
                # No tool calls, just send stream end
                ChatLogger.log_stream_event(session_id, "continuation", "stream_end_no_tools", %{
                  total_content: accumulated_content,
                  content_length: String.length(accumulated_content)
                })

                send(websocket_pid, {:stream_end, %{reason: "stop", session_id: session_id}})
                {accumulated_content, false}

              tool_calls when is_list(tool_calls) and length(tool_calls) > 0 ->
                # We have tool calls to execute in continuation
                IO.puts(
                  "ChatSocket: Executing tool calls in continuation: #{inspect(tool_calls)}"
                )

                ChatLogger.log_stream_event(session_id, "continuation", "executing_tools", %{
                  tool_count: length(tool_calls),
                  tools: inspect(tool_calls)
                })

                # Send stream end for the assistant message
                send(
                  websocket_pid,
                  {:stream_end, %{reason: "tool_calls", session_id: session_id}}
                )

                # Create assistant message with tool calls
                assistant_message = %{
                  "content" => accumulated_content,
                  "tool_calls" => tool_calls
                }

                # Add assistant message to chat history and handle tool calls
                case Chat.handle_assistant_with_tools(chat_pid, assistant_message,
                       streaming: true
                     ) do
                  {:ok, _tool_response} ->
                    IO.puts("ChatSocket: Continuation tool execution completed")

                    ChatLogger.log_stream_event(
                      session_id,
                      "continuation",
                      "tools_completed"
                    )

                    # Tool response will trigger another continuation automatically
                    {accumulated_content, true}

                  {:error, error} ->
                    IO.puts("ChatSocket: Continuation tool execution failed: #{inspect(error)}")

                    ChatLogger.log_stream_event(session_id, "continuation", "tools_failed", %{
                      error: inspect(error)
                    })

                    error_msg = "❌ **Tool Execution Error**: #{inspect(error)}"
                    send(websocket_pid, {:chat_response, error_msg})
                    {accumulated_content, true}
                end

              _ ->
                # Fallback
                ChatLogger.log_stream_event(session_id, "continuation", "stream_end", %{
                  total_content: accumulated_content,
                  content_length: String.length(accumulated_content)
                })

                send(websocket_pid, {:stream_end, %{reason: "stop", session_id: session_id}})
                {accumulated_content, false}
            end
          catch
            error ->
              IO.puts("ChatSocket: Continuation streaming error: #{inspect(error)}")

              ChatLogger.log_stream_event(session_id, "continuation", "error", %{
                error: inspect(error)
              })

              send(
                websocket_pid,
                {:stream_error,
                 %{error: "Streaming failed: #{inspect(error)}", session_id: session_id}}
              )

              {"", false}
          end
      end)
    end

    {:ok, state}
  end

  def websocket_info(info, state) do
    IO.puts("ChatSocket: CATCH-ALL websocket_info called with: #{inspect(info)}")

    ChatLogger.log_chat_event(
      Map.get(state, :session_id, "unknown"),
      :unhandled_websocket_info,
      %{
        message: inspect(info)
      }
    )

    {:ok, state}
  end

  def terminate(_reason, _request, state) do
    # Clean up: stop the chat GenServer and remove session from AppState
    session_id = Map.get(state, :session_id)

    if session_id do
      IO.puts("ChatSocket[#{session_id}]: Terminating and cleaning up session")

      # Remove session from AppState
      AppState.remove_ai_session(session_id)
    end

    case state do
      %{chat_pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # Private helper functions

  # Format model name for display in the UI
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

  defp handle_chat_message(_content, %{chat_pid: nil} = state) do
    IO.puts("ChatSocket: handle_chat_message called but chat_pid is nil")

    error_msg = %{
      type: "error",
      content: "Chat system not available",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:text, Poison.encode!(error_msg)}, state}
  end

  defp handle_chat_message(content, state) do
    session_id = state.session_id

    # Check if AI is globally stopped or this session is stopped
    session_info = AppState.get_ai_session(session_id)

    cond do
      AppState.ai_globally_stopped?() ->
        IO.puts("ChatSocket[#{session_id}]: AI is globally stopped, rejecting chat message")

        error_msg = %{
          type: "error",
          content: "AI is globally stopped. Please contact administrator.",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          session_id: session_id
        }

        {:reply, {:text, Poison.encode!(error_msg)}, state}

      session_info && session_info.status == :stopped ->
        IO.puts("ChatSocket[#{session_id}]: Session is stopped, rejecting chat message")

        error_msg = %{
          type: "error",
          content: "AI session is currently stopped. Send a 'start_ai' message to resume.",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          session_id: session_id
        }

        {:reply, {:text, Poison.encode!(error_msg)}, state}

      true ->
        handle_active_chat_message(content, state)
    end
  end

  defp handle_active_chat_message(content, %{chat_pid: chat_pid, session_id: session_id} = state) do
    IO.puts(
      "ChatSocket[#{session_id}]: handle_active_chat_message called with content: #{inspect(content)} and chat_pid: #{inspect(chat_pid)}"
    )

    # Update session activity
    AppState.update_session_activity(:ai, session_id)

    # Check if we need to auto-summarize before processing the new message (length-based only)
    _websocket_pid = self()

    # Send typing indicator
    typing_msg = %{
      type: "typing",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    IO.puts("ChatSocket: Sending typing indicator: #{inspect(typing_msg)}")

    # Capture the WebSocket process PID for use in the Task
    websocket_pid = self()

    # Send the message to the chat GenServer asynchronously with streaming
    Task.start(fn ->
      task_start_time = System.monotonic_time(:millisecond)
      current_time = DateTime.utc_now() |> DateTime.to_iso8601()

      IO.puts(
        "ChatSocket[#{current_time}]: Task started, calling Chat.stream_chat with: #{inspect(content)}"
      )

      case Chat.stream_chat(chat_pid, content) do
        {:ok, stream} ->
          stream_setup_time = System.monotonic_time(:millisecond) - task_start_time
          current_time = DateTime.utc_now() |> DateTime.to_iso8601()

          IO.puts(
            "ChatSocket[#{current_time}]: Chat.stream_chat returned success in #{stream_setup_time}ms, processing stream"
          )

          # Send stream start indicator
          send(websocket_pid, {:stream_start, %{session_id: session_id}})

          # Process the stream and send chunks
          {final_content, tools_handled} =
            try do
              {accumulated_content, tool_calls} =
                stream
                |> Enum.reduce({"", []}, fn chunk, {content_acc, tool_acc} ->
                  case chunk do
                    # Handle reasoning field (for models like Qwen3-VL-Thinking, DeepSeek-R1, OpenAI o1)
                    %{"choices" => [%{"delta" => %{"reasoning" => reasoning}} | _]}
                    when is_binary(reasoning) and reasoning != "" ->
                      send(
                        websocket_pid,
                        {:stream_chunk, %{content: reasoning, role: "thinking", session_id: session_id}}
                      )

                      {content_acc, tool_acc}

                    %{"choices" => [%{"delta" => %{"content" => content, "role" => role}} | _]}
                    when is_binary(content) ->
                      # Only send chunk to frontend if content is not empty
                      if String.trim(content) != "" do
                        send(
                          websocket_pid,
                          {:stream_chunk, %{content: content, role: role, session_id: session_id}}
                        )
                      end

                      {content_acc <> content, tool_acc}

                    %{"choices" => [%{"delta" => %{"content" => content}} | _]}
                    when is_binary(content) ->
                      # Only send chunk to frontend if content is not empty (no role)
                      if String.trim(content) != "" do
                        send(
                          websocket_pid,
                          {:stream_chunk, %{content: content, session_id: session_id}}
                        )
                      end

                      {content_acc <> content, tool_acc}

                    %{"choices" => [%{"delta" => %{"tool_calls" => delta_tool_calls}} | _]} ->
                      # Handle tool calls in streaming mode
                      IO.puts(
                        "ChatSocket: Tool calls detected in stream: #{inspect(delta_tool_calls)}"
                      )

                      # Merge streaming tool calls
                      updated_tool_calls = merge_tool_calls(tool_acc, delta_tool_calls)

                      {content_acc, updated_tool_calls}

                    %{"choices" => [%{"finish_reason" => reason} | _]} when reason != nil ->
                      IO.puts("ChatSocket: Stream finished with reason: #{reason}")
                      # Don't send stream_end here, send it after the enumeration
                      {content_acc, tool_acc}

                    _other ->
                      IO.puts("ChatSocket: Unhandled chunk: #{inspect(chunk)}")
                      {content_acc, tool_acc}
                  end
                end)

              # Check if we have tool calls to execute
              case tool_calls do
                [] ->
                  # No tool calls, just send stream end
                  send(websocket_pid, {:stream_end, %{reason: "stop", session_id: session_id}})
                  {accumulated_content, false}

                tool_calls when is_list(tool_calls) and length(tool_calls) > 0 ->
                  # We have tool calls to execute
                  tool_execution_start = System.monotonic_time(:millisecond)
                  current_time = DateTime.utc_now() |> DateTime.to_iso8601()

                  IO.puts(
                    "ChatSocket[#{current_time}]: Executing tool calls: #{inspect(tool_calls)}"
                  )

                  # Send stream end for the assistant message
                  send(
                    websocket_pid,
                    {:stream_end, %{reason: "tool_calls", session_id: session_id}}
                  )

                  # Create assistant message with tool calls
                  assistant_message = %{
                    "content" => accumulated_content,
                    "tool_calls" => tool_calls
                  }

                  # Add assistant message to chat history and handle tool calls
                  case Chat.handle_assistant_with_tools(chat_pid, assistant_message,
                         streaming: true
                       ) do
                    {:ok, _tool_response} ->
                      tool_execution_time =
                        System.monotonic_time(:millisecond) - tool_execution_start

                      current_time = DateTime.utc_now() |> DateTime.to_iso8601()

                      IO.puts(
                        "ChatSocket[#{current_time}]: Tool execution completed in #{tool_execution_time}ms"
                      )

                      # Tool response will be sent through the chat socket automatically
                      # Return content and flag indicating tool calls were handled
                      {accumulated_content, true}

                    {:error, error} ->
                      tool_execution_time =
                        System.monotonic_time(:millisecond) - tool_execution_start

                      current_time = DateTime.utc_now() |> DateTime.to_iso8601()

                      IO.puts(
                        "ChatSocket[#{current_time}]: Tool execution failed in #{tool_execution_time}ms: #{inspect(error)}"
                      )

                      error_msg = "❌ **Tool Execution Error**: #{inspect(error)}"
                      send(websocket_pid, {:chat_response, error_msg})
                      {accumulated_content, true}
                  end

                _ ->
                  # Fallback
                  send(websocket_pid, {:stream_end, %{reason: "stop", session_id: session_id}})
                  {accumulated_content, false}
              end
            rescue
              error ->
                IO.puts("ChatSocket: Stream processing error: #{inspect(error)}")

                send(
                  websocket_pid,
                  {:stream_error, %{error: inspect(error), session_id: session_id}}
                )

                {"", false}
            end

          # Update chat history with accumulated content only if tools weren't handled
          # (if tools were handled, the assistant message was already added to history)
          if final_content != "" and not tools_handled do
            # Add the assistant message to the chat history
            Chat.add_role_message(chat_pid, "assistant", final_content)
          end

        {:error, {:http_error, 401, body}} ->
          IO.puts("ChatSocket: API Key error: #{inspect(body)}")

          error_response = """
          ❌ **API Key Error**

          The AI service returned an authentication error. This usually means:

          • The API key has expired or is invalid
          • The API key doesn't have the required permissions
          • The API service is temporarily unavailable

          **To fix this:**
          1. Check your API keys in the `start.sh` file
          2. Verify the keys are still valid on the provider's website
          3. Restart the application after updating the keys

          **Current error:** Invalid API Key
          """

          send(websocket_pid, {:chat_response, error_response})

        {:error, {:http_error, status, body}} ->
          IO.puts("ChatSocket: HTTP error #{status}: #{inspect(body)}")

          error_response = """
          ❌ **AI Service Error**

          The AI service returned an HTTP #{status} error.

          **Error details:** #{body}

          This might be a temporary issue. Please try again in a moment.
          """

          send(websocket_pid, {:chat_response, error_response})

        {:error, {:request_failed, reason}} ->
          IO.puts("ChatSocket: Request failed: #{inspect(reason)}")

          error_response = """
          ❌ **Connection Error**

          Failed to connect to the AI service.

          **Possible causes:**
          • Network connectivity issues
          • AI service is temporarily down
          • Firewall blocking the connection

          **Error:** #{inspect(reason)}

          Please check your internet connection and try again.
          """

          send(websocket_pid, {:chat_response, error_response})

        {:error, reason} ->
          IO.puts("ChatSocket: Chat.chat returned error: #{inspect(reason)}")

          error_response = """
          ❌ **Unexpected Error**

          An unexpected error occurred while processing your message.

          **Error details:** #{inspect(reason)}

          Please try again or contact support if the issue persists.
          """

          send(websocket_pid, {:chat_response, error_response})
      end
    end)

    {:reply, {:text, Poison.encode!(typing_msg)}, state}
  end

  defp handle_clear_history(%{chat_pid: nil} = state) do
    IO.puts("ChatSocket: handle_clear_history called but chat_pid is nil")

    error_msg = %{
      type: "error",
      content: "Chat system not available",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, {:text, Poison.encode!(error_msg)}, state}
  end

  defp handle_clear_history(%{chat_pid: chat_pid} = state) do
    IO.puts("ChatSocket: handle_clear_history called with chat_pid: #{inspect(chat_pid)}")

    Chat.clear_history(chat_pid)

    success_msg = %{
      type: "system",
      content: "Chat history cleared",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    IO.puts("ChatSocket: Sending clear history success message: #{inspect(success_msg)}")
    {:reply, {:text, Poison.encode!(success_msg)}, state}
  end

  defp handle_stop_ai(state) do
    session_id = state.session_id
    IO.puts("ChatSocket[#{session_id}]: handle_stop_ai called")

    # Update the session status in AppState instead of local state
    AppState.update_ai_session_status(session_id, :stopped)

    # Send stop confirmation to frontend
    stop_msg = %{
      type: "ai_status",
      status: "stopped",
      message: "AI execution stopped for session #{session_id}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      session_id: session_id
    }

    IO.puts("ChatSocket[#{session_id}]: Sending stop confirmation: #{inspect(stop_msg)}")
    {:reply, {:text, Poison.encode!(stop_msg)}, state}
  end

  defp handle_start_ai(state) do
    session_id = state.session_id
    IO.puts("ChatSocket[#{session_id}]: handle_start_ai called")

    # Check if AI is globally stopped
    if AppState.ai_globally_stopped?() do
      error_msg = %{
        type: "error",
        content: "AI is globally stopped. Cannot start session.",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        session_id: session_id
      }

      {:reply, {:text, Poison.encode!(error_msg)}, state}
    else
      # Update the session status in AppState
      AppState.update_ai_session_status(session_id, :running)

      # Send start confirmation to frontend
      start_msg = %{
        type: "ai_status",
        status: "running",
        message: "AI execution resumed for session #{session_id}",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        session_id: session_id
      }

      IO.puts("ChatSocket[#{session_id}]: Sending start confirmation: #{inspect(start_msg)}")
      {:reply, {:text, Poison.encode!(start_msg)}, state}
    end
  end

  # Helper function to check API key configuration
  defp check_api_keys do
    groq_key = System.get_env("GROQ_API_KEY")
    deepinfra_key = System.get_env("DEEPINFRA_API_KEY")
    openrouter_key = System.get_env("OPENROUTER_API_KEY")

    cond do
      is_nil(groq_key) and is_nil(deepinfra_key) and is_nil(openrouter_key) ->
        {:warning,
         "No API keys found. Please set API keys in start.sh and restart the application."}

      String.length(groq_key || "") < 10 and String.length(deepinfra_key || "") < 10 and
          String.length(openrouter_key || "") < 10 ->
        {:warning, "API keys appear to be invalid. Please check your keys in start.sh."}

      true ->
        :ok
    end
  end

  # Helper function to merge streaming tool calls
  defp merge_tool_calls(existing_calls, new_delta_calls) do
    # In streaming, tool calls come as deltas that need to be merged
    # Each delta has an index and partial tool call data
    Enum.reduce(new_delta_calls, existing_calls, fn delta_call, acc_calls ->
      index = Map.get(delta_call, "index", 0)

      # Ensure we have enough slots in the accumulator
      padded_acc = ensure_list_size(acc_calls, index + 1)

      # Get existing call at this index or create new one
      existing_call = Enum.at(padded_acc, index) || %{}

      # Merge the delta into the existing call
      merged_call = deep_merge_tool_call(existing_call, delta_call)

      # Update the list at the specific index
      List.replace_at(padded_acc, index, merged_call)
    end)
  end

  defp ensure_list_size(list, min_size) do
    current_size = length(list)

    if current_size >= min_size do
      list
    else
      list ++ List.duplicate(%{}, min_size - current_size)
    end
  end

  defp deep_merge_tool_call(existing, delta) do
    # Merge tool call data, handling nested function data
    merged =
      Map.merge(existing, delta, fn
        "function", existing_fn, delta_fn when is_map(existing_fn) and is_map(delta_fn) ->
          Map.merge(existing_fn, delta_fn, fn
            "arguments", existing_args, delta_args
            when is_binary(existing_args) and is_binary(delta_args) ->
              existing_args <> delta_args

            _key, existing_val, new_val when is_nil(new_val) ->
              # Don't overwrite existing values with nil
              existing_val

            _key, _existing_val, new_val ->
              new_val
          end)

        _key, existing_val, new_val when is_nil(new_val) ->
          # Don't overwrite existing values with nil
          existing_val

        _key, _existing_val, new_val ->
          new_val
      end)

    # Remove any entries that have empty maps as values
    merged
    |> Enum.reject(fn {_k, v} -> v == %{} end)
    |> Enum.into(%{})
  end
end
