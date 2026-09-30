defmodule OpenFeature.Provider.Flagd.InProcess.Store do
  @moduledoc false

  # ETS-backed flag storage. The table is public with read concurrency so evaluations read it
  # directly and never wait on the sync process. One row per flag keeps lookups cheap regardless of
  # flag set size.

  alias OpenFeature.Provider.Flagd.InProcess.FlagSet
  alias OpenFeature.Provider.Flagd.InProcess.FlagSet.Flag

  @type table :: :ets.tid()

  @spec new() :: table()
  def new, do: :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

  # New rows are written before removed flags are deleted so readers never see an empty table.
  @spec put(table(), FlagSet.t(), map(), [binary()]) :: :ok
  def put(table, %FlagSet{flags: flags, metadata: metadata}, enriched_context, removed_keys) do
    rows = Enum.map(flags, fn {key, flag} -> {{:flag, key}, flag} end)
    :ets.insert(table, [{:metadata, metadata}, {:enriched_context, enriched_context} | rows])
    Enum.each(removed_keys, &:ets.delete(table, {:flag, &1}))
    :ok
  end

  @spec flag(table(), binary()) :: {:ok, Flag.t()} | :error | :unavailable
  def flag(table, key) do
    case lookup(table, {:flag, key}) do
      [{_, flag}] -> {:ok, flag}
      [] -> :error
      :unavailable -> :unavailable
    end
  end

  @spec metadata(table()) :: map()
  def metadata(table), do: value(table, :metadata)

  @spec enriched_context(table()) :: map()
  def enriched_context(table), do: value(table, :enriched_context)

  defp value(table, key) do
    case lookup(table, key) do
      [{_, map}] -> map
      _ -> %{}
    end
  end

  # The table dies with the sync process, and Registry cleanup lags that by a message, so a lookup
  # can race the owner's exit. Only the ETS call itself is guarded.
  defp lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> :unavailable
  end
end
