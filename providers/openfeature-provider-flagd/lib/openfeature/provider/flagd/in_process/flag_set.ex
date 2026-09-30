defmodule OpenFeature.Provider.Flagd.InProcess.FlagSet do
  @moduledoc false

  # A parsed flagd flag definition document, see https://flagd.dev/reference/flag-definitions/.
  # Shared $evaluators are inlined into each flag's targeting rule at parse time so evaluation never
  # has to resolve $ref.

  defmodule Flag do
    @moduledoc false

    defstruct state: "ENABLED", variants: %{}, default_variant: nil, targeting: nil, metadata: %{}

    @type t :: %__MODULE__{
            state: binary(),
            variants: %{optional(binary()) => term()},
            default_variant: binary() | nil,
            targeting: map() | nil,
            metadata: map()
          }
  end

  defstruct flags: %{}, metadata: %{}

  @type t :: %__MODULE__{flags: %{optional(binary()) => Flag.t()}, metadata: map()}

  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(json) when is_binary(json) do
    with {:ok, document} when is_map(document) <- Jason.decode(json),
         {:ok, evaluators} <- fetch_map(document, "$evaluators"),
         {:ok, metadata} <- fetch_map(document, "metadata"),
         {:ok, flags} <- parse_flags(Map.get(document, "flags"), evaluators) do
      {:ok, %__MODULE__{flags: flags, metadata: metadata}}
    else
      {:ok, _} -> {:error, :invalid_document}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, Exception.message(error)}}
      {:error, _} = error -> error
    end
  end

  # Keys whose definition differs between two flag maps, sorted.
  @spec changed_keys(%{optional(binary()) => Flag.t()}, %{optional(binary()) => Flag.t()}) :: [binary()]
  def changed_keys(old, new) do
    old
    |> Map.keys()
    |> Enum.concat(Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
    |> Enum.sort()
  end

  defp fetch_map(document, key) do
    case Map.get(document, key, %{}) do
      map when is_map(map) -> {:ok, map}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_flags(flags, evaluators) when is_map(flags) do
    Enum.reduce_while(flags, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case parse_flag(key, raw, evaluators) do
        {:ok, flag} -> {:cont, {:ok, Map.put(acc, key, flag)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # flagd also accepts the flags as an array of objects carrying their own key.
  defp parse_flags(flags, evaluators) when is_list(flags) do
    if Enum.all?(flags, &(is_map(&1) and is_binary(Map.get(&1, "key")))) do
      flags |> Map.new(&{Map.fetch!(&1, "key"), &1}) |> parse_flags(evaluators)
    else
      {:error, {:invalid_field, "flags"}}
    end
  end

  defp parse_flags(_flags, _evaluators), do: {:error, {:invalid_field, "flags"}}

  defp parse_flag(key, raw, evaluators) when is_map(raw) do
    flag = %Flag{
      state: Map.get(raw, "state") || "ENABLED",
      variants: Map.get(raw, "variants") || %{},
      default_variant: Map.get(raw, "defaultVariant"),
      targeting: Map.get(raw, "targeting"),
      metadata: Map.get(raw, "metadata") || %{}
    }

    case validate_flag(flag) do
      :ok -> {:ok, %Flag{flag | targeting: inline_refs(flag.targeting, evaluators)}}
      {:error, message} -> {:error, {:invalid_flag, key, message}}
    end
  end

  defp parse_flag(key, _raw, _evaluators), do: {:error, {:invalid_flag, key, "must be an object"}}

  defp validate_flag(%Flag{variants: variants}) when not is_map(variants), do: {:error, "variants must be an object"}

  defp validate_flag(%Flag{targeting: targeting}) when not (is_nil(targeting) or is_map(targeting)),
    do: {:error, "targeting must be an object"}

  defp validate_flag(%Flag{metadata: metadata}) when not is_map(metadata), do: {:error, "metadata must be an object"}

  defp validate_flag(%Flag{default_variant: default, variants: variants}) do
    cond do
      is_nil(default) -> :ok
      not is_binary(default) -> {:error, "defaultVariant must be a string"}
      Map.has_key?(variants, default) -> :ok
      true -> {:error, "default variant #{inspect(default)} is not a variant"}
    end
  end

  # Unknown references are left in place so they surface as a parse error at evaluation time.
  # Evaluators are not expanded recursively; flagd does not support nested references either.
  defp inline_refs(%{"$ref" => name} = node, evaluators) when map_size(node) == 1 do
    Map.get(evaluators, name, node)
  end

  defp inline_refs(node, evaluators) when is_map(node),
    do: Map.new(node, fn {k, v} -> {k, inline_refs(v, evaluators)} end)

  defp inline_refs(node, evaluators) when is_list(node), do: Enum.map(node, &inline_refs(&1, evaluators))
  defp inline_refs(node, _evaluators), do: node
end
