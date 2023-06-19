if Code.ensure_loaded?(:cowboy) do
  defmodule Websocket.TestServer do
    @moduledoc false

    @behaviour :cowboy_websocket

    @port 8080

    def send_frame(name \\ __MODULE__, frame) do
      send(name, {:send_frame, frame})
    end

    def child_spec(opts) do
      opts = Keyword.put_new(opts, :port, @port)
      opts = Keyword.put_new(opts, :name, __MODULE__)

      {send_to, opts} = Keyword.pop!(opts, :send_to)
      {name, opts} = Keyword.pop!(opts, :name)

      so_reuseport =
        case :os.type() do
          {:unix, :linux} -> [{:raw, 0x1, 0xF, <<1::32-native>>}]
          {:unix, :darwin} -> [{:raw, 0xFFFF, 0x0200, <<1::32-native>>}]
          _ -> []
        end

      state = %{send_to: send_to, name: name}
      dispatch = :cowboy_router.compile([{:_, [{:_, __MODULE__, state}]}])

      :ranch.child_spec(
        make_ref(),
        :ranch_tcp,
        opts ++ so_reuseport,
        :cowboy_clear,
        %{env: %{dispatch: dispatch}}
      )
    end

    @impl true
    def init(req, state) do
      {:cowboy_websocket, req, state}
    end

    @impl true
    def websocket_init(state) do
      Process.register(self(), state.name)
      {[], state}
    end

    @impl true
    def websocket_handle(frame, state) do
      send(state.send_to, {:ws_server_frame, frame})
      {[], state}
    end

    @impl true
    def websocket_info({:send_frame, frame}, state) do
      {List.wrap(frame), state}
    end

    @impl true
    def terminate(reason, _req, state) do
      send(state.send_to, {:ws_server_terminate, reason})
      :ok
    end
  end
end
