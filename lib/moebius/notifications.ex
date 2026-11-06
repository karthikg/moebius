defmodule Moebius.Notifications do
  @moduledoc """
  Postgres `LISTEN` / `NOTIFY`: Postgres sends events straight to your processes.

  Turn it on for a database with the `:notifications` option. The database then starts one
  extra connection, used only for listening, inside the same child of your tree as its pool:

  ```elixir
  children = [
    {MyApp.Db, Moebius.get_connection() ++ [notifications: true]}
  ]
  ```

  Then any process can listen on a channel, and any process (or a trigger) can notify it:

  ```elixir
  {:ok, ref} = MyApp.Db.listen("orders")

  MyApp.Db.notify("orders", %{id: 42, status: "paid"})

  receive do
    {:moebius_notification, ^ref, "orders", payload} -> Jason.decode!(payload)
  end
  ```

  ## What a listener receives

  * `{:moebius_notification, ref, channel, payload}` - a `NOTIFY` on the channel. `payload`
    is the string that was sent (`""` when there was none).
  * `{:moebius_listener, ref, :disconnected}` - the listening connection was lost.
    Notifications sent while it is down are **not** delivered; Postgres does not queue them
    for a listener that isn't connected.
  * `{:moebius_listener, ref, :connected}` - listening again. Reload whatever state the
    notifications keep fresh, because some may have been missed.

  Handle the two `:moebius_listener` messages, or ignore them with a catch-all clause, so they
  don't pile up in your mailbox.

  ## Guarantees

  * `listen/1` returning `{:ok, ref}` means `LISTEN` is active on the server: every `NOTIFY`
    committed after that reaches you. So listen first, then read the current state, and
    nothing falls in the gap.
  * `listen/1` returning `{:eventually, ref}` means the connection is down right now. The
    subscription is kept, and you receive `{:moebius_listener, ref, :connected}` once it is
    active.
  * Notifications sent inside a transaction are delivered when it commits, and not at all if
    it rolls back.
  * Postgres delivers notifications from one transaction in the order they were sent, and
    folds identical ones (same channel and payload) sent in the same transaction into one.
  * A listener is removed when its process exits. The last listener on a channel leaving
    sends `UNLISTEN` for it.

  ## Connection health

  The listening connection sends `select 1` when it has been idle for `:heartbeat` ms, and
  replaces itself when any command goes unanswered for `:timeout` ms. Without that, a network
  that silently drops the connection would leave listeners waiting for events that never
  come. Reconnects back off from `:backoff_min` to `:backoff_max`, with jitter, and retry
  forever. A database outage never crashes the listener or anything around it.

  ## Options

  `notifications: true` uses the defaults. Pass a keyword list to change them:

  * `:heartbeat` - ms of quiet before checking the connection (default 15,000).
  * `:timeout` - ms to wait for the server to answer a command or a connect (default 5,000).
  * `:backoff_min`, `:backoff_max` - reconnect delay bounds in ms (default 500 and 30,000).

  ## Limits

  Channel names are at most 63 bytes, and payloads at most about 8,000 bytes (a Postgres
  limit). Send an id in the payload and read the row, rather than sending the row.
  """

  use GenServer

  require Logger

  alias Moebius.{Connection, Error}

  @defaults [heartbeat: 15_000, timeout: 5_000, backoff_min: 500, backoff_max: 30_000]

  # Postgres truncates identifiers to NAMEDATALEN - 1 bytes, and pg_notify rejects longer ones
  @max_channel 63

  @typedoc "A channel name: a string or an atom, at most 63 bytes."
  @type channel :: String.t() | atom()

  # ---- public API (called through the database module) ----

  @doc false
  # `database` is always a module that `use`s Moebius.Database, never outside input, so
  # this makes one atom per database module.
  # sobelow_skip ["DOS.ModuleConcat"]
  def name(database), do: Module.concat(database, Notifications)

  @doc false
  def child_spec({database, opts}) do
    %{
      id: :notifications,
      start: {__MODULE__, :start_link, [database, opts]},
      # a database outage is handled inside; only a bug in this module ends it
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  def start_link(database, opts) do
    listener_opts = listener_opts(Keyword.get(opts, :notifications, true))
    server = name(database)
    :persistent_term.put({__MODULE__, server}, call_timeout(listener_opts))
    GenServer.start_link(__MODULE__, {database, opts, listener_opts}, name: server)
  end

  defp listener_opts(true), do: @defaults

  defp listener_opts(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @defaults)

    for {key, value} <- opts, not (is_integer(value) and value > 0) do
      raise ArgumentError,
            "notifications: #{key} must be a positive integer, got: #{inspect(value)}"
    end

    if opts[:backoff_min] > opts[:backoff_max],
      do: raise(ArgumentError, "notifications: backoff_min must not exceed backoff_max")

    opts
  end

  defp listener_opts(other) do
    raise ArgumentError,
          "the :notifications option must be true or a keyword list, got: #{inspect(other)}"
  end

  # A listen waits for at most the command in flight plus its own LISTEN. Either one
  # running past :timeout replaces the connection, and the caller gets {:eventually, ref}.
  defp call_timeout(opts), do: 2 * opts[:timeout] + 1_000

  @doc false
  def listen(database, channel) do
    channel = channel!(channel)
    call(database, {:listen, self(), channel})
  end

  @doc false
  def unlisten(database, ref) when is_reference(ref), do: call(database, {:unlisten, ref})

  def unlisten(_database, ref),
    do: raise(ArgumentError, "unlisten/1 expects the ref listen/1 returned, got: #{inspect(ref)}")

  defp call(database, message) do
    server = name(database)

    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> not_enabled(database)
      timeout -> GenServer.call(server, message, timeout)
    end
  catch
    :exit, {:noproc, _} -> not_enabled(database)
  end

  defp not_enabled(database) do
    {:error,
     "notifications aren't running for #{inspect(database)}. " <>
       "Start it with the notifications: true option."}
  end

  @doc false
  # The SQL and params for NOTIFY. pg_notify takes both as parameters, so neither is ever
  # written into SQL text.
  def notify_command(channel, payload) do
    {"select pg_notify($1, $2)", [channel!(channel), payload!(payload)]}
  end

  @doc false
  def channel!(channel) when is_atom(channel) and not is_nil(channel) and not is_boolean(channel),
    do: channel |> Atom.to_string() |> channel!()

  def channel!(channel) when is_binary(channel) do
    cond do
      channel == "" ->
        raise ArgumentError, "a notification channel can't be empty"

      byte_size(channel) > @max_channel ->
        raise ArgumentError,
              "a notification channel is at most #{@max_channel} bytes, got: #{inspect(channel)}"

      not String.valid?(channel) or String.contains?(channel, <<0>>) ->
        raise ArgumentError, "invalid notification channel: #{inspect(channel)}"

      true ->
        channel
    end
  end

  def channel!(channel),
    do: raise(ArgumentError, "a notification channel must be a string, got: #{inspect(channel)}")

  defp payload!(payload) when is_binary(payload), do: payload
  defp payload!(payload) when is_map(payload) or is_list(payload), do: Jason.encode!(payload)

  defp payload!(payload) do
    raise ArgumentError,
          "a notification payload must be a string, map or list, got: #{inspect(payload)}"
  end

  # LISTEN takes a name, not a parameter. Quoting keeps the channel exactly as given (no
  # lowercasing), so it matches what pg_notify($1, ...) sends; doubling " makes any name safe.
  defp quote_channel(channel), do: ~s(") <> String.replace(channel, ~s("), ~s("")) <> ~s(")

  # ---- server ----

  defmodule State do
    @moduledoc false
    defstruct [
      :database,
      :connect_opts,
      :opts,
      # the listening connection, once it's up
      :conn,
      # {pid, timer} for the process making a connection
      :connector,
      # {epgsqla ref, :sync | :ping, timer, to_listen, to_unlisten} for the one command in flight
      :inflight,
      :heartbeat,
      :backoff,
      status: :connecting,
      # true from losing the connection until it's back, to log each outage once
      outage?: false,
      # ref => {pid, channel}; the ref is the monitor on the listener
      subs: %{},
      # channel => MapSet of refs
      channels: %{},
      # channels LISTEN is active for on the current connection
      listening: MapSet.new(),
      # channel => [{from, ref}] waiting for LISTEN to be confirmed
      waiters: %{},
      # refs that will get {:moebius_listener, ref, :connected} when their channel is active
      owed: MapSet.new()
    ]
  end

  @impl true
  def init({database, opts, listener_opts}) do
    # the connection is linked to us; trapping turns its death into a message we handle
    Process.flag(:trap_exit, true)

    connect_opts =
      opts
      |> Connection.epgsql_options()
      # no codecs: listening only moves strings, and this skips the type-cache query
      |> Map.merge(%{codecs: [], async: self()})

    state = %State{
      database: database,
      connect_opts: connect_opts,
      opts: Map.new(listener_opts),
      backoff: listener_opts[:backoff_min]
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  # -- calls --

  @impl true
  def handle_call({:listen, pid, channel}, from, state) do
    ref = Process.monitor(pid)

    state = %{
      state
      | subs: Map.put(state.subs, ref, {pid, channel}),
        channels: Map.update(state.channels, channel, MapSet.new([ref]), &MapSet.put(&1, ref))
    }

    cond do
      state.status == :ready and active?(state, channel) ->
        {:reply, {:ok, ref}, state}

      state.status == :ready ->
        waiters = Map.update(state.waiters, channel, [{from, ref}], &[{from, ref} | &1])
        {:noreply, reconcile(%{state | waiters: waiters})}

      true ->
        {:reply, {:eventually, ref}, %{state | owed: MapSet.put(state.owed, ref)}}
    end
  end

  def handle_call({:unlisten, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, state |> remove_sub(ref) |> reconcile()}
  end

  # -- connecting --

  @impl true
  def handle_info({:moebius_connected, pid, conn}, %{connector: {pid, timer}} = state) do
    Process.cancel_timer(timer)
    # take ownership before the connector exits; if conn already died, the link delivers
    # {:EXIT, conn, :noproc} and we reconnect
    Process.link(conn)
    send(pid, {:moebius_ack, self()})

    if state.outage?, do: Logger.info("#{inspect(state.database)} notifications reconnected")

    state = %{
      state
      | conn: conn,
        connector: nil,
        status: :ready,
        outage?: false,
        backoff: state.opts.backoff_min
    }

    {:noreply, state |> reconcile() |> arm_heartbeat()}
  end

  def handle_info({:moebius_connect_failed, pid, reason}, %{connector: {pid, timer}} = state) do
    Process.cancel_timer(timer)
    {:noreply, connect_failed(%{state | connector: nil}, reason)}
  end

  def handle_info({:connect_timeout, pid}, %{connector: {pid, _timer}} = state) do
    # killing the connector kills the half-open connection linked to it
    Process.exit(pid, :kill)
    {:noreply, connect_failed(%{state | connector: nil}, :timeout)}
  end

  def handle_info(:reconnect, %{status: :backoff} = state), do: {:noreply, connect(state)}

  # -- the connection and its commands --

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) when is_pid(conn),
    do: {:noreply, disconnected(state, reason)}

  def handle_info({:EXIT, pid, reason}, %{connector: {pid, timer}} = state) do
    # the connector died before reporting (e.g. the socket closed during auth)
    Process.cancel_timer(timer)
    {:noreply, connect_failed(%{state | connector: nil}, reason)}
  end

  def handle_info(
        {conn, ref, result},
        %{conn: conn, inflight: {ref, kind, timer, add, drop}} = state
      ) do
    Process.cancel_timer(timer)
    state = %{state | inflight: nil}

    case {kind, command_error(result)} do
      {:ping, nil} ->
        # subscriptions may have changed while the ping was out
        {:noreply, state |> reconcile() |> arm_heartbeat()}

      {:sync, nil} ->
        listening = state.listening |> MapSet.union(add) |> MapSet.difference(drop)
        {:noreply, %{state | listening: listening} |> settle() |> reconcile() |> arm_heartbeat()}

      {_, error} ->
        # LISTEN on a quoted name doesn't fail on a healthy connection; start over on a new one
        Logger.warning("#{inspect(state.database)} notifications: #{error}; reconnecting")
        {:noreply, drop_connection(state)}
    end
  end

  def handle_info({:command_timeout, ref}, %{inflight: {ref, _, _, _, _}} = state) do
    Logger.warning(
      "#{inspect(state.database)} notifications: no answer from the server in " <>
        "#{state.opts.timeout}ms; reconnecting"
    )

    {:noreply, drop_connection(state)}
  end

  def handle_info({:heartbeat, token}, %{heartbeat: {token, _}} = state) do
    state = %{state | heartbeat: nil}

    case state do
      %{status: :ready, inflight: nil} -> {:noreply, send_command(state, :ping, "select 1")}
      _ -> {:noreply, state}
    end
  end

  # -- notifications --

  def handle_info(
        {:epgsql, conn, {:notification, channel, _backend, payload}},
        %{conn: conn} = state
      ) do
    for ref <- Map.get(state.channels, channel, []) do
      {pid, _channel} = Map.fetch!(state.subs, ref)
      send(pid, {:moebius_notification, ref, channel, payload})
    end

    {:noreply, state}
  end

  # -- listeners leaving --

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, state |> remove_sub(ref) |> reconcile()}

  # Everything else is stale: server notices, replies and timers from a connection we have
  # already replaced, the connector's normal exit. Dropping them keeps the mailbox empty.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: :epgsqla.close(state.conn)
    with {pid, _timer} <- state.connector, do: Process.exit(pid, :kill)
    :ok
  end

  # ---- connection lifecycle ----

  defp connect(state) do
    parent = self()
    opts = state.connect_opts
    timeout = state.opts.timeout
    pid = spawn_link(fn -> connector(parent, opts, timeout) end)
    timer = Process.send_after(self(), {:connect_timeout, pid}, timeout)
    %{state | status: :connecting, connector: {pid, timer}}
  end

  # Runs in its own process, because :epgsql.connect/1 blocks without a deadline of its own.
  # The connection is linked to this process until the listener takes it over and acks;
  # if this process is killed first, the half-made connection dies with it.
  defp connector(parent, opts, timeout) do
    case :epgsql.connect(opts) do
      {:ok, conn} ->
        send(parent, {:moebius_connected, self(), conn})

        receive do
          {:moebius_ack, ^parent} -> :ok
        after
          timeout -> exit(:no_ack)
        end

      {:error, reason} ->
        send(parent, {:moebius_connect_failed, self(), reason})
    end
  end

  defp connect_failed(state, reason) do
    unless state.outage? do
      Logger.warning(
        "#{inspect(state.database)} notifications can't connect: #{describe(reason)}; " <>
          "retrying"
      )
    end

    schedule_reconnect(%{state | outage?: true})
  end

  # Kill a connection we can't trust; its {:EXIT, ...} then runs disconnected/2.
  defp drop_connection(%{conn: conn} = state) do
    Process.unlink(conn)
    Process.exit(conn, :kill)
    disconnected(state, :killed)
  end

  defp disconnected(state, reason) do
    if state.inflight, do: Process.cancel_timer(elem(state.inflight, 2))

    unless state.outage? do
      Logger.warning(
        "#{inspect(state.database)} notifications lost the connection: #{describe(reason)}; " <>
          "reconnecting"
      )
    end

    # calls waiting on a LISTEN that will now never be confirmed
    owed =
      for {_channel, waiting} <- state.waiters, {from, ref} <- waiting, reduce: state.owed do
        owed ->
          GenServer.reply(from, {:eventually, ref})
          MapSet.put(owed, ref)
      end

    # everyone else was listening, and may now miss notifications
    for {ref, {pid, _channel}} <- state.subs, not MapSet.member?(owed, ref) do
      send(pid, {:moebius_listener, ref, :disconnected})
    end

    state = %{
      state
      | conn: nil,
        inflight: nil,
        heartbeat: nil,
        listening: MapSet.new(),
        waiters: %{},
        owed: state.subs |> Map.keys() |> MapSet.new(),
        outage?: true
    }

    schedule_reconnect(state)
  end

  defp schedule_reconnect(state) do
    # full jitter between half the delay and the delay, so many nodes don't retry in step
    delay = div(state.backoff, 2) + :rand.uniform(div(state.backoff, 2) + 1)
    Process.send_after(self(), :reconnect, delay)
    %{state | status: :backoff, backoff: min(state.backoff * 2, state.opts.backoff_max)}
  end

  # ---- keeping LISTEN in step with the subscriptions ----

  # One command at a time: send whatever LISTEN/UNLISTEN brings the server in line with
  # the channels people want. Called after every change; a no-op while a command is out.
  defp reconcile(%{status: :ready, inflight: nil} = state) do
    wanted = state.channels |> Map.keys() |> MapSet.new()
    add = MapSet.difference(wanted, state.listening)
    drop = MapSet.difference(state.listening, wanted)

    if MapSet.size(add) == 0 and MapSet.size(drop) == 0 do
      state
    else
      sql =
        Enum.map(add, &("listen " <> quote_channel(&1))) ++
          Enum.map(drop, &("unlisten " <> quote_channel(&1)))

      send_command(state, :sync, Enum.join(sql, "; "), add, drop)
    end
  end

  defp reconcile(state), do: state

  defp send_command(state, kind, sql, add \\ MapSet.new(), drop \\ MapSet.new()) do
    ref = :epgsqla.squery(state.conn, sql)
    timer = Process.send_after(self(), {:command_timeout, ref}, state.opts.timeout)
    %{state | inflight: {ref, kind, timer, add, drop}}
  end

  # Listening on a channel only counts once the server confirmed it, and not while an
  # UNLISTEN for it is on the way.
  defp active?(%{inflight: {_, :sync, _, _, drop}} = state, channel),
    do: MapSet.member?(state.listening, channel) and not MapSet.member?(drop, channel)

  defp active?(state, channel), do: MapSet.member?(state.listening, channel)

  # Answer the calls and send the :connected messages whose channel is now active.
  defp settle(state) do
    {ready, waiting} = Map.split_with(state.waiters, fn {ch, _} -> active?(state, ch) end)

    for {_channel, waiters} <- ready, {from, ref} <- waiters, Map.has_key?(state.subs, ref) do
      GenServer.reply(from, {:ok, ref})
    end

    {connected, owed} =
      Enum.split_with(state.owed, fn ref ->
        case state.subs do
          %{^ref => {_pid, channel}} -> active?(state, channel)
          _ -> false
        end
      end)

    for ref <- connected do
      {pid, _channel} = Map.fetch!(state.subs, ref)
      send(pid, {:moebius_listener, ref, :connected})
    end

    %{state | waiters: waiting, owed: MapSet.new(owed)}
  end

  defp remove_sub(state, ref) do
    case Map.pop(state.subs, ref) do
      {nil, _subs} ->
        state

      {{_pid, channel}, subs} ->
        refs = state.channels |> Map.fetch!(channel) |> MapSet.delete(ref)

        channels =
          if MapSet.size(refs) == 0,
            do: Map.delete(state.channels, channel),
            else: Map.put(state.channels, channel, refs)

        waiters =
          case Map.get(state.waiters, channel) do
            nil -> state.waiters
            list -> Map.put(state.waiters, channel, Enum.reject(list, &(elem(&1, 1) == ref)))
          end

        %{
          state
          | subs: subs,
            channels: channels,
            waiters: waiters,
            owed: MapSet.delete(state.owed, ref)
        }
    end
  end

  # ---- heartbeat ----

  defp arm_heartbeat(%{status: :ready, inflight: nil, heartbeat: nil} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:heartbeat, token}, state.opts.heartbeat)
    %{state | heartbeat: {token, timer}}
  end

  defp arm_heartbeat(state), do: state

  # ---- helpers ----

  defp command_error(results) when is_list(results),
    do: Enum.find_value(results, &command_error/1)

  defp command_error({:error, error}), do: describe(error)
  defp command_error(_ok), do: nil

  defp describe(reason) do
    case Error.from_epgsql(reason) do
      %Error{name: :driver_error} -> inspect(reason)
      %Error{message: message} -> message
    end
  end
end
