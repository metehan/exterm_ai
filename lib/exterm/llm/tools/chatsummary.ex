defmodule Exterm.Llm.Tools.ChatSummary do
  @moduledoc """
  Chat history management and summarization tools.
  """

  alias Exterm.Llm.Chat
  alias Exterm.Llm.ReqClient, as: LLMClient

  @doc """
  Summarize chat history when it gets too long or when switching topics
  """
  def summarize_chat(%{"reason" => reason} = params, chat_socket_pid) do
    max_history_length = Map.get(params, "max_history_length", 10)
    summary_length = Map.get(params, "summary_length", "medium")

    try do
      # Get the chat session for this socket - we'll get it from the process that calls this
      # For now, we'll modify this to work with the chat_pid passed from the socket
      case get_chat_pid_from_socket(chat_socket_pid) do
        nil ->
          %{
            "success" => false,
            "error" => "No active chat session found"
          }

        chat_pid ->
          summarize_chat_with_pid(chat_pid, reason, max_history_length, summary_length)
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error summarizing chat: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Summarize chat using the chat PID directly
  """
  def summarize_chat_with_pid(
        chat_pid,
        reason,
        max_history_length \\ 10,
        summary_length \\ "medium"
      ) do
    try do
      # Get current conversation history
      current_messages = Chat.export_conversation(chat_pid)

      if length(current_messages) <= 3 do
        %{
          "success" => true,
          "message" => "Chat history is too short to summarize",
          "action" => "none"
        }
      else
        # Generate summary using the chat itself
        summary_prompt = build_summary_prompt(current_messages, reason, summary_length)

        # Create a temporary summary request
        {:ok, summary} = request_summary(chat_pid, summary_prompt)

        # Create condensed history: system message + summary + recent messages
        condensed_history =
          create_condensed_history(
            current_messages,
            summary,
            max_history_length
          )

        # Replace the conversation history
        Chat.import_conversation(chat_pid, condensed_history)

        %{
          "success" => true,
          "message" => "Chat history summarized successfully",
          "reason" => reason,
          "original_message_count" => length(current_messages),
          "condensed_message_count" => length(condensed_history),
          "summary_preview" => String.slice(summary, 0, 200) <> "..."
        }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error summarizing chat: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Summarizes a chat conversation using the provided messages directly (no GenServer calls).
  This avoids deadlock when called from within the Chat GenServer itself.

  ## Parameters
  - `messages`: List of conversation messages
  - `reason`: Reason for summarization
  - `max_history_length`: Number of recent messages to keep after summary
  - `summary_length`: Length of summary ("short", "medium", "long")
  """
  def summarize_chat_with_messages(
        messages,
        reason,
        max_history_length \\ 10,
        summary_length \\ "medium"
      ) do
    try do
      if length(messages) <= 3 do
        %{
          "success" => true,
          "message" => "Chat history is too short to summarize",
          "action" => "none"
        }
      else
        # Generate summary using an external Chat GenServer to avoid deadlock
        summary_prompt = build_summary_prompt(messages, reason, summary_length)

        # Start a temporary chat process for summarization
        {:ok, temp_chat_pid} =
          Chat.start_link(
            provider: :openrouter,
            system_prompt: "You are a helpful assistant that creates concise summaries."
          )

        # Get summary from temporary process
        {:ok, summary} = request_summary(temp_chat_pid, summary_prompt)

        # Stop temporary process
        GenServer.stop(temp_chat_pid)

        # Create condensed history: system message + summary + recent messages
        condensed_history = create_condensed_history(messages, summary, max_history_length)

        %{
          "success" => true,
          "message" => "Chat history summarized successfully",
          "reason" => reason,
          "original_message_count" => length(messages),
          "condensed_message_count" => length(condensed_history),
          "condensed_history" => condensed_history
        }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error summarizing chat: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Check if chat history should be summarized automatically
  """
  def should_auto_summarize(chat_pid) when is_pid(chat_pid) do
    current_messages = Chat.export_conversation(chat_pid)
    message_count = length(current_messages)

    # Auto-summarize if we have more than 30 messages
    message_count > 30
  end

  def should_auto_summarize(_), do: false

  @doc """
  Auto-summarize if needed and return whether summarization occurred
  """
  def auto_summarize_if_needed(chat_pid) when is_pid(chat_pid) do
    if should_auto_summarize(chat_pid) do
      case summarize_chat_with_pid(chat_pid, "automatic_length_limit") do
        %{"success" => true} = result ->
          {:summarized, result}

        error ->
          {:error, error}
      end
    else
      {:no_action, nil}
    end
  end

  def auto_summarize_if_needed(_), do: {:no_action, nil}

  # Private helper functions

  defp get_chat_pid_from_socket(chat_socket_pid) do
    # Try to get the chat_pid from the calling process context
    # Since this is called from within the Chat GenServer process,
    # we can access the chat_pid from the process that calls this tool
    # Let's use the process dictionary as a simple solution
    case Process.get({:chat_pid_for_socket, chat_socket_pid}) do
      nil ->
        # Fallback: try to find it via the socket process itself
        try do
          case GenServer.call(chat_socket_pid, :get_chat_pid, 5000) do
            {:ok, chat_pid} -> chat_pid
            _ -> nil
          end
        rescue
          _ -> nil
        end

      chat_pid ->
        chat_pid
    end
  end

  defp build_summary_prompt(messages, reason, summary_length) do
    length_instruction =
      case summary_length do
        "short" -> "Keep the summary very concise (2-3 sentences)."
        "medium" -> "Provide a moderate summary (1-2 paragraphs)."
        "long" -> "Provide a detailed summary (2-3 paragraphs)."
        _ -> "Provide a moderate summary (1-2 paragraphs)."
      end

    reason_context =
      case reason do
        "topic_change" ->
          "The user is switching to a completely different topic."

        "automatic_length_limit" ->
          "The conversation has become too long and needs to be condensed."

        "user_request" ->
          "The user has explicitly requested a summary."

        _ ->
          "The conversation needs to be summarized."
      end

    # Extract non-system messages for summarization
    conversation_messages =
      messages
      |> Enum.filter(fn msg -> msg.role != "system" end)
      |> Enum.map(fn msg -> "#{String.upcase(msg.role)}: #{msg.content}" end)
      |> Enum.join("\n\n")

    """
    You are an expert at summarizing technical conversations. Please provide a comprehensive summary of this AI assistant conversation. #{reason_context} #{length_instruction}

    **SUMMARIZATION GOALS:**
    - Preserve key technical details and context
    - Maintain important command outputs and file operations
    - Keep track of project state and ongoing work
    - Note any important decisions or conclusions
    - Preserve error resolutions and troubleshooting steps

    **FOCUS AREAS:**
    - Key topics and technical discussions
    - Commands executed and their outcomes
    - Files created, modified, or analyzed
    - Current state of any ongoing work
    - Important context that should be remembered for future assistance
    - Any unresolved issues or next steps

    **CONVERSATION TO SUMMARIZE:**
    #{conversation_messages}

    **INSTRUCTIONS:**
    - Write in clear, technical language
    - Use bullet points or structured format for clarity
    - Include specific technical details that are important
    - Mention any ongoing context or state that should be preserved
    - Keep the summary focused and actionable

    Provide only the summary content, no meta-commentary about the summarization process.
    """
  end

  defp request_summary(_chat_pid, summary_prompt) do
    # Use a reliable model for summaries
    summary_opts = [
      # Use the same working model
      model: "x-ai/grok-4-fast",
      # Lower temperature for more focused summaries
      temperature: 0.3,
      # Reasonable limit for summaries
      max_tokens: 1000,
      # Don't include chat history for summary generation
      previous_messages: []
    ]

    # Create a direct request to the summarization model
    case LLMClient.chat(:openrouter, summary_prompt, summary_opts) do
      %{"choices" => [%{"message" => %{"content" => summary}} | _]} ->
        {:ok, summary}

      {:error, error} ->
        {:error, error}

      error ->
        {:error, "Unexpected response format: #{inspect(error)}"}
    end
  end

  defp create_condensed_history(original_messages, summary, max_recent_count) do
    # Find the system message (if any)
    system_messages = Enum.filter(original_messages, fn msg -> msg.role == "system" end)

    # Get the most recent messages (excluding system messages)
    non_system_messages = Enum.filter(original_messages, fn msg -> msg.role != "system" end)
    recent_messages = Enum.take(non_system_messages, -max_recent_count)

    # Create summary message
    summary_message = %{role: "system", content: "Previous conversation summary: #{summary}"}

    # Combine: system messages + summary + recent messages
    system_messages ++ [summary_message] ++ recent_messages
  end
end
