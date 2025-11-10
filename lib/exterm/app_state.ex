defmodule Exterm.AppState do
  @moduledoc """
  Single source of truth for application state management.
  Simple GenServer that holds all application state in one place.
  """

  use GenServer

  # Client API

  @doc "Start the state manager"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the entire application state"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Get a specific value from state by path"
  def get(path) when is_list(path) do
    GenServer.call(__MODULE__, {:get, path})
  end

  def get(key) when is_atom(key) do
    get([key])
  end

  @doc "Set a value in state by path"
  def put(path, value) when is_list(path) do
    GenServer.call(__MODULE__, {:put, path, value})
  end

  def put(key, value) when is_atom(key) do
    put([key], value)
  end

  @doc "Update state using a function"
  def update(path, update_fn) when is_list(path) and is_function(update_fn) do
    GenServer.call(__MODULE__, {:update, path, update_fn})
  end

  def update(key, update_fn) when is_atom(key) and is_function(update_fn) do
    update([key], update_fn)
  end

  @doc "Subscribe to state changes for a specific path"
  def subscribe(path \\ []) do
    GenServer.call(__MODULE__, {:subscribe, self(), path})
  end

  @doc "Unsubscribe from state changes"
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  # Session Management API

  @doc "Create a new AI chat session"
  def create_ai_session(session_id, chat_pid, socket_pid) do
    session_data = %{
      chat_pid: chat_pid,
      socket_pid: socket_pid,
      status: :running,
      created_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      message_count: 0
    }

    GenServer.call(__MODULE__, {:create_ai_session, session_id, session_data})
  end

  @doc "Create a new terminal session"
  def create_terminal_session(session_id, socket_pid, port) do
    session_data = %{
      socket_pid: socket_pid,
      port: port,
      current_output: "",
      history: [],
      created_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now()
    }

    GenServer.call(__MODULE__, {:create_terminal_session, session_id, session_data})
  end

  @doc "Update AI session status"
  def update_ai_session_status(session_id, status) when status in [:running, :stopped, :error] do
    GenServer.call(__MODULE__, {:update_ai_session_status, session_id, status})
  end

  @doc "Remove AI session"
  def remove_ai_session(session_id) do
    GenServer.call(__MODULE__, {:remove_ai_session, session_id})
  end

  @doc "Remove terminal session"
  def remove_terminal_session(session_id) do
    GenServer.call(__MODULE__, {:remove_terminal_session, session_id})
  end

  @doc "Get all AI sessions"
  def get_ai_sessions do
    get([:ai_sessions])
  end

  @doc "Get specific AI session"
  def get_ai_session(session_id) do
    get([:ai_sessions, session_id])
  end

  @doc "Get all terminal sessions"
  def get_terminal_sessions do
    get([:terminal_sessions])
  end

  @doc "Get specific terminal session"
  def get_terminal_session(session_id) do
    get([:terminal_sessions, session_id])
  end

  @doc "Check if AI is globally stopped"
  def ai_globally_stopped? do
    get([:global, :ai_globally_stopped]) || false
  end

  @doc "Set global AI stop state"
  def set_global_ai_stopped(stopped) when is_boolean(stopped) do
    put([:global, :ai_globally_stopped], stopped)
  end

  @doc "Update session activity timestamp"
  def update_session_activity(session_type, session_id) when session_type in [:ai, :terminal] do
    path = [:"#{session_type}_sessions", session_id, :last_activity]
    put(path, DateTime.utc_now())
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    state = %{
      # Application data
      data: %{
        # AI Sessions - support multiple concurrent AI chat sessions
        ai_sessions:
          %{
            # session_id => %{
            #   chat_pid: pid,
            #   socket_pid: pid, 
            #   status: :running | :stopped | :error,
            #   created_at: datetime,
            #   last_activity: datetime,
            #   message_count: integer
            # }
          },
        # Terminal Sessions - support multiple concurrent terminal sessions  
        terminal_sessions:
          %{
            # session_id => %{
            #   socket_pid: pid,
            #   port: port,
            #   current_output: string,
            #   history: [commands],
            #   created_at: datetime,
            #   last_activity: datetime
            # }
          },
        # Global application state
        global: %{
          # Global AI control (can stop all AI sessions)
          ai_globally_stopped: false,
          # UI preferences
          ui: %{
            theme: "dark",
            split_ratio: 0.6
          },
          # Statistics
          stats: %{
            total_sessions_created: 0,
            active_sessions: 0
          }
        }
      },
      # Subscribers list: [{pid, path}]
      subscribers: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.data, state}
  end

  @impl true
  def handle_call({:get, path}, _from, state) do
    value = get_in(state.data, path)
    {:reply, value, state}
  end

  @impl true
  def handle_call({:put, path, value}, _from, state) do
    new_data = put_in(state.data, path, value)
    new_state = %{state | data: new_data}

    # Notify subscribers
    notify_subscribers(new_state.subscribers, path, value)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update, path, update_fn}, _from, state) do
    current_value = get_in(state.data, path)
    new_value = update_fn.(current_value)
    new_data = put_in(state.data, path, new_value)
    new_state = %{state | data: new_data}

    # Notify subscribers
    notify_subscribers(new_state.subscribers, path, new_value)

    {:reply, new_value, new_state}
  end

  @impl true
  def handle_call({:subscribe, pid, path}, _from, state) do
    # Monitor the subscriber process
    Process.monitor(pid)

    new_subscribers = [{pid, path} | state.subscribers]
    new_state = %{state | subscribers: new_subscribers}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers = Enum.reject(state.subscribers, fn {sub_pid, _} -> sub_pid == pid end)
    new_state = %{state | subscribers: new_subscribers}

    {:reply, :ok, new_state}
  end

  # Session Management Handlers

  @impl true
  def handle_call({:create_ai_session, session_id, session_data}, _from, state) do
    new_data = put_in(state.data, [:ai_sessions, session_id], session_data)

    # Update stats
    new_data = update_in(new_data, [:global, :stats, :total_sessions_created], &(&1 + 1))
    new_data = update_in(new_data, [:global, :stats, :active_sessions], &(&1 + 1))

    new_state = %{state | data: new_data}

    # Notify subscribers of new session
    notify_subscribers(new_state.subscribers, [:ai_sessions, session_id], session_data)
    notify_subscribers(new_state.subscribers, [:global, :stats], new_data.global.stats)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:create_terminal_session, session_id, session_data}, _from, state) do
    new_data = put_in(state.data, [:terminal_sessions, session_id], session_data)

    # Update stats
    new_data = update_in(new_data, [:global, :stats, :total_sessions_created], &(&1 + 1))
    new_data = update_in(new_data, [:global, :stats, :active_sessions], &(&1 + 1))

    new_state = %{state | data: new_data}

    # Notify subscribers
    notify_subscribers(new_state.subscribers, [:terminal_sessions, session_id], session_data)
    notify_subscribers(new_state.subscribers, [:global, :stats], new_data.global.stats)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update_ai_session_status, session_id, status}, _from, state) do
    case get_in(state.data, [:ai_sessions, session_id]) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      _session ->
        path = [:ai_sessions, session_id, :status]
        new_data = put_in(state.data, path, status)
        new_state = %{state | data: new_data}

        # Notify subscribers
        notify_subscribers(new_state.subscribers, path, status)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:remove_ai_session, session_id}, _from, state) do
    case get_in(state.data, [:ai_sessions, session_id]) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      _session ->
        new_data = update_in(state.data, [:ai_sessions], &Map.delete(&1, session_id))
        new_data = update_in(new_data, [:global, :stats, :active_sessions], &max(&1 - 1, 0))

        new_state = %{state | data: new_data}

        # Notify subscribers
        notify_subscribers(new_state.subscribers, [:ai_sessions], new_data.ai_sessions)
        notify_subscribers(new_state.subscribers, [:global, :stats], new_data.global.stats)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:remove_terminal_session, session_id}, _from, state) do
    case get_in(state.data, [:terminal_sessions, session_id]) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      _session ->
        new_data = update_in(state.data, [:terminal_sessions], &Map.delete(&1, session_id))
        new_data = update_in(new_data, [:global, :stats, :active_sessions], &max(&1 - 1, 0))

        new_state = %{state | data: new_data}

        # Notify subscribers
        notify_subscribers(
          new_state.subscribers,
          [:terminal_sessions],
          new_data.terminal_sessions
        )

        notify_subscribers(new_state.subscribers, [:global, :stats], new_data.global.stats)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscriber
    new_subscribers = Enum.reject(state.subscribers, fn {sub_pid, _} -> sub_pid == pid end)
    new_state = %{state | subscribers: new_subscribers}

    {:noreply, new_state}
  end

  # Helper functions

  defp notify_subscribers(subscribers, changed_path, new_value) do
    Enum.each(subscribers, fn {pid, subscribed_path} ->
      if path_matches?(changed_path, subscribed_path) do
        send(pid, {:state_changed, changed_path, new_value})
      end
    end)
  end

  defp path_matches?(changed_path, subscribed_path) do
    # If subscribed to root ([]), get all changes
    # If changed path starts with subscribed path
    subscribed_path == [] or
      List.starts_with?(changed_path, subscribed_path)
  end
end
