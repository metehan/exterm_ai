defmodule Exterm.TerminalChatBridge do
  @moduledoc """
  Bridge module that connects terminal sessions with chat sessions.
  Manages mapping between terminal session IDs and chat sessions for AI context.
  """

  use GenServer

  defstruct [:session_mappings, :terminal_sockets]

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok, %__MODULE__{session_mappings: %{}, terminal_sockets: %{}}}
  end

  @doc """
  Register a terminal socket with its session ID.
  This allows AI to send commands directly to the terminal.
  """
  def register_terminal_socket(session_id, terminal_socket_pid) do
    GenServer.cast(__MODULE__, {:register_terminal, session_id, terminal_socket_pid})
  end

  @doc """
  Unregister a terminal socket when it closes.
  """
  def unregister_terminal_socket(session_id) do
    GenServer.cast(__MODULE__, {:unregister_terminal, session_id})
  end

  @doc """
  Send input directly to a terminal session.
  """
  def send_to_terminal(session_id, input) do
    GenServer.call(__MODULE__, {:send_to_terminal, session_id, input})
  end

  @doc """
  Register a chat socket with a terminal session ID.
  This allows the AI to access terminal history for context.
  """
  def register_chat_session(chat_socket_pid, terminal_session_id) do
    GenServer.cast(__MODULE__, {:register_chat, chat_socket_pid, terminal_session_id})
  end

  @doc """
  Get the terminal session ID associated with a chat socket.
  For now, returns the first available terminal session.
  """
  def get_terminal_session_id(chat_socket_pid) do
    case GenServer.call(__MODULE__, {:get_terminal_session, chat_socket_pid}) do
      nil ->
        # If no specific mapping, try to get the first available terminal session
        GenServer.call(__MODULE__, :get_any_terminal_session)

      session_id ->
        session_id
    end
  end

  @doc """
  Get any available terminal session ID for testing.
  """
  def get_any_terminal_session() do
    GenServer.call(__MODULE__, :get_any_terminal_session)
  end

  @doc """
  Unregister a chat session when it closes.
  """
  def unregister_chat_session(chat_socket_pid) do
    GenServer.cast(__MODULE__, {:unregister_chat, chat_socket_pid})
  end

  @doc """
  🤖 AUTONOMOUS AI: Notify AI about new terminal output for autonomous analysis.
  This triggers the AI to automatically analyze terminal output and take action.
  """
  def notify_terminal_output(terminal_session_id, output_data) do
    GenServer.cast(__MODULE__, {:notify_terminal_output, terminal_session_id, output_data})
  end

  @doc """
  Execute a validated command suggestion in the terminal.
  This is called when user approves an AI command suggestion.
  """
  def execute_approved_command(terminal_session_id, command) do
    # For now, we'll just log this - in future we could send to terminal
    IO.puts("Bridge: Executing approved command '#{command}' for session #{terminal_session_id}")
    {:ok, "Command logged (terminal execution not yet implemented)"}
  end

  # GenServer callbacks

  def handle_cast({:register_terminal, session_id, terminal_socket_pid}, state) do
    new_terminal_sockets = Map.put(state.terminal_sockets, session_id, terminal_socket_pid)
    {:noreply, %{state | terminal_sockets: new_terminal_sockets}}
  end

  def handle_cast({:unregister_terminal, session_id}, state) do
    new_terminal_sockets = Map.delete(state.terminal_sockets, session_id)
    {:noreply, %{state | terminal_sockets: new_terminal_sockets}}
  end

  def handle_cast({:register_chat, chat_pid, terminal_session_id}, state) do
    new_mappings = Map.put(state.session_mappings, chat_pid, terminal_session_id)
    {:noreply, %{state | session_mappings: new_mappings}}
  end

  def handle_cast({:unregister_chat, chat_pid}, state) do
    new_mappings = Map.delete(state.session_mappings, chat_pid)
    {:noreply, %{state | session_mappings: new_mappings}}
  end

  def handle_cast({:notify_terminal_output, terminal_session_id, output_data}, state) do
    # 🤖 AUTONOMOUS AI: Find all chat sessions associated with this terminal session
    # and automatically send meaningful terminal output for AI analysis

    # Only trigger AI analysis for meaningful output (not just prompts, empty lines, etc.)
    trimmed_output = String.trim(output_data)

    # Skip analysis for:
    # - Empty output
    # - Pure ANSI escape sequences
    # - Just prompts (lines ending with $ or #)
    # - Very short output (less than 5 chars)
    should_analyze =
      String.length(trimmed_output) > 5 and
        not String.match?(trimmed_output, ~r/^[\s\x1b\[\d;]*[m$#]*$/u) and
        not String.match?(trimmed_output, ~r/^.*[$#]\s*$/u) and
        String.length(String.replace(trimmed_output, ~r/\x1b\[[0-9;]*m/u, "")) > 3

    if should_analyze do
      # Find chat sockets associated with this terminal session
      associated_chat_pids =
        state.session_mappings
        |> Enum.filter(fn {_chat_pid, session_id} -> session_id == terminal_session_id end)
        |> Enum.map(fn {chat_pid, _session_id} -> chat_pid end)

      # Send autonomous analysis message to each associated chat AI
      for chat_pid <- associated_chat_pids do
        # Create autonomous analysis prompt
        autonomous_message = """
        🤖 AUTONOMOUS ANALYSIS: New terminal output detected:

        ```
        #{trimmed_output}
        ```

        Please analyze this output and take autonomous action if needed:
        - Are there errors that need fixing?
        - Is a task incomplete that should be continued?
        - Should you suggest next steps?
        - Can you help optimize the workflow?
        - Does this indicate success/completion of a task?

        Take initiative based on what you observe! If no action is needed, just say "Monitoring..." to acknowledge.
        """

        # Send the autonomous analysis request to the AI
        try do
          # Use spawn to avoid blocking the bridge
          spawn(fn ->
            # Send the autonomous message to the AI for analysis
            case GenServer.call(chat_pid, {:chat, autonomous_message}, 10_000) do
              {:ok, _response} ->
                :ok

              {:error, reason} ->
                IO.puts("Bridge: Failed to send autonomous analysis to AI: #{inspect(reason)}")
            end
          end)
        rescue
          error ->
            IO.puts("Bridge: Error sending autonomous analysis: #{inspect(error)}")
        end
      end
    end

    {:noreply, state}
  end

  def handle_call({:send_to_terminal, session_id, input}, _from, state) do
    case Map.get(state.terminal_sockets, session_id) do
      nil ->
        # Try to send to any available terminal as fallback
        case get_any_available_terminal(state) do
          nil ->
            {:reply, {:error, "No terminal session found"}, state}

          terminal_pid ->
            send(terminal_pid, {:ai_input, input})
            {:reply, {:ok, "Input sent to terminal"}, state}
        end

      terminal_pid ->
        send(terminal_pid, {:ai_input, input})
        {:reply, {:ok, "Input sent to terminal"}, state}
    end
  end

  def handle_call({:get_terminal_session, chat_pid}, _from, state) do
    terminal_session_id = Map.get(state.session_mappings, chat_pid)
    {:reply, terminal_session_id, state}
  end

  def handle_call(:get_any_terminal_session, _from, state) do
    # Try to get a real terminal session, or return a default one
    case Map.keys(state.terminal_sockets) do
      [] ->
        mock_session_id = "terminal_session_1"
        {:reply, mock_session_id, state}

      [session_id | _] ->
        {:reply, session_id, state}
    end
  end

  # Private helper functions

  defp get_any_available_terminal(state) do
    case Map.values(state.terminal_sockets) do
      [] -> nil
      [terminal_pid | _] -> terminal_pid
    end
  end
end
