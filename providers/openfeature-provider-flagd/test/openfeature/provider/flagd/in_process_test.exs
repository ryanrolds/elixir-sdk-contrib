defmodule OpenFeature.Provider.Flagd.InProcessTest do
  use ExUnit.Case
  use Mimic

  import ExUnit.CaptureLog

  alias Flagd.Sync.V1.FlagSyncService.Stub
  alias Flagd.Sync.V1.SyncFlagsResponse
  alias OpenFeature.Client
  alias OpenFeature.Provider.Flagd
  alias OpenFeature.Provider.Flagd.GRPC, as: FlagdGRPC
  alias OpenFeature.Provider.Flagd.InProcess
  alias OpenFeature.Provider.Flagd.InProcess.Sync

  @moduletag :capture_log

  setup :set_mimic_global
  setup :verify_on_exit!

  @fixture Path.expand("../../../fixtures/flagd-testbed/testkit-flags.json", __DIR__)
  @env ~w(FLAGD_HOST FLAGD_PORT FLAGD_TLS FLAGD_SERVER_CERT_PATH FLAGD_SOURCE_SELECTOR FLAGD_PROVIDER_ID FLAGD_DEADLINE_MS FLAGD_STREAM_DEADLINE_MS FLAGD_RETRY_BACKOFF_MS FLAGD_RETRY_BACKOFF_MAX_MS FLAGD_RETRY_GRACE_PERIOD FLAGD_RESOLVER)

  setup do
    on_exit(fn -> Enum.each(@env, &System.delete_env/1) end)
  end

  describe "new/1" do
    test "has the cross-SDK defaults" do
      provider = InProcess.new()

      assert %InProcess{
               name: "FlagdInProcess",
               host: "localhost",
               port: 8015,
               tls: false,
               selector: nil,
               provider_id: nil,
               deadline_ms: 500,
               stream_deadline_ms: 600_000,
               retry_backoff_ms: 1000,
               retry_backoff_max_ms: 5000,
               retry_grace_period: 10,
               state: :not_ready
             } = provider

      assert provider.context_enricher.(%{"a" => 1}) == %{"a" => 1}
    end

    test "reads environment variables and lets options win" do
      System.put_env("FLAGD_HOST", "flagd-proxy")
      System.put_env("FLAGD_PORT", "9000")
      System.put_env("FLAGD_TLS", "TRUE")
      System.put_env("FLAGD_SERVER_CERT_PATH", "/certs/ca.pem")
      System.put_env("FLAGD_SOURCE_SELECTOR", "core.openfeature.dev/ns/flags")
      System.put_env("FLAGD_PROVIDER_ID", "phoenix")
      System.put_env("FLAGD_DEADLINE_MS", "2000")
      System.put_env("FLAGD_STREAM_DEADLINE_MS", "notanumber")
      System.put_env("FLAGD_RETRY_BACKOFF_MS", "")
      System.put_env("FLAGD_RETRY_GRACE_PERIOD", "3")

      provider = InProcess.new(port: 8016, hooks: [], unknown: :ignored)

      assert %InProcess{
               host: "flagd-proxy",
               port: 8016,
               tls: true,
               cacertfile: "/certs/ca.pem",
               selector: "core.openfeature.dev/ns/flags",
               provider_id: "phoenix",
               deadline_ms: 2000,
               stream_deadline_ms: 600_000,
               retry_backoff_ms: 1000,
               retry_grace_period: 3
             } = provider

      refute Map.has_key?(provider, :unknown)
    end
  end

  describe "OpenFeature.Provider.Flagd.new/1" do
    test "defaults to the rpc resolver" do
      assert %FlagdGRPC{port: 8013} = Flagd.new()
      assert %FlagdGRPC{port: 1} = Flagd.new(resolver: "rpc", port: 1)
    end

    test "selects the in-process resolver from the option or the environment" do
      assert %InProcess{selector: "x"} = Flagd.new(resolver: :in_process, selector: "x")
      System.put_env("FLAGD_RESOLVER", "in-process")
      assert %InProcess{port: 8015} = Flagd.new()
      assert %FlagdGRPC{} = Flagd.new(resolver: :rpc)
    end

    test "rejects unknown resolvers" do
      assert_raise ArgumentError, ~r/unsupported flagd resolver: "file"/, fn ->
        Flagd.new(resolver: "file")
      end
    end
  end

  describe "as an OpenFeature provider" do
    setup do
      stub(GRPC.Stub, :connect, fn _target, _opts -> {:ok, %GRPC.Channel{}} end)
      stub(GRPC.Stub, :disconnect, fn channel -> {:ok, channel} end)
      %{domain: "in-process-test-#{System.unique_integer([:positive])}", json: File.read!(@fixture)}
    end

    test "initializes, evaluates through the SDK client and shuts down", %{domain: domain, json: json} do
      expect(Stub, :sync_flags, fn _channel, _request, _opts ->
        {:ok, [{:ok, %SyncFlagsResponse{flag_configuration: json}}]}
      end)

      assert {:ok, %InProcess{state: :ready, sync_ref: ref, domain: ^domain}} =
               OpenFeature.set_provider(domain, InProcess.new(deadline_ms: 1000))

      assert {:ok, sync, _table} = Sync.whereis(ref)

      client = OpenFeature.get_client(domain)

      assert Client.get_boolean_value(client, "boolean-flag", false) == true
      assert Client.get_string_value(client, "string-flag", "bye") == "hi"
      assert Client.get_number_value(client, "integer-flag", 1) == 10
      assert Client.get_number_value(client, "float-flag", 1.0) == 0.5
      assert Client.get_map_value(client, "object-flag", %{})["imagesPerPage"] == 100

      hit =
        Client.get_string_details(client, "targeting-key-flag", "x",
          context: %{"targetingKey" => "5c3d8535-f81a-4478-a6d3-afaa4d51199e"}
        )

      assert %{value: "hit", variant: "hit", reason: :targeting_match} = hit

      missing = Client.get_string_details(client, "nope", "x")
      assert %{value: "x", reason: :error, error_code: :flag_not_found} = missing

      mismatch = Client.get_number_details(client, "wrong-flag", 13)
      assert %{value: 13, reason: :error, error_code: :type_mismatch} = mismatch

      assert Client.get_boolean_details(client, "disabled-boolean-flag", true).reason == :disabled

      assert :ok = InProcess.shutdown(client.provider)
      refute Process.alive?(sync)

      not_ready = Client.get_string_details(client, "string-flag", "x")
      assert %{value: "x", reason: :error, error_code: :provider_not_ready} = not_ready
    end

    test "fails to initialize when no flags arrive in time", %{domain: domain} do
      test_pid = self()

      expect(Stub, :sync_flags, fn _channel, _request, _opts ->
        send(test_pid, {:task, self()})
        {:ok, Stream.repeatedly(fn -> Process.sleep(:infinity) end)}
      end)

      log =
        capture_log(fn ->
          assert {:error, %MatchError{}} = OpenFeature.set_provider(domain, InProcess.new(deadline_ms: 50))
        end)

      assert log =~ "received no flags within 50ms"
      assert_receive {:task, task}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
    end
  end
end
