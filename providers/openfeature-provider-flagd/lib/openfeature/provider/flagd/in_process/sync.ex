defmodule OpenFeature.Provider.Flagd.InProcess.Sync do
  @moduledoc false

  # Streams flag definitions from flagd's sync service into a Store.
  #
  # One sync process runs per initialized provider, under its own SyncSupervisor, and registers its
  # ETS table in the Registry under the provider's sync_ref so evaluations can find it across
  # restarts. The stream itself runs in a supervised task so a broken connection never takes the
  # store with it. When the stream drops the provider goes :stale and reconnects with
  # exponential backoff; still disconnected after the grace period, it goes :error. The last flag
  # set keeps serving evaluations throughout.

  use GenServer, restart: :transient

  require Logger

  alias Flagd.Sync.V1.FlagSyncService.Stub
  alias Flagd.Sync.V1.SyncFlagsRequest
  alias Flagd.Sync.V1.SyncFlagsResponse
  alias OpenFeature.EventEmitter
  alias OpenFeature.Provider.Flagd.InProcess
  alias OpenFeature.Provider.Flagd.InProcess.FlagSet
  alias OpenFeature.Provider.Flagd.InProcess.Store
  alias OpenFeature.Provider.Flagd.InProcess.SyncSupervisor
  alias OpenFeature.Provider.Flagd.TLS

  @registry OpenFeature.Provider.Flagd.InProcess.Registry
  @supervisor OpenFeature.Provider.Flagd.InProcess.Supervisor
  @task_supervisor OpenFeature.Provider.Flagd.InProcess.TaskSupervisor
  @deadline_exceeded GRPC.Status.deadline_exceeded()

  defstruct [
    :provider,
    :domain,
    :supervisor,
    :table,
    :channel,
    :task,
    :grace_timer,
    flags: %{},
    status: :connecting,
    backoff_ms: nil,
    waiters: []
  ]

  # Starts the provider's supervisor and returns the sync process it started, which has registered
  # itself by the time start_child/2 returns because init/1 runs synchronously.
  @spec start(InProcess.t(), binary(), reference()) :: {:ok, pid()} | {:error, term()}
  def start(%InProcess{} = provider, domain, ref) when is_binary(domain) and is_reference(ref) do
    with {:ok, _supervisor} <- DynamicSupervisor.start_child(@supervisor, {SyncSupervisor, {provider, domain, ref}}),
         {:ok, pid, _table} <- whereis(ref) do
      {:ok, pid}
    else
      :error -> {:error, :not_registered}
      {:error, _reason} = error -> error
    end
  end

  @spec start_link({InProcess.t(), binary(), reference(), pid()}) :: GenServer.on_start()
  def start_link({%InProcess{}, _domain, _ref, _supervisor} = args), do: GenServer.start_link(__MODULE__, args)

  @spec whereis(reference() | nil) :: {:ok, pid(), Store.table()} | :error
  def whereis(ref) do
    case live_entry(ref) do
      {pid, {table, _supervisor}} -> {:ok, pid, table}
      nil -> :error
    end
  end

  @spec table(reference() | nil) :: {:ok, Store.table()} | :error
  def table(ref) do
    with {:ok, _pid, table} <- whereis(ref), do: {:ok, table}
  end

  # Blocks until the first flag set is stored. The waiter is dropped by the caller on timeout, so a
  # late reply is possible only if the caller keeps the process alive; initialize/3 stops it instead.
  @spec await_ready(pid(), timeout()) :: {:ok, Store.table()} | {:error, :timeout}
  def await_ready(pid, timeout) do
    GenServer.call(pid, :await_ready, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec stop(reference() | nil) :: :ok
  def stop(ref) do
    case live_entry(ref) do
      {_pid, {_table, supervisor}} ->
        DynamicSupervisor.terminate_child(@supervisor, supervisor)
        :ok

      nil ->
        :ok
    end
  end

  @impl true
  def init({provider, domain, ref, supervisor}) do
    # Trapping exits makes terminate/2 run on supervisor shutdown, so the stream task and channel
    # are released with the process, and turns a linked task's crash into a message.
    Process.flag(:trap_exit, true)
    table = Store.new()
    {:ok, _owner} = Registry.register(@registry, ref, {table, supervisor})

    state = %__MODULE__{
      provider: provider,
      domain: domain,
      supervisor: supervisor,
      table: table,
      backoff_ms: provider.retry_backoff_ms
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  # Any status other than :connecting means a flag set has been stored, even if the stream has
  # since dropped again.
  @impl true
  def handle_call(:await_ready, _from, %{status: status} = state) when status != :connecting do
    {:reply, {:ok, state.table}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_info({:flag_set, %SyncFlagsResponse{} = response}, state) do
    {:noreply, store_flag_set(response, state)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, stream_closed(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, stream_closed({:crashed, reason}, %{state | task: nil})}
  end

  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  def handle_info(:grace_expired, %{status: :stale} = state) do
    Logger.error("flagd sync still disconnected after #{state.provider.retry_grace_period}s, provider is in error")
    emit(state, :error, %{})
    {:noreply, %{state | status: :error, grace_timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> stop_task() |> disconnect()
    :ok
  end

  defp connect(state) do
    state = state |> stop_task() |> disconnect()
    provider = state.provider
    target = "#{provider.host}:#{provider.port}"

    case GRPC.Stub.connect(target, TLS.connection_opts(provider)) do
      {:ok, channel} ->
        start_stream(%{state | channel: channel})

      {:error, reason} ->
        Logger.warning("flagd sync connection to #{target} failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  # The task is linked so it cannot outlive a crashed sync process; exits are trapped, so its own
  # crash arrives as a DOWN message rather than killing the sync.
  defp start_stream(%{channel: channel, provider: provider} = state) do
    parent = self()
    task = Task.Supervisor.async(@task_supervisor, fn -> run_stream(parent, channel, provider) end)
    %{state | task: task}
  end

  # Returns why the stream ended; flag sets are forwarded to the parent as they arrive.
  defp run_stream(parent, channel, provider) do
    request = %SyncFlagsRequest{provider_id: provider.provider_id || "", selector: provider.selector || ""}

    case Stub.sync_flags(channel, request, stream_opts(provider)) do
      {:ok, stream} ->
        Enum.reduce_while(stream, :closed, fn
          {:ok, response}, _acc ->
            send(parent, {:flag_set, response})
            {:cont, :closed}

          {:error, error}, _acc ->
            {:halt, {:error, error}}
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  # The selector travels in the request body for older servers and in the header current servers read.
  defp stream_opts(%{selector: selector, stream_deadline_ms: deadline}) when is_binary(selector) and selector != "" do
    [timeout: deadline, metadata: %{"flagd-selector" => selector}]
  end

  defp stream_opts(%{stream_deadline_ms: deadline}), do: [timeout: deadline]

  defp store_flag_set(%SyncFlagsResponse{flag_configuration: json, sync_context: sync_context}, state) do
    case FlagSet.parse(json) do
      {:ok, flag_set} ->
        removed = Map.keys(state.flags) -- Map.keys(flag_set.flags)
        Store.put(state.table, flag_set, enrich(sync_context, state.provider), removed)
        changed = FlagSet.changed_keys(state.flags, flag_set.flags)
        first? = state.status == :connecting

        state = %{state | flags: flag_set.flags} |> connected() |> reply_waiters()

        if not first? and changed != [], do: emit(state, :configuration_changed, %{flags_changed: changed})

        state

      {:error, reason} ->
        Logger.error("flagd sent a flag definition that could not be parsed: #{inspect(reason)}")
        state
    end
  end

  defp enrich(nil, _provider), do: %{}

  # Round-trips through JSON text on purpose: it is the public Protobuf.JSON API, and the private
  # Encode/Decode modules changed arity in protobuf 0.17.
  defp enrich(sync_context, provider) do
    sync_context |> Protobuf.JSON.encode!() |> Jason.decode!() |> provider.context_enricher.()
  end

  defp connected(%{status: status} = state) do
    if status in [:stale, :error], do: emit(state, :ready, %{})
    if state.grace_timer, do: Process.cancel_timer(state.grace_timer)

    %{state | status: :connected, grace_timer: nil, backoff_ms: state.provider.retry_backoff_ms}
  end

  defp reply_waiters(%{waiters: waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, {:ok, state.table}))
    %{state | waiters: []}
  end

  # A stream that expires on its deadline is reopened silently; anything else means flagd went away.
  defp stream_closed({:error, %GRPC.RPCError{status: @deadline_exceeded}}, state), do: connect(state)

  defp stream_closed(reason, state) do
    Logger.warning("flagd sync stream closed: #{inspect(reason)}")
    state |> stale() |> schedule_reconnect()
  end

  defp stale(%{status: :connected} = state) do
    emit(state, :stale, %{})
    timer = Process.send_after(self(), :grace_expired, state.provider.retry_grace_period * 1000)
    %{state | status: :stale, grace_timer: timer}
  end

  defp stale(state), do: state

  # Jitter of plus or minus 20% keeps a fleet of clients from reconnecting in lockstep after flagd
  # restarts.
  defp schedule_reconnect(state) do
    jittered = trunc(state.backoff_ms * (0.8 + :rand.uniform() * 0.4))
    Process.send_after(self(), :reconnect, jittered)
    %{state | backoff_ms: min(state.backoff_ms * 2, state.provider.retry_backoff_max_ms)}
  end

  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(%{task: task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  defp disconnect(%{channel: nil} = state), do: state

  defp disconnect(%{channel: channel} = state) do
    GRPC.Stub.disconnect(channel)
    %{state | channel: nil}
  end

  # The registry allows duplicate keys because a restarted process may register before the
  # registry has processed its predecessor's exit; the live entry is the one that counts.
  defp live_entry(ref) do
    @registry
    |> Registry.lookup(ref)
    |> Enum.find(fn {pid, _value} -> Process.alive?(pid) end)
  end

  defp emit(state, type, details) do
    EventEmitter.emit(state.domain, type, Map.put(details, :provider, state.provider.name))
  end
end
