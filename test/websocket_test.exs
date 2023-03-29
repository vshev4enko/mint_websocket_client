defmodule WebsocketTest do
  use ExUnit.Case

  alias Websocket.TestServer

  defmodule TestClient do
    use Websocket

    def start_link(opts) do
      Websocket.start_link(opts[:url], __MODULE__, Keyword.put_new(opts, :name, __MODULE__))
    end

    def send_frame(client \\ __MODULE__, frame) do
      Websocket.send_frame(client, frame)
    end

    def cast(client \\ __MODULE__, request) do
      Websocket.cast(client, request)
    end

    @impl true
    def init(opts) do
      # we need this to invoke `terminate/2` on shutdown
      Process.flag(:trap_exit, true)
      state = %{send_to: opts[:send_to]}
      {:ok, state}
    end

    @impl true
    def handle_connect(conn, state) do
      send(state.send_to, {:ws_client_connect, conn})
      {:reply, {:text, "{\"action\":\"subscribe\"}"}, state}
    end

    @impl true
    def handle_disconnect(reason, state) do
      send(state.send_to, {:ws_client_disconnect, reason})
      {:reconnect, state}
    end

    @impl true
    def handle_frame(frame, state) do
      send(state.send_to, {:ws_client_frame, frame})
      {:ok, state}
    end

    @impl true
    def handle_cast({:close, code, reason}, state) do
      {:close, {code, reason}, state}
    end

    @impl true
    def handle_cast({:reply, frame}, state) do
      {:reply, frame, state}
    end

    @impl true
    def terminate(reason, state) do
      send(state.send_to, {:ws_client_terminate, reason})
    end
  end

  setup tags do
    port = 8001
    send_to = self()
    start_supervised!({TestClient, send_to: send_to, url: "ws://localhost:#{port}/"})
    start_supervised!({TestServer, send_to: send_to, port: port})
    if tags[:connected], do: assert_receive({:ws_client_connect, _conn}, 1000)
    :ok
  end

  test "handle_connect" do
    assert_receive {:ws_client_connect, _conn}, 1000
    assert_receive {:ws_server_frame, {:text, "{\"action\":\"subscribe\"}"}}
  end

  @tag :connected
  test "client initiates closing" do
    TestClient.cast({:close, 4000, "local close"})
    assert_receive {:ws_client_disconnect, %Mint.TransportError{reason: :closed}}
    assert_receive {:ws_server_terminate, {:remote, 4000, "local close"}}
  end

  @tag :connected
  test "server initiates closing" do
    TestServer.send_frame({:close, 4000, "remote close"})
    assert_receive {:ws_client_disconnect, %Mint.TransportError{reason: :closed}}
    assert_receive {:ws_server_terminate, :stop}
  end

  test "client in disconnected state" do
    assert {:error, :disconnected} = TestClient.send_frame(:ping)
  end

  @tag :connected
  test "client in connected state" do
    assert :ok = TestClient.send_frame(:ping)
    assert_receive {:ws_server_frame, :ping}
    assert_receive {:ws_client_frame, {:pong, ""}}
  end

  test "drops frame if disconnected" do
    TestClient.cast({:reply, {:text, "hello there"}})
    refute_receive {:ws_server_frame, {:text, "hello there"}}
  end

  @tag :connected
  test "send frame to the server on :reply" do
    TestClient.cast({:reply, {:text, "hello there"}})
    assert_receive {:ws_server_frame, {:text, "hello there"}}
  end

  test "invokes terminate on shutdown" do
    :ok = stop_supervised(TestClient)
    assert_receive {:ws_client_terminate, :shutdown}
  end
end
