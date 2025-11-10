defmodule Exterm.TerminalHistory do
  @moduledoc """
  Manages terminal command history and output for AI context.
  Stores recent commands and outputs for AI to analyze.
  """

  use GenServer
  require Logger

  # Keep last 100 entries per session
  @max_history_entries 100

  defstruct [:session_histories]

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok, %__MODULE__{session_histories: %{}}}
  end

  @doc """
  Add a command to session history
  """
  def add_command(session_id, command) do
    GenServer.cast(__MODULE__, {:add_command, session_id, command, DateTime.utc_now()})
  end

  @doc """
  Add command output to session history
  """
  def add_output(session_id, output) do
    GenServer.cast(__MODULE__, {:add_output, session_id, output, DateTime.utc_now()})
  end

  @doc """
  Get recent history for a session
  """
  def get_history(session_id, lines \\ 20) do
    GenServer.call(__MODULE__, {:get_history, session_id, lines})
  end

  @doc """
  Get all history for a session (for AI context)
  """
  def get_full_history(session_id) do
    GenServer.call(__MODULE__, {:get_history, session_id, @max_history_entries})
  end

  @doc """
  Clear history for a session
  """
  def clear_session(session_id) do
    GenServer.cast(__MODULE__, {:clear_session, session_id})
  end

  # GenServer callbacks

  def handle_cast({:add_command, session_id, command, timestamp}, state) do
    entry = %{type: :command, content: command, timestamp: timestamp}
    new_state = add_entry_to_session(state, session_id, entry)
    {:noreply, new_state}
  end

  def handle_cast({:add_output, session_id, output, timestamp}, state) do
    entry = %{type: :output, content: output, timestamp: timestamp}
    new_state = add_entry_to_session(state, session_id, entry)
    {:noreply, new_state}
  end

  def handle_cast({:clear_session, session_id}, state) do
    new_histories = Map.delete(state.session_histories, session_id)
    {:noreply, %{state | session_histories: new_histories}}
  end

  def handle_call({:get_history, session_id, lines}, _from, state) do
    history = get_session_history(state, session_id, lines)
    {:reply, history, state}
  end

  # Private functions

  defp add_entry_to_session(state, session_id, entry) do
    current_history = Map.get(state.session_histories, session_id, [])
    new_history = [entry | current_history] |> Enum.take(@max_history_entries)

    new_histories = Map.put(state.session_histories, session_id, new_history)
    %{state | session_histories: new_histories}
  end

  defp get_session_history(state, session_id, lines) do
    case Map.get(state.session_histories, session_id) do
      nil -> []
      history -> history |> Enum.take(lines) |> Enum.reverse()
    end
  end
end
