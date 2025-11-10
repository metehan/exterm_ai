defmodule Exterm.Llm.Tools.Terminal do
  @moduledoc """
  Terminal interaction tools for AI assistant.
  """

  alias Exterm.TerminalHistory
  alias Exterm.TerminalChatBridge

  @doc """
  Read terminal output and command history
  """
  def read_terminal(params, chat_socket_pid) do
    lines = Map.get(params, "lines", 20) |> min(100)

    case TerminalChatBridge.get_terminal_session_id(chat_socket_pid) do
      nil ->
        %{
          "success" => false,
          "error" => "No terminal session associated with this chat"
        }

      session_id ->
        history = TerminalHistory.get_history(session_id, lines)
        formatted_history = format_history_for_ai(history)

        %{
          "success" => true,
          "terminal_output" => formatted_history,
          "entry_count" => length(history),
          "note" => "Recent terminal output and commands"
        }
    end
  end

  @doc """
  Send input to terminal and optionally read results
  """
  def send_to_terminal(params, chat_socket_pid) do
    # Handle both "input" and "command" parameter names (some models use "command")
    input = Map.get(params, "input") || Map.get(params, "command")

    if !input do
      %{
        "success" => false,
        "error" => "Missing required parameter: 'input' or 'command'"
      }
    else
      add_newline = Map.get(params, "add_newline", true)
      auto_read = Map.get(params, "auto_read", true)
      sleep_seconds = Map.get(params, "sleep_seconds", 1.5)

      case TerminalChatBridge.get_terminal_session_id(chat_socket_pid) do
        nil ->
          %{
            "success" => false,
            "error" => "No terminal session associated with this chat"
          }

        session_id ->
          final_input = if add_newline, do: input <> "\n", else: input

          case TerminalChatBridge.send_to_terminal(session_id, final_input) do
            {:ok, message} ->
              base_result = %{
                "success" => true,
                "message" => message,
                "sent_input" => final_input,
                "note" => "Input sent to terminal successfully"
              }

              if auto_read do
                # Instead of sleeping, monitor terminal output for command completion
                case wait_for_command_completion(session_id, sleep_seconds) do
                  {:ok, final_history} ->
                    Map.merge(base_result, %{
                      "terminal_output" => final_history,
                      "auto_read" => true,
                      "note" => "Command sent and monitored until completion"
                    })

                  {:timeout, partial_history} ->
                    Map.merge(base_result, %{
                      "terminal_output" => partial_history,
                      "auto_read" => true,
                      "note" =>
                        "Command sent, timed out after #{sleep_seconds}s, showing partial results"
                    })
                end
              else
                base_result
              end

            {:error, reason} ->
              %{
                "success" => false,
                "error" => reason
              }
          end
      end
    end
  end

  @doc """
  Sleep for specified duration
  """
  def sleep(%{"seconds" => seconds}, _chat_socket_pid) do
    sleep_duration = max(0.1, min(seconds, 10.0))
    sleep_ms = round(sleep_duration * 1000)

    :timer.sleep(sleep_ms)

    %{
      "success" => true,
      "slept_seconds" => sleep_duration,
      "message" => "Waited for #{sleep_duration} seconds"
    }
  end

  @doc """
  Suggest a terminal command for user approval
  """
  def suggest_terminal_command(%{"command" => command, "reason" => reason}, _chat_socket_pid) do
    %{
      "success" => true,
      "message" => "Command suggestion created",
      "command" => command,
      "reason" => reason,
      "status" => "awaiting_approval",
      "note" => "This command is awaiting user approval before execution."
    }
  end

  @doc """
  Get terminal command history
  """
  def get_terminal_history(params, chat_socket_pid) do
    lines = Map.get(params, "lines", 20) |> min(50)

    case TerminalChatBridge.get_terminal_session_id(chat_socket_pid) do
      nil ->
        %{
          "success" => false,
          "error" => "No terminal session associated with this chat"
        }

      session_id ->
        history = TerminalHistory.get_history(session_id, lines)
        formatted_history = format_history_for_ai(history)

        %{
          "success" => true,
          "history" => formatted_history,
          "entry_count" => length(history)
        }
    end
  end

  # Private helper functions

  # Monitor terminal output for command completion instead of using sleep
  defp wait_for_command_completion(session_id, timeout_seconds) do
    timeout_ms = round(timeout_seconds * 1000)
    start_time = System.monotonic_time(:millisecond)
    # Check every 50ms for faster response
    check_interval = 50

    # Get initial output count to detect new activity
    initial_history = TerminalHistory.get_history(session_id, 5)
    initial_count = length(initial_history)

    wait_for_output_stability(session_id, start_time, timeout_ms, check_interval, initial_count)
  end

  defp wait_for_output_stability(session_id, start_time, timeout_ms, check_interval, last_count) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - start_time

    if elapsed >= timeout_ms do
      # Timeout reached, return what we have
      history = TerminalHistory.get_history(session_id, 20)
      formatted_history = format_history_for_ai(history)
      {:timeout, formatted_history}
    else
      # Check if new output has appeared
      current_history = TerminalHistory.get_history(session_id, 10)
      current_count = length(current_history)

      if current_count > last_count do
        # New output detected, wait a bit more and check for stability
        :timer.sleep(check_interval)

        # Check again after short wait
        stable_history = TerminalHistory.get_history(session_id, 10)
        stable_count = length(stable_history)

        if stable_count == current_count and elapsed > 100 do
          # Output appears stable (no new output in last 50ms) and we've waited at least 100ms
          full_history = TerminalHistory.get_history(session_id, 20)
          formatted_history = format_history_for_ai(full_history)
          {:ok, formatted_history}
        else
          # Still receiving output, continue monitoring
          wait_for_output_stability(
            session_id,
            start_time,
            timeout_ms,
            check_interval,
            stable_count
          )
        end
      else
        # No new output, wait and check again
        :timer.sleep(check_interval)

        wait_for_output_stability(
          session_id,
          start_time,
          timeout_ms,
          check_interval,
          current_count
        )
      end
    end
  end

  defp format_history_for_ai(history) do
    Enum.map(history, fn entry ->
      %{
        "type" => entry.type,
        "content" => String.trim(entry.content),
        "timestamp" => DateTime.to_string(entry.timestamp)
      }
    end)
  end
end
