defmodule OpenFeature.Provider.Flagd.InProcess.SyncTest do
  use ExUnit.Case
  use Mimic

  import ExUnit.CaptureLog

  alias Flagd.Sync.V1.FlagSyncService.Stub
  alias Flagd.Sync.V1.SyncFlagsRequest
  alias Flagd.Sync.V1.SyncFlagsResponse
  alias OpenFeature.EventEmitter
  alias OpenFeature.Provider.Flagd.InProcess
  alias OpenFeature.Provider.Flagd.InProcess.Store
  alias OpenFeature.Provider.Flagd.InProcess.Sync

  @moduletag :capture_log

  setup :set_mimic_global
  setup :verify_on_exit!

  @flags_v1 ~s({"flags": {"a": {"state": "ENABLED", "variants": {"on": true, "off": false}, "defaultVariant": "on"}}})
  @flags_v2 ~s({"flags": {"a": {"state": "ENABLED", "variants": {"on": true, "off": false}, "defaultVariant": "off"}}})

  defp provider(opts \\ []) do
    InProcess.new(Keyword.merge([retry_backoff_ms: 20, retry_backoff_max_ms: 40, retry_grace_period: 1], opts))
  end

  defp domain, do: "sync-test-#{System.unique_integer([:positive])}"

  defp start_sync(provider) do
    ref = make_ref()
    {:ok, pid} = Sync.start(provider, domain(), ref)
    {pid, ref}
  end

  # A stream the test drives by sending `{:ok, response}`, `{:error, error}` or `:close` to the pid
  # it announces. The stream runs inside the sync task, so the mock has to hand that pid out.
  defp controlled_stream(test_pid) do
    send(test_pid, {:stream, self()})

    Stream.unfold(:open, fn :open ->
      receive do
        :close ->
          nil

        message ->
          {message, :open}
      end
    end)
  end

  defp expect_connect(times \\ 1) do
    expect(GRPC.Stub, :connect, times, fn _target, _opts -> {:ok, %GRPC.Channel{}} end)
    stub(GRPC.Stub, :disconnect, fn channel -> {:ok, channel} end)
  end

  defp forward_events(test_pid) do
    stub(EventEmitter, :emit, fn _domain, type, details ->
      send(test_pid, {:event, type, details})
      :ok
    end)
  end

  test "stores the first flag set and answers waiters" do
    expect_connect()

    expect(Stub, :sync_flags, fn _channel, %SyncFlagsRequest{}, _opts ->
      {:ok, [{:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}}]}
    end)

    {pid, ref} = start_sync(provider())
    assert {:ok, table} = Sync.await_ready(pid, 500)
    assert {:ok, %{default_variant: "on"}} = Store.flag(table, "a")
    assert Sync.stop(ref) == :ok
  end

  test "sends the selector in the request body and the header" do
    test_pid = self()
    expect_connect()

    expect(Stub, :sync_flags, fn _channel, request, opts ->
      send(test_pid, {:request, request, opts})
      {:ok, [{:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}}]}
    end)

    {pid, ref} = start_sync(provider(selector: "flagSetId=x", provider_id: "me", stream_deadline_ms: 1234))
    assert {:ok, _} = Sync.await_ready(pid, 500)

    assert_receive {:request, %SyncFlagsRequest{selector: "flagSetId=x", provider_id: "me"}, opts}
    assert opts[:timeout] == 1234
    assert opts[:metadata] == %{"flagd-selector" => "flagSetId=x"}
    Sync.stop(ref)
  end

  test "await_ready times out when no flag set arrives" do
    test_pid = self()
    expect_connect()
    expect(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert {:error, :timeout} = Sync.await_ready(pid, 50)
    assert Process.alive?(pid)
    assert {:ok, ^pid, _table} = Sync.whereis(ref)
    Sync.stop(ref)
  end

  test "emits configuration_changed only when flags change" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect()
    expect(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert_receive {:stream, stream}

    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, table} = Sync.await_ready(pid, 500)
    refute_receive {:event, _, _}, 50

    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    refute_receive {:event, _, _}, 50

    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v2}})
    assert_receive {:event, :configuration_changed, %{flags_changed: ["a"], provider: "FlagdInProcess"}}
    assert {:ok, %{default_variant: "off"}} = Store.flag(table, "a")
    Sync.stop(ref)
  end

  test "goes stale, then error, then ready again while still serving flags" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect(2)

    expect(Stub, :sync_flags, 2, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider(retry_grace_period: 0))
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, table} = Sync.await_ready(pid, 500)

    log =
      capture_log(fn ->
        send(stream, {:error, %GRPC.RPCError{status: 14, message: "unavailable"}})
        assert_receive {:event, :stale, %{provider: "FlagdInProcess"}}
        assert_receive {:event, :error, _}, 500
      end)

    assert log =~ "flagd sync stream closed"
    assert {:ok, %{default_variant: "on"}} = Store.flag(table, "a")

    assert_receive {:stream, stream2}, 500
    send(stream2, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v2}})
    assert_receive {:event, :ready, _}
    assert_receive {:event, :configuration_changed, %{flags_changed: ["a"]}}
    Sync.stop(ref)
  end

  test "recovers within the grace period without an error event" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect(2)
    expect(Stub, :sync_flags, 2, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider(retry_grace_period: 5))
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, _} = Sync.await_ready(pid, 500)

    capture_log(fn ->
      send(stream, :close)
      assert_receive {:event, :stale, _}
      assert_receive {:stream, stream2}, 500
      send(stream2, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
      assert_receive {:event, :ready, _}
    end)

    refute_receive {:event, :error, _}, 100
    refute_receive {:event, :configuration_changed, _}, 10
    Sync.stop(ref)
  end

  test "reopens an expired stream without going stale" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect(2)
    expect(Stub, :sync_flags, 2, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, _} = Sync.await_ready(pid, 500)

    send(stream, {:error, %GRPC.RPCError{status: 4, message: "deadline exceeded"}})
    assert_receive {:stream, _stream2}, 500
    refute_receive {:event, _, _}, 50
    Sync.stop(ref)
  end

  test "retries until the connection succeeds" do
    test_pid = self()
    forward_events(test_pid)

    expect(GRPC.Stub, :connect, 3, fn _target, _opts ->
      send(test_pid, :connect_failed)
      {:error, :econnrefused}
    end)

    expect(GRPC.Stub, :connect, fn _target, _opts -> {:ok, %GRPC.Channel{}} end)
    stub(GRPC.Stub, :disconnect, fn channel -> {:ok, channel} end)
    expect(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider(retry_backoff_ms: 20, retry_backoff_max_ms: 40))
    assert_receive {:stream, stream}, 1000
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, _} = Sync.await_ready(pid, 500)

    for _ <- 1..3, do: assert_received(:connect_failed)
    refute_receive {:event, _, _}, 10
    Sync.stop(ref)
  end

  test "backoff doubles up to the maximum and resets on reconnect" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect(2)
    expect(Stub, :sync_flags, 2, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider(retry_backoff_ms: 30, retry_backoff_max_ms: 50, retry_grace_period: 5))
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, _} = Sync.await_ready(pid, 500)
    assert :sys.get_state(pid).backoff_ms == 30

    send(stream, :close)
    assert_receive {:event, :stale, _}
    assert :sys.get_state(pid).backoff_ms == 50

    assert_receive {:stream, stream2}, 500
    send(stream2, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert_receive {:event, :ready, _}
    assert :sys.get_state(pid).backoff_ms == 30
    Sync.stop(ref)
  end

  test "ignores a flag set that fails to parse" do
    test_pid = self()
    forward_events(test_pid)
    expect_connect()
    expect(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, table} = Sync.await_ready(pid, 500)

    log =
      capture_log(fn ->
        send(stream, {:ok, %SyncFlagsResponse{flag_configuration: "{not json"}})
        # A second, valid flag set proves the bad one was processed and skipped.
        send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v2}})
        assert_receive {:event, :configuration_changed, %{flags_changed: ["a"]}}, 500
      end)

    assert log =~ "could not be parsed"
    assert {:ok, %{default_variant: "off"}} = Store.flag(table, "a")
    refute_receive {:event, _, _}, 10
    Sync.stop(ref)
  end

  test "stores sync context through the context enricher" do
    expect_connect()
    sync_context = Protobuf.JSON.decode!(~s({"fn": "flagd", "secret": "x"}), Google.Protobuf.Struct)

    expect(Stub, :sync_flags, fn _channel, _request, _opts ->
      {:ok, [{:ok, %SyncFlagsResponse{flag_configuration: @flags_v1, sync_context: sync_context}}]}
    end)

    enricher = fn context -> Map.delete(context, "secret") end
    {pid, ref} = start_sync(provider(context_enricher: enricher))
    assert {:ok, table} = Sync.await_ready(pid, 500)
    assert Store.enriched_context(table) == %{"fn" => "flagd"}
    Sync.stop(ref)
  end

  test "a crashed sync process is restarted and re-registers a fresh table" do
    test_pid = self()
    expect_connect(2)
    expect(Stub, :sync_flags, 2, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, table} = Sync.await_ready(pid, 500)

    old_task = Process.monitor(stream)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^old_task, :process, _, _}, 500
    assert_receive {:stream, stream2}, 500
    assert {:ok, new_pid, new_table} = Sync.whereis(ref)
    assert new_pid != pid
    assert new_table != table

    send(stream2, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v2}})
    assert {:ok, ^new_table} = Sync.await_ready(new_pid, 500)
    assert {:ok, %{default_variant: "off"}} = Store.flag(new_table, "a")
    Sync.stop(ref)
  end

  test "a crash loop gives up on that provider alone" do
    test_pid = self()
    stub(GRPC.Stub, :connect, fn _target, _opts -> {:ok, %GRPC.Channel{}} end)
    stub(GRPC.Stub, :disconnect, fn channel -> {:ok, channel} end)
    stub(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    {other_pid, other_ref} = start_sync(provider())
    assert_receive {:stream, _}
    assert_receive {:stream, _}

    # SyncSupervisor allows three restarts in five seconds; the next crash ends the provider.
    Enum.reduce(1..3, pid, fn _, current ->
      Process.exit(current, :kill)
      assert_receive {:stream, _}, 500
      {:ok, next, _} = Sync.whereis(ref)
      next
    end)

    kill_until_gone(ref, 10)
    assert Sync.table(ref) == :error
    assert {:ok, ^other_pid, _} = Sync.whereis(other_ref)
    Sync.stop(other_ref)
  end

  defp kill_until_gone(_ref, 0), do: flunk("sync process kept being restarted")

  defp kill_until_gone(ref, attempts) do
    case Sync.whereis(ref) do
      {:ok, pid, _} ->
        Process.exit(pid, :kill)
        Process.sleep(10)
        kill_until_gone(ref, attempts - 1)

      :error ->
        :ok
    end
  end

  test "stop kills the stream task and drops the table" do
    test_pid = self()
    expect_connect()
    expect(Stub, :sync_flags, fn _channel, _request, _opts -> {:ok, controlled_stream(test_pid)} end)

    {pid, ref} = start_sync(provider())
    assert_receive {:stream, stream}
    send(stream, {:ok, %SyncFlagsResponse{flag_configuration: @flags_v1}})
    assert {:ok, table} = Sync.await_ready(pid, 500)

    monitor = Process.monitor(stream)
    assert Sync.stop(ref) == :ok
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert :ets.info(table) == :undefined
    assert Sync.stop(ref) == :ok
    assert Sync.table(ref) == :error
  end
end
