defmodule Websocket do
  @moduledoc """
  A behaviour module for implementing the websocket clients.
  """

  @callback init(opts :: term()) ::
              {:ok, state :: term()}
  @callback handle_connect(conn :: Mint.HTTP.t(), state :: term()) ::
              {:ok, state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), state :: term()}
  @callback handle_disconnect(reason :: term(), state :: term()) ::
              {:ok, state :: term()}
              | {:reconnect, state :: term()}
              | {:reconnect, timeout :: timeout(), state :: term()}
  @callback handle_frame(frame :: Mint.WebSocket.frame(), state :: term()) ::
              {:ok, state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), state :: term()}
  @callback handle_cast(request :: term(), state :: term()) ::
              {:ok, state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), state :: term()}
              | {:close, state :: term()}
              | {:close, frame :: Mint.WebSocket.frame(), state :: term()}
  @callback handle_info(message :: term(), state :: term()) ::
              {:ok, state :: term()}
              | {:reply, frame :: Mint.WebSocket.frame(), state :: term()}
              | {:close, state :: term()}
              | {:close, frame :: Mint.WebSocket.frame(), state :: term()}
  @callback terminate(reason :: term(), state :: term()) :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour Websocket

      def child_spec(init_arg) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }
      end

      defoverridable child_spec: 1

      @impl true
      def init(opts) do
        {:ok, opts}
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
            ref: Mint.Types.request_ref(),
            websocket: Mint.WebSocket.t(),
            handler: module(),
            handler_state: term(),
            timer: reference(),
            opts: keyword()
          }

    defstruct uri: nil,
              conn: nil,
              ref: nil,
              websocket: nil,
              handler: nil,
              handler_state: nil,
              timer: nil,
              opts: []
  end

  use GenServer

  require Logger

  @doc """
  Starts the `Websocket` process linked to the current process.

  ## Options

    * `:name` - used for name registration

    All available options see Mint.HTTP.connect/4.
  """
  @spec start_link(
          url :: String.t() | URI.t(),
          handler :: module(),
          opts :: [{:name, atom()} | Keyword.t()]
        ) :: GenServer.on_start()
  def start_link(url, handler, opts) do
    server_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {url, handler, opts}, server_opts)
  end

  @doc """
  Sends a frame to the server.
  """
  @spec send_frame(client :: GenServer.server(), frame :: Mint.WebSocket.frame()) ::
          :ok
          | {:error, :disconnected}
          | {:error, Mint.WebSocket.t(), any()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def send_frame(client \\ __MODULE__, frame) do
    GenServer.call(client, {:"$websocket", frame})
  end

  @doc """
  Casts a request to the ws client.
  """
  @spec cast(client :: GenServer.server(), request :: term()) :: :ok
  def cast(client \\ __MODULE__, request) do
    GenServer.cast(client, {:"$websocket", request})
  end

  @impl true
  def init({url, handler, opts}) do
    {:ok, handler_state} = apply(handler, :init, [opts])

    opts = Keyword.drop(opts, [:name])

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
    case Mint.HTTP.connect(http_scheme(uri), uri.host, uri.port, state.opts) do
      {:ok, conn} ->
        {:noreply, Map.put(state, :conn, conn), {:continue, :upgrade}}

      {:error, error} ->
        {:noreply, dispatch(state, :handle_disconnect, [error])}
    end
  end

  def handle_continue(:upgrade, %State{uri: uri, conn: conn} = state) do
    case Mint.WebSocket.upgrade(ws_scheme(uri), conn, uri.path, []) do
      {:ok, conn, ref} ->
        {:noreply, state |> Map.put(:conn, conn) |> Map.put(:ref, ref)}

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:noreply, state |> Map.put(:conn, nil) |> dispatch(:handle_disconnect, [error])}
    end
  end

  @impl true
  def handle_call({:"$websocket", frame}, _from, %State{conn: conn, websocket: websocket} = state)
      when not is_nil(conn) and not is_nil(websocket) do
    {reply, state} =
      case Mint.WebSocket.encode(websocket, frame) do
        {:ok, websocket, data} ->
          case Mint.WebSocket.stream_request_body(conn, state.ref, data) do
            {:ok, conn} ->
              {:ok, state |> Map.put(:conn, conn) |> Map.put(:websocket, websocket)}

            {:error, conn, error} ->
              {{:error, error}, state |> Map.put(:conn, conn) |> Map.put(:websocket, websocket)}
          end

        {:error, websocket, error} ->
          {{:error, error}, state |> Map.put(:websocket, websocket)}
      end

    {:reply, reply, state}
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
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:"$websocket", :close}, %State{conn: conn} = state) do
    Mint.HTTP.close(conn)

    state =
      state
      |> Map.put(:conn, nil)
      |> Map.put(:timer, nil)
      |> Map.put(:websocket, nil)
      |> dispatch(:handle_disconnect, [{:local, :closed}])

    {:noreply, state}
  end

  def handle_info(http_reply, %State{} = state)
      when is_tuple(http_reply) and
             elem(http_reply, 0) in [:tcp, :ssl, :tcp_closed, :ssl_closed, :tcp_error, :ssl_error] do
    {:noreply, do_handle_http_reply(state, http_reply)}
  end

  def handle_info(message, state) do
    {:noreply, dispatch(state, :handle_info, [message])}
  end

  @impl true
  def terminate(reason, %State{conn: conn} = state) do
    unless is_nil(conn), do: Mint.HTTP.close(conn)
    dispatch(state, :terminate, [reason])
  end

  # Private

  # ignore all transport messages in disconnected state
  defp do_handle_http_reply(%State{conn: nil} = state, _http_reply), do: state

  defp do_handle_http_reply(%State{conn: conn} = state, http_reply)
       when elem(http_reply, 1) == conn.socket do
    case Mint.WebSocket.stream(state.conn, http_reply) do
      {:ok, conn, response} ->
        state
        |> Map.put(:conn, conn)
        |> handle_response(response)

      {:error, conn, error, _response} ->
        Mint.HTTP.close(conn)

        state
        |> Map.put(:conn, nil)
        |> Map.put(:websocket, nil)
        |> purge_timer({:"$websocket", :close})
        |> dispatch(:handle_disconnect, [error])

      :unknown ->
        Logger.warning("Websocket stream unknown message: #{inspect(http_reply)}")
        state
    end
  end

  defp do_handle_http_reply(%State{conn: conn} = state, http_reply) do
    Logger.warning(
      "Websocket got reply from wrong socket reply: #{inspect(http_reply)}, socket: #{inspect(conn.socket)}"
    )

    state
  end

  defp handle_response(%State{} = state, []), do: state

  defp handle_response(%State{conn: conn, ref: ref} = state, [
         {:status, ref, status},
         {:headers, ref, headers} | response
       ]) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        state
        |> Map.put(:conn, conn)
        |> Map.put(:websocket, websocket)
        |> dispatch(:handle_connect, [conn])
        |> handle_response(response)

      {:error, conn, error} ->
        Mint.HTTP.close(conn)

        state
        |> Map.put(:conn, nil)
        |> Map.put(:websocket, nil)
        |> dispatch(:handle_disconnect, [error])
    end
  end

  defp handle_response(%State{ref: ref, websocket: websocket} = state, [
         {:data, ref, data} | response
       ]) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state
        |> Map.put(:websocket, websocket)
        |> handle_frames(frames)
        |> handle_response(response)

      {:error, websocket, error} ->
        Logger.warning("Websocket decode error: #{inspect(error)}")

        state
        |> Map.put(:websocket, websocket)
        |> handle_response(response)
    end
  end

  defp handle_response(%State{ref: ref} = state, [{:done, ref} | response]) do
    handle_response(state, response)
  end

  defp handle_response(%State{ref: ref} = state, [{:error, ref, reason} | response]) do
    Logger.warning("Websocket got an error response: #{inspect(reason)}")

    handle_response(state, response)
  end

  # http2 responses
  defp handle_response(%State{ref: ref} = state, [{:pong, ref} | response]) do
    handle_response(state, response)
  end

  defp handle_response(%State{ref: ref} = state, [
         {:push_promise, ref, _pref, _headers} | response
       ]) do
    handle_response(state, response)
  end

  defp handle_response(%State{ref: ref} = state, [item | response]) do
    Logger.warning(
      "Websocket response mismatch ref: #{inspect(ref)}, reponse item: #{inspect(item)}"
    )

    handle_response(state, response)
  end

  defp handle_frames(%State{} = state, []), do: state

  defp handle_frames(%State{} = state, [{:close, _code, _reason} | frames]) do
    state
    |> purge_timer({:"$websocket", :close})
    |> handle_frames(frames)
  end

  defp handle_frames(%State{} = state, [frame | frames]) do
    state
    |> dispatch(:handle_frame, [frame])
    |> handle_frames(frames)
  end

  # Invokes an implementations callbacks
  # credo:disable-for-next-line
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
        Map.put(state, :handler_state, handler_state)

      {:reply, frame, handler_state}
      when function in [
             :handle_connect,
             :handle_frame,
             :handle_cast,
             :handle_info
           ] ->
        state
        |> stream_request_body(frame)
        |> Map.put(:handler_state, handler_state)

      {:close, {code, reason}, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        state
        |> stream_request_body({:close, code, reason})
        |> Map.put(:timer, Process.send_after(self(), {:"$websocket", :close}, :timer.seconds(5)))
        |> Map.put(:handler_state, handler_state)

      {:close, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        state
        |> stream_request_body(:close)
        |> Map.put(:timer, Process.send_after(self(), {:"$websocket", :close}, :timer.seconds(5)))
        |> Map.put(:handler_state, handler_state)

      {:reconnect, timeout, handler_state}
      when function == :handle_disconnect ->
        Process.send_after(self(), {:"$websocket", :connect}, timeout)
        Map.put(state, :handler_state, handler_state)

      {:reconnect, handler_state}
      when function == :handle_disconnect ->
        Process.send(self(), {:"$websocket", :connect}, [])
        Map.put(state, :handler_state, handler_state)

      _any when function == :terminate ->
        state
    end
  end

  # we ignore frame streaming if error occured or connection was not established
  defp stream_request_body(%State{conn: conn, websocket: websocket} = state, frame)
       when not is_nil(conn) and not is_nil(websocket) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)

    {:ok, conn} =
      with {:error, conn, error} <- Mint.WebSocket.stream_request_body(conn, state.ref, data) do
        Logger.warning("Websocket stream_request_body error: #{inspect(error)}")
        {:ok, conn}
      end

    state
    |> Map.put(:conn, conn)
    |> Map.put(:websocket, websocket)
  end

  defp stream_request_body(%State{} = state, _frame), do: state

  defp http_scheme(%URI{scheme: "ws"}), do: :http
  defp http_scheme(%URI{scheme: "wss"}), do: :https

  defp ws_scheme(%URI{scheme: "ws"}), do: :ws
  defp ws_scheme(%URI{scheme: "wss"}), do: :wss

  defp purge_timer(%State{timer: nil} = state, _msg), do: state

  defp purge_timer(%State{timer: ref} = state, msg) do
    case Process.cancel_timer(ref) do
      i when is_integer(i) ->
        :ok

      false ->
        receive do
          ^msg -> :ok
        after
          100 -> :ok
        end
    end

    Map.put(state, :timer, nil)
  end
end
