defmodule Exterm.Router do
  use Plug.Router

  plug(Plug.Logger)
  plug(Plug.Static, at: "/", from: "priv/static")
  plug(:match)
  plug(:dispatch)

  # Serve static files
  get "/" do
    send_file(conn, 200, "priv/static/index.html")
  end

  # WebSocket upgrade endpoint
  get "/ws" do
    conn
    |> Plug.Conn.upgrade_adapter(:websocket, {Exterm.TerminalSocket, [], %{}})
  end

  # Chat WebSocket upgrade endpoint
  get "/chat_ws" do
    conn
    |> Plug.Conn.upgrade_adapter(:websocket, {Exterm.ChatSocket, [], %{}})
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
