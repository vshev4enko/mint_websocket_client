# Websocket

[![CI](https://github.com/vshev4enko/websocket/actions/workflows/ci.yml/badge.svg)](https://github.com/vshev4enko/websocket/actions/workflows/ci.yml)

Websocket is a behaviour for implementing websocket clients.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `websocket` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:websocket, "~> 0.1.0"}
  ]
end
```

## Usage

Keep in mind all frames you return in `{:reply, frame, state}` might be lost depends on connection state.

```elixir
defmodule WS do
  use Websocket

  def start_link(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.put_new(:transport_opts, verify: :verify_none)

    Websocket.start_link("wss://feed.exchange.com/", __MODULE__, opts)
  end

  @impl true
  def handle_connect(_conn, state) do
    # subscribe
    text = ~s|{"action": "subscribe"}|

    {:reply, {:text, text}, state}
  end

  @impl true
  def handle_disconnect(_reason, state) do
    # notify about disconnect
    {:reconnect, state}
  end

  @impl true
  def handle_frame(frame, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # do some cleanup if necessary
  end
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/websocket>.

