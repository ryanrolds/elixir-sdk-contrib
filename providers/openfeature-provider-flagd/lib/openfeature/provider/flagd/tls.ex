defmodule OpenFeature.Provider.Flagd.TLS do
  @moduledoc false

  require Logger

  alias OpenFeature.Provider.Flagd.GRPC, as: FlagdGRPC
  alias OpenFeature.Provider.Flagd.InProcess

  # gRPC connection options from a provider's tls, cacerts and cacertfile fields.
  @spec connection_opts(FlagdGRPC.t() | InProcess.t()) :: Keyword.t()
  def connection_opts(%{tls: true, cacerts: cacerts}) when not is_nil(cacerts) do
    [cred: GRPC.Credential.new(ssl: [cacerts: cacerts])]
  end

  def connection_opts(%{tls: true, cacertfile: cacertfile}) when is_binary(cacertfile) do
    [cred: GRPC.Credential.new(ssl: [cacertfile: cacertfile])]
  end

  def connection_opts(%{tls: true}) do
    # The system certificate store needs OTP 25+
    if function_exported?(:public_key, :cacerts_get, 0) do
      [cred: GRPC.Credential.new(ssl: [cacerts: :public_key.cacerts_get()])]
    else
      Logger.info("System CA certificate store unavailable (requires OTP 25+)")
      [cred: GRPC.Credential.new(ssl: true)]
    end
  rescue
    _ ->
      Logger.warning("Could not load system CA certificates, using default SSL configuration")
      [cred: GRPC.Credential.new(ssl: true)]
  end

  def connection_opts(_provider), do: []
end
