defmodule MintWebsocketClient do
  @moduledoc """
  A behaviour module for implementing websocket clients.

  ## Example

      defmodule WS do
        use MintWebsocketClient

        def start_link(url, opts \\ []) do
          opts =
            opts
            |> Keyword.put_new(:name, __MODULE__)
            |> Keyword.put_new(:protocols, [:http1])

          MintWebsocketClient.start_link(url, __MODULE__, opts)
        end

        @impl true
        def handle_connect(status_map, state) do
          # subscribe
          message = ~s|{"action": "subscribe"}|

          {:reply, {:text, message}, state}
        end

        @impl true
        def handle_disconnect(reason, state) do
          # notify about disconnect
          {:reconnect, state}
        end

        @impl true
        def handle_frame(frame, state) do
          # do handle frame
          {:ok, state}
        end

        @impl true
        def terminate(reason, _state) do
          # do some cleanup if necessary
        end
      end

  We leave all the hussle of opening/closing/reconnecting details to the MintWebsocketClient
  behaviour and focus only on the callback implementation. We can now use the MintWebsocketClient API to
  interact with the remote websocket service.

      # Start the process
      {:ok, pid} = WS.start_link("wss://feed.exchange.com/")

      # Sends :ping frame to the server
      MintWebsocketClient.send_frame(pid, :ping)
      #=> :ok

      # Casts request to the WS process
      MintWebsocketClient.cast(pid, {:send_message, "elixir"})
      #=> :ok

  > #### `use Websocket` {: .info}
  >
  > When you `use MintWebsocketClient`, the `MintWebsocketClient` module will
  > set `@behaviour MintWebsocketClient` and define a `child_spec/1`
  > function, so your module can be used as a child
  > in a supervision tree.
  """

  @doc """
  Invoked in process init.

  Good place to initialize state and setup process flags.

  This callback is optional. If one is not implemented, the default implementation
  will return `{:ok, nil}`.
  """
  @callback init(opts :: term()) ::
              {:ok, state :: term()}

  @doc """
  Invoked once the new ws connection established.

  Returning `{:ok, new_state}` continues the loop with new state `new_state`.

  Returning `{:reply, frame, new_state}` sends the websocket `frame` to the
  server and continues the loop with new state `new_state`.
  """
  @callback handle_connect(status_map :: map(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state :: term()}

  @doc """
  Invoked once the ws connection lost.

  Returning `{:ok, new_state}` continues the loop with new state `new_state`.

  Returning `{:reconnect, timeout, new_state}` does reconnect to the server after specific timeout and
  continues the loop with new state `new_state`.

  Returning `{:reconnect, new_state}` does reconnect to the server immediately and
  continues the loop with new state `new_state`.
  """
  @callback handle_disconnect(reason :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reconnect, timeout :: timeout(), new_state :: term()}
              | {:reconnect, new_state :: term()}

  @doc """
  Invoked once the new websocket frame received.

  Returning `{:ok, new_state}` continues the loop with new state `new_state`.

  Returning `{:reply, frame, new_state}` sends the websocket `frame` to the
  server and continues the loop with new state `new_state`.
  """
  @callback handle_frame(frame :: Mint.WebSocket.frame(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state :: term()}

  @doc """
  Invoked to handle asynchronous `cast/2` messages.

  Returning `{:ok, new_state}` continues the loop with new state `new_state`.

  Returning `{:reply, frame, new_state}` sends the websocket `frame` to the
  server and continues the loop with new state `new_state`.

  Returning `{:close, frame, new_state}` tries to close the connection gracefully
  sending websocket `frame` and waiting 5 seconds before actually close connection
  and continues the loop with new state `new_state`.

  Returning `{:close, new_state}` close the connection immediately
  and continues the loop with new state `new_state`.

  This callback is optional. If one is not implemented, the default implementation
  will return `{:ok, new_state}`.
  """
  @callback handle_cast(request :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state :: term()}
              | {:close, frame :: Mint.WebSocket.frame(), new_state :: term()}
              | {:close, new_state :: term()}

  @doc """
  Invoked to handle all other messages.

  Return values are the same as `c:handle_cast/2`.

  This callback is optional. If one is not implemented, the default implementation
  will return `{:ok, new_state}`.
  """
  @callback handle_info(message :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state :: term()}
              | {:close, frame :: Mint.WebSocket.frame(), new_state :: term()}
              | {:close, new_state :: term()}

  @doc """
  Invoked when the server is about to exit. It should do any cleanup required.

  This callback is optional.
  """
  @callback terminate(reason :: term(), state :: term()) :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour MintWebsocketClient

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]}
        }
      end

      defoverridable child_spec: 1

      @impl true
      def init(_opts) do
        {:ok, nil}
      end

      @impl true
      def handle_cast(_request, state) do
        {:ok, state}
      end

      @impl true
      def handle_info(_message, state) do
        {:ok, state}
      end

      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      defoverridable init: 1, handle_cast: 2, handle_info: 2, terminate: 2
    end
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            uri: URI.t(),
            conn: Mint.HTTP.t(),
            request_ref: Mint.Types.request_ref(),
            websocket: Mint.WebSocket.t(),
            status: Mint.Types.status(),
            headers: Mint.Types.headers(),
            handler: module(),
            handler_state: term(),
            closing?: boolean(),
            timer: reference(),
            opts: keyword()
          }

    defstruct uri: nil,
              conn: nil,
              request_ref: nil,
              websocket: nil,
              status: nil,
              headers: nil,
              handler: nil,
              handler_state: nil,
              closing?: false,
              timer: nil,
              opts: []
  end

  use GenServer

  require Logger

  @doc """
  Starts the `MintWebsocketClient` process linked to the current process.

  ## Options

    * `:name` - used for name registration

    All available options see `Mint.HTTP.connect/4`.
  """
  @spec start_link(
          url :: String.t() | URI.t(),
          handler :: module(),
          opts :: [{:name, atom()} | Keyword.t()]
        ) :: GenServer.on_start()
  def start_link(url, handler, opts \\ []) do
    server_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {url, handler, opts}, server_opts)
  end

  @doc """
  Sends frame to the websocket server.
  """
  @spec send_frame(server :: GenServer.server(), frame :: Mint.WebSocket.frame()) ::
          :ok
          | {:error, :disconnected}
          | {:error, Mint.WebSocket.t(), any()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def send_frame(server \\ __MODULE__, frame) do
    GenServer.call(server, {:"$websocket", frame})
  end

  @doc """
  Casts request to the underlying process.
  """
  @spec cast(server :: GenServer.server(), request :: term()) :: :ok
  def cast(server \\ __MODULE__, request) do
    GenServer.cast(server, {:"$websocket", request})
  end

  @impl true
  def init({url, handler, opts}) do
    {:ok, handler_state} = apply(handler, :init, [opts])

    state = %State{
      uri: URI.parse(url),
      opts: opts,
      handler: handler,
      handler_state: handler_state
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %State{uri: uri} = state) do
    http_scheme =
      case uri.scheme do
        "ws" -> :http
        "wss" -> :https
      end

    ws_scheme =
      case uri.scheme do
        "ws" -> :ws
        "wss" -> :wss
      end

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, state.opts),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, uri.path, []) do
      {:noreply, %{state | conn: conn, request_ref: ref}}
    else
      {:error, error} ->
        {:noreply, dispatch(state, :handle_disconnect, [error])}

      {:error, conn, error} ->
        state = %{state | conn: conn}
        {:noreply, dispatch(state, :handle_disconnect, [error])}
    end
  end

  @impl true
  def handle_call({:"$websocket", frame}, _from, %State{} = state)
      when not is_nil(state.conn) and not is_nil(state.websocket) do
    case stream_frame(state, frame) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, state, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:"$websocket", _frame}, _from, %State{} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_cast({:"$websocket", request}, %State{} = state) do
    {:noreply, dispatch(state, :handle_cast, [request])}
  end

  @impl true
  def handle_info({:"$websocket", :connect}, state) do
    state = %{
      state
      | conn: nil,
        request_ref: nil,
        websocket: nil,
        status: nil,
        headers: nil,
        closing?: false
    }

    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:"$websocket", {:close, frame}}, %State{} = state) do
    {:ok, conn} = Mint.HTTP.close(state.conn)
    state = %{state | conn: conn, closing?: true, timer: nil}
    state = dispatch(state, :handle_disconnect, [frame])
    {:noreply, state}
  end

  def handle_info(http_reply, %State{} = state)
      when is_tuple(http_reply) and
             elem(http_reply, 0) in [:tcp, :ssl, :tcp_closed, :ssl_closed, :tcp_error, :ssl_error] do
    {:noreply, process_http_reply(http_reply, state)}
  end

  def handle_info(message, state) do
    {:noreply, dispatch(state, :handle_info, [message])}
  end

  @impl true
  def terminate(reason, %State{conn: conn} = state) do
    unless is_nil(conn) do
      _ = stream_frame(state, :close)
      Mint.HTTP.close(conn)
    end

    dispatch(state, :terminate, [reason])
  end

  # Private

  # we skip http_reply not for current active socket
  defp process_http_reply(http_reply, %State{conn: %{socket: socket}, closing?: false} = state)
       when is_tuple(http_reply) and elem(http_reply, 1) == socket do
    case Mint.WebSocket.stream(state.conn, http_reply) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        Enum.reduce(responses, state, &process_response/2)

      {:error, conn, error, responses} ->
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &process_response/2)
        dispatch(state, :handle_disconnect, [error])

      :unknown ->
        state
    end
  end

  # we ignore http_replys in closing state or from wrong socket
  defp process_http_reply(_http_reply, %State{} = state) do
    state
  end

  defp process_response(response, state)

  defp process_response({:status, ref, status}, %{request_ref: ref} = state) do
    %{state | status: status}
  end

  defp process_response({:headers, ref, headers}, %{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
      {:ok, conn, websocket} ->
        %{state | conn: conn, websocket: websocket, status: nil, headers: nil}
        |> dispatch(:handle_connect, [%{status: state.status, headers: headers}])

      {:error, conn, error} ->
        %{state | conn: conn, websocket: nil, status: nil, headers: nil}
        |> dispatch(:handle_disconnect, [error])
    end
  end

  # we skip data if no websocket to decode it
  defp process_response({:data, ref, _data}, %{request_ref: ref, websocket: nil} = state) do
    state
  end

  defp process_response({:data, ref, data}, %{request_ref: ref, websocket: websocket} = state) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &handle_frame/2)

      {:error, websocket, error} ->
        Logger.error(["[Websocket] decoding error: ", inspect(error)])

        %{state | websocket: websocket}
    end
  end

  defp process_response({:done, ref}, %{request_ref: ref} = state) do
    state
  end

  defp process_response(response, %{request_ref: ref} = state) do
    Logger.warning([
      "[Websocket] got unexpected response: ",
      inspect(response),
      "\nrequest_ref: ",
      inspect(ref)
    ])

    state
  end

  defp handle_frame({:close, _code, _reason}, %State{} = state) do
    maybe_purge_close_timer(state)
  end

  defp handle_frame(frame, %State{} = state) do
    dispatch(state, :handle_frame, [frame])
  end

  # Invokes an implementations callbacks
  defp dispatch(%State{handler: handler, handler_state: handler_state} = state, function, args) do
    case apply(handler, function, args ++ [handler_state]) do
      {:ok, handler_state}
      when function in [
             :handle_connect,
             :handle_disconnect,
             :handle_frame,
             :handle_cast,
             :handle_info
           ] ->
        %{state | handler_state: handler_state}

      {:reply, frame, handler_state}
      when function in [
             :handle_connect,
             :handle_frame,
             :handle_cast,
             :handle_info
           ] ->
        # streaming the frame may fail if server already closed connection.
        _ = stream_frame(state, frame)
        %{state | handler_state: handler_state}

      {:close, {code, reason}, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        frame = {:close, code, reason}
        # streaming the frame may fail if server already closed connection.
        _ = stream_frame(state, frame)
        timer = Process.send_after(self(), {:"$websocket", {:close, frame}}, :timer.seconds(5))
        %{state | timer: timer, handler_state: handler_state}

      {:close, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        frame = :close
        # streaming the frame may fail if server already closed connection.
        _ = stream_frame(state, frame)
        timer = Process.send_after(self(), {:"$websocket", {:close, frame}}, :timer.seconds(5))
        %{state | timer: timer, handler_state: handler_state}

      {:reconnect, timeout, handler_state}
      when function == :handle_disconnect ->
        Process.send_after(self(), {:"$websocket", :connect}, timeout)
        %{state | handler_state: handler_state}

      {:reconnect, handler_state}
      when function == :handle_disconnect ->
        Process.send(self(), {:"$websocket", :connect}, [])
        %{state | handler_state: handler_state}

      _any when function == :terminate ->
        state
    end
  end

  defp stream_frame(state, _frame) when is_nil(state.conn) or is_nil(state.websocket),
    do: {:error, state, :disconnected}

  defp stream_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        state = %{state | websocket: websocket}

        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, conn, error} -> {:error, %{state | conn: conn}, error}
        end

      {:error, websocket, error} ->
        {:error, %{state | websocket: websocket}, error}
    end
  end

  defp maybe_purge_close_timer(%State{timer: nil} = state), do: state

  defp maybe_purge_close_timer(%State{timer: ref} = state) do
    case Process.cancel_timer(ref) do
      i when is_integer(i) ->
        :ok

      false ->
        receive do
          {:"$websocket", {:close, _frame}} -> :ok
        after
          100 -> :ok
        end
    end

    %{state | timer: nil}
  end
end
