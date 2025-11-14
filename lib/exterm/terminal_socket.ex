defmodule Exterm.TerminalSocket do
  @behaviour :cowboy_websocket

  alias Exterm.TerminalHistory
  alias Exterm.TerminalChatBridge

  def init(request, _state) do
    {:cowboy_websocket, request, %{}}
  end

  def websocket_init(_state) do
    # Generate a unique session ID for this terminal session
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16()

    # Detect OS and configure shell accordingly
    {os_family, os_name} = :os.type()

    script_cmd =
      case os_family do
        :win32 ->
          # Windows: Use PowerShell or cmd.exe directly
          case System.find_executable("pwsh") || System.find_executable("powershell") do
            nil ->
              # Fallback to cmd.exe
              "cmd.exe"

            ps_path ->
              # Use PowerShell
              "#{ps_path} -NoLogo -NoExit"
          end

        :unix ->
          # Unix-like systems (Linux, macOS, BSD)
          # Find bash path - try common locations
          bash_path =
            case System.find_executable("bash") do
              # fallback to sh if bash not found
              nil -> "/bin/sh"
              path -> path
            end

          # Use script command to create a proper PTY session
          # Linux: script -qefc command
          # macOS: script -q /dev/null command
          case System.find_executable("script") do
            nil ->
              # Fallback: use bash directly with some PTY-like options
              "#{bash_path} -i"

            script_path ->
              # Detect Unix variant and use appropriate script syntax
              case os_name do
                :darwin ->
                  # macOS syntax: script -q /dev/null command
                  "#{script_path} -q /dev/null #{bash_path} -i"

                _ ->
                  # Linux syntax: script -qefc command /dev/null
                  "#{script_path} -qefc '#{bash_path} -i' /dev/null"
              end
          end
      end

    # Spawn the shell with PTY support
    port =
      Port.open({:spawn, script_cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout
      ])

    # Set up a heartbeat timer to keep connection alive (every 30 seconds)
    :timer.send_interval(30_000, self(), :heartbeat)

    # Register this terminal socket with the bridge for AI interaction
    TerminalChatBridge.register_terminal_socket(session_id, self())

    # Store the port and session ID in the state
    {:ok, %{port: port, session_id: session_id}}
  end

  def websocket_handle({:text, msg}, state) do
    # Debug: log control characters
    if String.contains?(msg, <<3>>) do
      IO.puts("Received Ctrl+C (ETX) signal")
    end

    # Convert \r to \n for proper shell handling
    normalized_msg = String.replace(msg, "\r", "\n")

    # Log command to terminal history if it's a command (ends with newline)
    if String.ends_with?(normalized_msg, "\n") do
      command = String.trim(normalized_msg)

      if command != "" do
        TerminalHistory.add_command(state.session_id, command)
      end
    end

    # Forward incoming WebSocket message to the shell
    case Map.get(state, :port) do
      nil ->
        {:reply, {:text, "Error: Shell not available\r\n"}, state}

      port ->
        Port.command(port, normalized_msg)
        {:ok, state}
    end
  end

  def websocket_handle({:binary, msg}, state) do
    # Handle binary messages the same way as text
    case Map.get(state, :port) do
      nil ->
        {:reply, {:text, "Error: Shell not available\r\n"}, state}

      port ->
        Port.command(port, msg)
        {:ok, state}
    end
  end

  def websocket_handle({:pong, _data}, state) do
    # Handle pong response from client (optional logging)
    {:ok, state}
  end

  def websocket_handle(_data, state) do
    {:ok, state}
  end

  def websocket_info({port, {:data, data}}, %{port: port} = state) do
    # Log output to terminal history
    TerminalHistory.add_output(state.session_id, data)

    # 🤖 AUTONOMOUS AI: Notify AI about new terminal output for autonomous analysis
    TerminalChatBridge.notify_terminal_output(state.session_id, data)

    # Convert \n to \r\n for proper terminal display
    normalized_data = String.replace(data, "\n", "\r\n")
    # Forward shell output back to WebSocket client
    {:reply, {:text, normalized_data}, state}
  end

  def websocket_info({port, {:exit_status, _status}}, %{port: port} = state) do
    # Shell exited, close the WebSocket
    {:reply, {:close, 1000, "Shell exited"}, state}
  end

  def websocket_info(:heartbeat, state) do
    # Send a ping frame to keep the connection alive
    {:reply, {:ping, ""}, state}
  end

  def websocket_info({:ai_input, input}, state) do
    # Handle input from AI through the bridge
    case Map.get(state, :port) do
      nil ->
        {:ok, state}

      port ->
        # Log the AI input as a command
        TerminalHistory.add_command(state.session_id, String.trim(input))

        # Send the input to the terminal
        Port.command(port, input)
        {:ok, state}
    end
  end

  def websocket_info(_info, state) do
    {:ok, state}
  end

  def terminate(_reason, _request, state) do
    # Unregister from the bridge
    if Map.has_key?(state, :session_id) do
      TerminalChatBridge.unregister_terminal_socket(state.session_id)
      TerminalHistory.clear_session(state.session_id)
    end

    # Clean up: close the port if it exists
    case state do
      %{port: port} when is_port(port) -> Port.close(port)
      _ -> :ok
    end

    :ok
  end
end
