defmodule Exterm.Llm.ChatLogger do
  @moduledoc """
  Comprehensive logging for chat sessions to debug tool execution and continuation issues.
  """

  @log_dir "logs"

  def log_chat_event(session_id, event_type, data) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    log_entry = %{
      timestamp: timestamp,
      session_id: session_id,
      event_type: event_type,
      data: data
    }

    # Log to file
    log_to_file(session_id, log_entry)

    # Also log to console for immediate debugging
    IO.puts(
      "ChatLogger[#{timestamp}][#{session_id}]: #{event_type} - #{inspect(data, limit: :infinity)}"
    )
  end

  def log_message_history(session_id, messages) do
    log_chat_event(session_id, :message_history, %{
      message_count: length(messages),
      messages: messages
    })
  end

  def log_tool_execution(session_id, tool_name, args, result, duration_ms) do
    log_chat_event(session_id, :tool_execution, %{
      tool_name: tool_name,
      args: args,
      result: result,
      duration_ms: duration_ms
    })
  end

  def log_stream_event(session_id, stream_type, event, data \\ nil) do
    log_chat_event(session_id, "stream_#{stream_type}_#{event}", data)
  end

  def log_continuation_attempt(session_id, prompt, context_size) do
    log_chat_event(session_id, :continuation_attempt, %{
      prompt: prompt,
      context_size: context_size
    })
  end

  def log_ai_response(session_id, response_type, content, metadata \\ %{}) do
    log_chat_event(session_id, "ai_response_#{response_type}", %{
      content: content,
      metadata: metadata
    })
  end

  defp log_to_file(session_id, log_entry) do
    # Ensure logs directory exists
    File.mkdir_p!(@log_dir)

    # Create session-specific log file
    date_str = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string()
    filename = "#{@log_dir}/chat_#{session_id}_#{date_str}.log"

    # Format log entry as human-readable text
    timestamp = log_entry.timestamp
    event_type = log_entry.event_type

    # Format the data in a readable way
    data_str =
      case log_entry.data do
        nil -> ""
        data when is_map(data) -> format_data(data)
        data -> inspect(data, pretty: true, limit: :infinity)
      end

    # Use multi-line format if data is long
    log_line =
      if String.contains?(data_str, "\n") or String.length(data_str) > 200 do
        "[#{timestamp}] #{event_type}\n#{data_str}\n---\n"
      else
        "[#{timestamp}] #{event_type}#{if data_str != "", do: " - #{data_str}", else: ""}\n"
      end

    # Append to file
    File.write!(filename, log_line, [:append])
  end

  defp format_data(data) when is_map(data) do
    case map_size(data) do
      0 ->
        ""

      1 ->
        {key, value} = Enum.at(data, 0)
        "#{key}: #{format_value(value)}"

      _ ->
        data
        |> Enum.map(fn {key, value} -> "#{key}: #{format_value(value)}" end)
        # Multi-line format for better readability
        |> Enum.join("\n    ")
    end
  end

  defp format_value(value) when is_binary(value) do
    # Don't truncate! Show full content for debugging
    value
  end

  defp format_value(value), do: inspect(value, pretty: true, limit: :infinity)

  def get_session_logs(session_id, date \\ nil) do
    date_str =
      if date,
        do: Date.to_string(date),
        else: DateTime.utc_now() |> DateTime.to_date() |> Date.to_string()

    filename = "#{@log_dir}/chat_#{session_id}_#{date_str}.log"

    case File.read(filename) do
      {:ok, content} ->
        # Return raw content since it's now human readable
        String.split(content, "\n", trim: true)

      {:error, _} ->
        []
    end
  end

  def analyze_continuation_failures(session_id, date \\ nil) do
    logs = get_session_logs(session_id, date)

    continuation_attempts = Enum.filter(logs, &String.contains?(&1, "continuation_attempt"))
    stream_starts = Enum.filter(logs, &String.contains?(&1, "stream_continuation_start"))
    stream_chunks = Enum.filter(logs, &String.contains?(&1, "stream_continuation_chunk"))
    stream_ends = Enum.filter(logs, &String.contains?(&1, "stream_continuation_end"))

    %{
      continuation_attempts: length(continuation_attempts),
      stream_starts: length(stream_starts),
      stream_chunks: length(stream_chunks),
      stream_ends: length(stream_ends),
      attempts: continuation_attempts,
      starts: stream_starts,
      chunks: stream_chunks,
      ends: stream_ends
    }
  end
end
