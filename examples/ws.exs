Mix.install([{:mint_websocket_client, path: "."}, :castore])

import ExUnit.Assertions

defmodule WS do
  use MintWebsocketClient

  def start_link(url, opts \\ []) do
    MintWebsocketClient.start_link(url, __MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, %{send_to: Keyword.fetch!(opts, :send_to)}}
  end

  @impl true
  def handle_connect(status_map, state) do
    IO.puts("Connected #{inspect(status_map)}")
    send(state.send_to, {:connected, status_map})
    {:reply, {:text, ~s|{"message": "Hello World!"}|}, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    IO.puts("Disconnected #{inspect(reason)}")
    send(state.send_to, {:disconnected, reason})
    {:reconnect, :timer.seconds(5), state}
  end

  @impl true
  def handle_frame(frame, state) do
    IO.puts("Got frame #{inspect(frame)}")
    send(state.send_to, frame)
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    IO.puts("Terminating #{inspect(reason)}")
    send(state.send_to, {:terminate, reason})
  end
end

{:ok, pid} = WS.start_link("wss://ws.postman-echo.com/raw", protocols: [:http1], send_to: self())
assert_receive {:connected, _}, 1000

assert_receive {:text, _}, 1000

MintWebsocketClient.send_frame(pid, :ping)
assert_receive {:pong, _}, 1000

MintWebsocketClient.send_frame(pid, {:text, ~s|{"hello": "world"}|})
assert_receive {:text, _}, 1000

MintWebsocketClient.send_frame(pid, :close)
assert_receive {:disconnected, _}, 1000

GenServer.stop(pid)
assert_receive {:terminate, _}, 1000
