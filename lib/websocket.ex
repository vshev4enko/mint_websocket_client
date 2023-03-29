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
            connected: boolean(),
            handler: module(),
            handler_state: term(),
            timer: reference(),
            opts: keyword()
          }

    defstruct uri: nil,
              conn: nil,
              ref: nil,
              websocket: nil,
              connected: false,
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
    {server_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {url, handler, opts}, server_opts)
  end

  # TODO: If you gonna use ws extensions or ws over http2 you should update
  # conn and websocket state every frame, in order to do that implement send_frame via
  # process `handle_cast/2 -> {:reply, frame, state}` callback.
  @spec send_frame(GenServer.server(), Mint.WebSocket.frame()) ::
          :ok
          | {:error, :disconnected}
          | {:error, Mint.WebSocket.t(), any()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def send_frame(client \\ __MODULE__, frame) do
    with {:ok, {conn, ref, websocket}} <- GenServer.call(client, :get_connection),
         {:ok, _websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, _conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      :ok
    end
  end

  @spec cast(GenServer.server(), term()) :: :ok
  def cast(client \\ __MODULE__, message) do
    GenServer.cast(client, {:cast, message})
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
  def handle_continue(:connect, %State{uri: uri, conn: conn} = state) do
    if not is_nil(conn) and Mint.HTTP.open?(conn) do
      {:noreply, state, {:continue, :upgrade}}
    else
      case Mint.HTTP.connect(http_scheme(uri), uri.host, uri.port, state.opts) do
        {:ok, conn} ->
          {:noreply, Map.put(state, :conn, conn), {:continue, :upgrade}}

        {:error, error} ->
          {:noreply, dispatch(state, :handle_disconnect, [error])}
      end
    end
  end

  def handle_continue(:upgrade, %State{uri: uri, conn: conn} = state) do
    case Mint.WebSocket.upgrade(ws_scheme(uri), conn, uri.path, []) do
      {:ok, conn, ref} ->
        {:noreply, state |> Map.put(:conn, conn) |> Map.put(:ref, ref)}

      {:error, conn, error} ->
        {:noreply, state |> Map.put(:conn, conn) |> dispatch(:handle_disconnect, [error])}
    end
  end

  @impl true
  def handle_call(:get_connection, _from, %State{connected: true} = state) do
    {:reply, {:ok, {state.conn, state.ref, state.websocket}}, state}
  end

  def handle_call(:get_connection, _from, %State{} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_cast({:cast, request}, %State{} = state) do
    {:noreply, dispatch(state, :handle_cast, [request])}
  end

  @impl true
  def handle_info({:internal, :connect}, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:internal, :close}, %State{conn: conn} = state) do
    if conn, do: Mint.HTTP.close(conn)
    {:noreply, state |> Map.put(:timer, nil) |> dispatch(:handle_disconnect, [{:local, :close}])}
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

  defp do_handle_http_reply(%State{conn: conn} = state, http_reply) do
    case Mint.WebSocket.stream(conn, http_reply) do
      {:ok, conn, response} ->
        state
        |> Map.put(:conn, conn)
        |> handle_response(response)

      {:error, conn, error, response} ->
        state
        |> handle_response(response)
        |> Map.put(:conn, conn)
        |> Map.put(:connected, false)
        |> dispatch(:handle_disconnect, [error])

      :unknown ->
        Logger.warning("Websocket got an unknown message, #{inspect(http_reply)}")
        state
    end
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
        |> Map.put(:connected, true)
        |> dispatch(:handle_connect, [conn])
        |> handle_response(response)

      {:error, conn, error} ->
        state
        |> Map.put(:conn, conn)
        |> Map.put(:connected, false)
        |> dispatch(:handle_disconnect, [error])
        |> handle_response(response)
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
        Logger.warning("Websocket decode error: #{error}")

        state
        |> Map.put(:websocket, websocket)
        |> handle_response(response)
    end
  end

  defp handle_response(%State{ref: ref} = state, [{:done, ref} | response]) do
    handle_response(state, response)
  end

  defp handle_response(%State{ref: ref} = state, [{:error, ref, reason} | response]) do
    Logger.warning("Websocket got an error frame: #{reason}")

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

  defp handle_frames(%State{} = state, []), do: state

  defp handle_frames(%State{} = state, [{:close, _code, _reason} | frames]) do
    state
    |> cancel_timer()
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
        case send_if_connected(state, frame) do
          {:ok, state} ->
            Map.put(state, :handler_state, handler_state)

          {:error, state, error} ->
            state
            |> Map.put(:handler_state, handler_state)
            |> dispatch(:handle_disconnect, [error])
        end

      {:close, {code, reason}, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        _ = send_if_connected(state, {:close, code, reason})

        state
        |> Map.put(:timer, Process.send_after(self(), {:internal, :close}, :timer.seconds(5)))
        |> Map.put(:handler_state, handler_state)

      {:close, handler_state}
      when function in [
             :handle_cast,
             :handle_info
           ] ->
        _ = send_if_connected(state, :close)

        state
        |> Map.put(:timer, Process.send_after(self(), {:internal, :close}, :timer.seconds(5)))
        |> Map.put(:handler_state, handler_state)

      {:reconnect, timeout, handler_state}
      when function in [
             :handle_disconnect
           ] ->
        Process.send_after(self(), {:internal, :connect}, timeout)
        Map.put(state, :handler_state, handler_state)

      {:reconnect, handler_state}
      when function in [
             :handle_disconnect
           ] ->
        Process.send(self(), {:internal, :connect}, [])
        Map.put(state, :handler_state, handler_state)

      _ when function == :terminate ->
        state
    end
  end

  defp send_if_connected(%State{conn: conn, websocket: websocket} = state, frame) do
    if not is_nil(websocket) and not is_nil(conn) and Mint.HTTP.open?(conn) do
      with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, state.ref, data) do
        {:ok,
         state
         |> Map.put(:conn, conn)
         |> Map.put(:websocket, websocket)}
      else
        {:error, %Mint.WebSocket{} = websocket, error} ->
          Logger.warning("Websocket encode error: #{inspect(error)}")
          {:ok, Map.put(state, :websocket, websocket)}

        {:error, conn, error} ->
          Logger.warning("Websocket can't send a message due to: #{inspect(error)}")
          {:error, Map.put(state, :conn, conn), error}
      end
    else
      Logger.warning("Websocket not connected, message will be dropped")
      {:ok, state}
    end
  end

  defp http_scheme(%URI{scheme: "ws"}), do: :http
  defp http_scheme(%URI{scheme: "wss"}), do: :https

  defp ws_scheme(%URI{scheme: "ws"}), do: :ws
  defp ws_scheme(%URI{scheme: "wss"}), do: :wss

  defp cancel_timer(%State{timer: nil} = state), do: state

  defp cancel_timer(%State{timer: ref} = state) do
    Process.cancel_timer(ref)
    Map.put(state, :timer, nil)
  end
end
