# Flagd Provider for OpenFeature

An OpenFeature provider for `flagd`, enabling feature flag evaluation in Elixir using gRPC or HTTP, or in-process over the flagd sync protocol.

This library integrates with the OpenFeature SDK for Elixir and supports remote evaluation via `flagd` using gRPC or HTTP, and in-process evaluation of a flag set streamed from `flagd` or `flagd-proxy`.

## Installation

Add `open_feature_flagd_provider` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:open_feature_provider_flagd, "~> 0.1.0"}]
end
```

## Providers

This library supports:

- `OpenFeature.Provider.Flagd.HTTP`
- `OpenFeature.Provider.Flagd.GRPC`
- `OpenFeature.Provider.Flagd.InProcess`

All providers implement the `OpenFeature.Provider` behaviour and can be used with the OpenFeature SDK. This means you can swap between providers (e.g. `gRPC`, `HTTP` or in-process) with no changes to your application code beyond provider initialization.

`OpenFeature.Provider.Flagd.new/1` picks the gRPC or in-process provider from the `:resolver` option or the `FLAGD_RESOLVER` environment variable (`rpc` or `in-process`), so a deployment can switch between remote and in-process evaluation without a code change.

## Usage

### gRPC Provider

```elixir
# Simple usage with defaults
provider = OpenFeature.Provider.Flagd.GRPC.new()

# With custom options
provider = OpenFeature.Provider.Flagd.GRPC.new(
  host: "flagd.example.com",
  port: 8013,
  tls: true,
  cacertfile: "/path/to/cert.pem"
)

{:ok, _} = OpenFeature.set_provider(provider)
client = OpenFeature.get_client()
OpenFeature.Client.get_boolean_value(client, "my-feature", false)
```

### Event Streaming

The gRPC provider supports event streaming via the EventStream module. This allows your application to receive `:ready` and `:configuration_changed` events from flagd.

To enable streaming, you must start the stream manually using `OpenFeature.Provider.Flagd.GRPC.EventStream.start_link(client)`. The stream runs as a long-lived `GenServer` and should be supervised using either static or dynamic supervision, depending on your needs.

For setup examples and supervision options, see the `EventStream` module documentation.

### HTTP Provider

```elixir
# Simple usage with defaults
provider = OpenFeature.Provider.Flagd.HTTP.new()

# With custom options
provider = OpenFeature.Provider.Flagd.HTTP.new(
  scheme: "https",
  host: "flagd.example.com",
  port: 8013
)

{:ok, _} = OpenFeature.set_provider(provider)
client = OpenFeature.get_client()
OpenFeature.Client.get_boolean_value(client, "my-feature", false)
```

### In-Process Provider

The in-process provider streams the whole flag definition from `flagd` (or `flagd-proxy`) over the sync protocol and evaluates flags locally, including targeting rules and the `fractional`, `sem_ver`, `starts_with` and `ends_with` operators. No network call is made per evaluation and no sidecar is needed. The sync service listens on port 8015 by default.

```elixir
provider = OpenFeature.Provider.Flagd.InProcess.new(
  host: "flagd-proxy",
  selector: "flagSetId=my-app",
  deadline_ms: 2000
)

{:ok, _} = OpenFeature.set_provider(provider)
client = OpenFeature.get_client()
OpenFeature.Client.get_boolean_value(client, "my-feature", false)
```

Every option has an environment variable fallback (`FLAGD_HOST`, `FLAGD_PORT`, `FLAGD_TLS`, `FLAGD_SOURCE_SELECTOR`, `FLAGD_DEADLINE_MS` and so on), listed in the module documentation. `initialize/3` waits up to `deadline_ms` (500 ms by default) for the first flag set; raise it if `flagd` is not on the same host.

The provider emits `:configuration_changed` (with `flags_changed: [keys]`) when the flag set changes, `:stale` when the stream drops, `:error` when it is still down after `retry_grace_period` seconds, and `:ready` again once it reconnects. Evaluations keep using the last flag set while disconnected. No extra process needs to be started or supervised; the provider manages the stream itself.

Sync metadata sent by `flagd` is merged underneath the evaluation context, so rules can target it. Pass a `:context_enricher` function to filter or reshape it first.

## Regenerating gRPC Protos (Development Only)

This project includes a mix task to download and generate Elixir modules from the latest [`flagd`](https://buf.build/open-feature/flagd) protobuf definitions.

To regenerate:

```sh
mix proto.gen
```

> [!NOTE]
> You must have both `protoc` and `protoc-gen-elixir` available in your system `PATH` for this task to work. See the [official docs](https://hexdocs.pm/protobuf/readme.html#generate-elixir-code) for installation instructions.

## Roadmap

- [ ] Cache resolution details
- [x] In-process provider using the flagd sync protocol
