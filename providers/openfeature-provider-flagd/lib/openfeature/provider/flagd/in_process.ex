defmodule OpenFeature.Provider.Flagd.InProcess do
  @moduledoc """
  OpenFeature provider for flagd that evaluates flags in-process.

  The provider streams the flag definition from flagd (or flagd-proxy) over the
  [sync protocol](https://flagd.dev/reference/specifications/in-process-providers/) and evaluates
  every flag locally, so no network call happens per evaluation. flagd's sync service listens on
  port 8015 by default.

  ## Options

  Constructor options win over environment variables, which win over defaults.

    * `:host` (`FLAGD_HOST`) - flagd host, default `"localhost"`
    * `:port` (`FLAGD_PORT`) - sync service port, default `8015`
    * `:tls` (`FLAGD_TLS`) - use TLS, default `false`
    * `:cacertfile` (`FLAGD_SERVER_CERT_PATH`) - path to a CA certificate file
    * `:cacerts` - CA certificates as DER-encoded binaries
    * `:selector` (`FLAGD_SOURCE_SELECTOR`) - restricts the flags flagd sends, for example
      `flagSetId=my-app` or `core.openfeature.dev/my-namespace/my-flags`
    * `:provider_id` (`FLAGD_PROVIDER_ID`) - identifies this client to flagd
    * `:deadline_ms` (`FLAGD_DEADLINE_MS`) - how long `initialize/3` waits for the first flag set,
      default `500`
    * `:stream_deadline_ms` (`FLAGD_STREAM_DEADLINE_MS`) - stream lifetime before it is reopened,
      default `600_000`
    * `:retry_backoff_ms` (`FLAGD_RETRY_BACKOFF_MS`) - initial reconnect backoff, default `1000`
    * `:retry_backoff_max_ms` (`FLAGD_RETRY_BACKOFF_MAX_MS`) - maximum reconnect backoff, default `5000`
    * `:retry_grace_period` (`FLAGD_RETRY_GRACE_PERIOD`) - seconds the provider stays `:stale` before
      emitting `:error`, default `10`
    * `:context_enricher` - function applied to the sync metadata flagd sends before it is merged
      underneath the evaluation context, default identity
    * `:name`, `:domain`, `:hooks` - as for the other providers

  ## Events

  The SDK emits `:ready` once `initialize/3` succeeds. Afterwards the provider emits
  `:configuration_changed` with `flags_changed: [keys]` whenever the flag set changes, `:stale` when
  the stream drops, `:error` when it stays down past the grace period, and `:ready` again on reconnect.
  Evaluations keep using the last flag set while disconnected.

  ## Example

      provider = OpenFeature.Provider.Flagd.InProcess.new(host: "flagd-proxy", selector: "flagSetId=my-app")
      {:ok, _} = OpenFeature.set_provider(provider)
  """
  @moduledoc since: "0.2.0"

  require Logger

  @behaviour OpenFeature.Provider

  alias OpenFeature.Provider.Flagd.InProcess.Evaluator
  alias OpenFeature.Provider.Flagd.InProcess.Sync
  alias OpenFeature.Types

  defstruct name: "FlagdInProcess",
            host: "localhost",
            port: 8015,
            tls: false,
            cacertfile: nil,
            cacerts: nil,
            selector: nil,
            provider_id: nil,
            deadline_ms: 500,
            stream_deadline_ms: 600_000,
            retry_backoff_ms: 1000,
            retry_backoff_max_ms: 5000,
            retry_grace_period: 10,
            context_enricher: &Function.identity/1,
            domain: nil,
            hooks: [],
            state: :not_ready,
            sync_ref: nil

  @typedoc "In-process provider for flagd"
  @type t() :: %__MODULE__{
          name: String.t(),
          host: String.t(),
          port: pos_integer(),
          tls: boolean(),
          cacertfile: String.t() | nil,
          cacerts: term() | nil,
          selector: String.t() | nil,
          provider_id: String.t() | nil,
          deadline_ms: pos_integer(),
          stream_deadline_ms: pos_integer(),
          retry_backoff_ms: pos_integer(),
          retry_backoff_max_ms: pos_integer(),
          retry_grace_period: non_neg_integer(),
          context_enricher: (map() -> map()),
          domain: String.t() | nil,
          hooks: [OpenFeature.Hook.t()],
          state: :not_ready | :ready,
          sync_ref: reference() | nil
        }

  @env_opts [
    host: {"FLAGD_HOST", :string},
    port: {"FLAGD_PORT", :integer},
    tls: {"FLAGD_TLS", :boolean},
    cacertfile: {"FLAGD_SERVER_CERT_PATH", :string},
    selector: {"FLAGD_SOURCE_SELECTOR", :string},
    provider_id: {"FLAGD_PROVIDER_ID", :string},
    deadline_ms: {"FLAGD_DEADLINE_MS", :integer},
    stream_deadline_ms: {"FLAGD_STREAM_DEADLINE_MS", :integer},
    retry_backoff_ms: {"FLAGD_RETRY_BACKOFF_MS", :integer},
    retry_backoff_max_ms: {"FLAGD_RETRY_BACKOFF_MAX_MS", :integer},
    retry_grace_period: {"FLAGD_RETRY_GRACE_PERIOD", :integer}
  ]

  @config_opts Keyword.keys(@env_opts) ++ [:cacerts, :context_enricher, :name, :domain, :hooks]

  @doc """
  Creates a new in-process flagd provider. See the module documentation for the options.
  """
  @doc since: "0.2.0"
  @spec new(opts :: Keyword.t()) :: t()
  def new(opts \\ []) do
    opts = Keyword.take(opts, @config_opts)

    env_opts =
      for {key, {var, type}} <- @env_opts,
          not Keyword.has_key?(opts, key),
          {:ok, value} <- [parse_env(System.get_env(var), type)],
          do: {key, value}

    struct(__MODULE__, Keyword.merge(env_opts, opts))
  end

  @impl true
  @spec initialize(provider :: t(), domain :: binary(), context :: Types.context()) ::
          {:ok, t()} | {:error, :provider_not_ready}
  def initialize(provider, domain, _context) do
    ref = make_ref()

    with {:ok, pid} <- Sync.start(provider, domain, ref),
         {:ok, _table} <- Sync.await_ready(pid, provider.deadline_ms) do
      {:ok, %{provider | domain: domain, state: :ready, sync_ref: ref}}
    else
      {:error, :timeout} ->
        Sync.stop(ref)
        Logger.error("flagd in-process provider received no flags within #{provider.deadline_ms}ms")
        {:error, :provider_not_ready}

      {:error, reason} ->
        Logger.error("flagd in-process provider could not start its sync process: #{inspect(reason)}")
        {:error, :provider_not_ready}
    end
  end

  @impl true
  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{sync_ref: ref}), do: Sync.stop(ref)

  @impl true
  @spec resolve_boolean_value(t(), String.t(), boolean(), Types.context()) :: OpenFeature.Provider.result()
  def resolve_boolean_value(provider, key, default, context) do
    resolve(provider, :boolean, key, default, context)
  end

  @impl true
  @spec resolve_string_value(t(), String.t(), String.t(), Types.context()) :: OpenFeature.Provider.result()
  def resolve_string_value(provider, key, default, context) do
    resolve(provider, :string, key, default, context)
  end

  @impl true
  @spec resolve_number_value(t(), String.t(), number(), Types.context()) :: OpenFeature.Provider.result()
  def resolve_number_value(provider, key, default, context) do
    resolve(provider, :number, key, default, context)
  end

  @impl true
  @spec resolve_map_value(t(), String.t(), map(), Types.context()) :: OpenFeature.Provider.result()
  def resolve_map_value(provider, key, default, context) do
    resolve(provider, :map, key, default, context)
  end

  # The table lives with the sync process and is found through the Registry, so evaluations keep
  # working after a supervisor restart.
  defp resolve(%__MODULE__{sync_ref: ref}, type, key, default, context) do
    case Sync.table(ref) do
      {:ok, table} -> Evaluator.resolve(table, type, key, default, context)
      :error -> Evaluator.not_ready(default, "flag sync process is not running")
    end
  end

  defp parse_env(nil, _type), do: :error
  defp parse_env("", _type), do: :error
  defp parse_env(value, :string), do: {:ok, value}
  defp parse_env(value, :boolean), do: {:ok, String.downcase(value) == "true"}

  defp parse_env(value, :integer) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end
end
