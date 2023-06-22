# MintWebsocketClient

[![CI](https://github.com/vshev4enko/mint_websocket_client/actions/workflows/ci.yml/badge.svg)](https://github.com/vshev4enko/mint_websocket_client/actions/workflows/ci.yml)

Behaviour module built on top of GenServer to build processfull websocket client
using [Mint](https://hex.pm/packages/mint) and [Mint.WebSocket](https://hex.pm/packages/mint_web_socket)
to establish and maintain the Websocket connection.

## Usage

Add `mint_websocket_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mint_websocket_client, "~> 0.1.0"}
  ]
end
```

Next, run mix deps.get in your shell to fetch and compile MintWebsocketClient. Start an interactive Elixir shell with iex -S mix:

# Examples

Keep in mind all frames you return in `{:reply, frame, state}` might be lost depends on connection state.

```elixir
defmodule WS do
  use MintWebsocketClient

  def start_link(url, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.put_new(:transport_opts, [verify: :verify_none])

    MintWebsocketClient.start_link(url, __MODULE__, opts)
  end

  @impl true
  def handle_connect(status_map, state) do
    IO.inspect(status_map, label: "handle_connect")
    {:ok, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    IO.inspect(reason, label: "handle_disconnect")
    {:reconnect, state}
  end

  @impl true
  def handle_frame(frame, state) do
    IO.inspect(frame, label: "handle_frame")
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    IO.inspect(reason, label: "terminate")
  end
end

iex(1)> {:ok, pid} = WS.start_link("wss://ws.postman-echo.com/raw")
{:ok, #PID<0.207.0>}
handle_connect: %{
  headers: [...],
  status: 101
}

iex(2)> MintWebsocketClient.send_frame(pid, :ping)
:ok
handle_frame: {:pong, ""}

iex(3)> MintWebsocketClient.send_frame(pid, :close)
:ok
handle_disconnect: %Mint.TransportError{reason: :closed}

iex(4)> MintWebsocketClient.send_frame(pid, {:text, "{\"lang\":\"elixir\"}"})
:ok
handle_frame: {:text, "{\"lang\":\"elixir\"}"}
```
