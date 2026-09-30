defmodule OpenFeature.Provider.Flagd do
  @moduledoc """
  Builds a flagd provider for the configured resolver.

  The resolver is chosen with the `:resolver` option, falling back to the `FLAGD_RESOLVER` environment
  variable and then to `:rpc`:

    * `:rpc` (`"rpc"`) - `OpenFeature.Provider.Flagd.GRPC`, evaluates every flag against flagd
    * `:in_process` (`"in-process"`) - `OpenFeature.Provider.Flagd.InProcess`, streams the flag
      definition and evaluates locally

  Remaining options are passed to the selected provider's `new/1`.

      provider = OpenFeature.Provider.Flagd.new(resolver: :in_process, selector: "flagSetId=my-app")
  """
  @moduledoc since: "0.2.0"

  alias OpenFeature.Provider.Flagd.GRPC
  alias OpenFeature.Provider.Flagd.InProcess

  @doc "Creates the provider for the resolver given in `opts` or `FLAGD_RESOLVER`."
  @doc since: "0.2.0"
  @spec new(opts :: Keyword.t()) :: GRPC.t() | InProcess.t()
  def new(opts \\ []) do
    {resolver, opts} = Keyword.pop(opts, :resolver)

    case resolver || System.get_env("FLAGD_RESOLVER") || :rpc do
      rpc when rpc in [:rpc, "rpc"] -> GRPC.new(opts)
      in_process when in_process in [:in_process, "in-process", "in_process"] -> InProcess.new(opts)
      other -> raise ArgumentError, "unsupported flagd resolver: #{inspect(other)}"
    end
  end
end
