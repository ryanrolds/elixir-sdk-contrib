defmodule OpenFeature.Provider.Flagd.InProcess.Evaluator do
  @moduledoc false

  # Resolves flags from a Store using flagd's evaluation rules. The algorithm mirrors flagd's JSON
  # evaluator: disabled flags return the caller's default with reason :disabled, targeting picks a
  # variant by name (booleans and numbers are matched by their string form), a null rule result
  # falls back to the default variant, and a flag without a default variant resolves to the
  # caller's default with reason :default.

  alias OpenFeature.Provider.Flagd.InProcess.FlagSet.Flag
  alias OpenFeature.Provider.Flagd.InProcess.JsonLogic
  alias OpenFeature.Provider.Flagd.InProcess.Store
  alias OpenFeature.ResolutionDetails
  alias OpenFeature.Types

  @spec resolve(Store.table(), Types.flag_type(), binary(), Types.flag_value(), Types.context()) ::
          OpenFeature.Provider.result()
  def resolve(table, type, key, default, context) do
    case Store.flag(table, key) do
      {:ok, flag} ->
        metadata = merge_metadata(Store.metadata(table), flag.metadata)
        details = flag |> evaluate(key, default, build_context(table, context)) |> check_type(type, default)
        {:ok, %ResolutionDetails{details | flag_metadata: metadata}}

      :error ->
        {:error, :flag_not_found}

      :unavailable ->
        {:ok, error_details(default, :provider_not_ready, "flag store is unavailable")}
    end
  end

  @spec not_ready(Types.flag_value(), binary()) :: OpenFeature.Provider.result()
  def not_ready(default, message), do: {:ok, error_details(default, :provider_not_ready, message)}

  defp evaluate(%Flag{state: "DISABLED"}, _key, default, _context) do
    %ResolutionDetails{value: default, reason: :disabled}
  end

  defp evaluate(%Flag{targeting: targeting} = flag, _key, default, _context)
       when is_nil(targeting) or targeting == %{} do
    default_variant(flag, default)
  end

  defp evaluate(%Flag{} = flag, key, default, context) do
    case JsonLogic.evaluate(flag.targeting, Map.put(context, "$flagd", flagd_properties(key))) do
      {:ok, nil} ->
        default_variant(flag, default)

      {:ok, result} ->
        variant = JsonLogic.to_text(result)

        case Map.fetch(flag.variants, variant) do
          {:ok, value} -> %ResolutionDetails{value: value, variant: variant, reason: :targeting_match}
          :error -> error_details(default, :general, "targeting resolved to unknown variant #{inspect(variant)}")
        end

      {:error, %JsonLogic.Error{} = error} ->
        error_details(default, :parse_error, "targeting rule failed: #{Exception.message(error)}")
    end
  end

  defp default_variant(%Flag{default_variant: nil}, default), do: %ResolutionDetails{value: default, reason: :default}

  defp default_variant(%Flag{default_variant: variant, variants: variants, targeting: targeting}, _default) do
    reason = if is_nil(targeting) or targeting == %{}, do: :static, else: :default
    %ResolutionDetails{value: Map.fetch!(variants, variant), variant: variant, reason: reason}
  end

  defp check_type(%ResolutionDetails{variant: nil} = details, _type, _default), do: details

  defp check_type(%ResolutionDetails{value: value} = details, type, default) do
    if typed?(type, value) do
      details
    else
      error_details(default, :type_mismatch, "variant #{inspect(details.variant)} is not a #{type}")
    end
  end

  defp typed?(:boolean, value), do: is_boolean(value)
  defp typed?(:string, value), do: is_binary(value)
  defp typed?(:number, value), do: is_number(value)
  defp typed?(:map, value), do: is_map(value)

  defp error_details(default, code, message) do
    %ResolutionDetails{value: default, reason: :error, error_code: code, error_message: message}
  end

  defp merge_metadata(flag_set_metadata, flag_metadata) do
    flag_set_metadata
    |> Map.merge(flag_metadata)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The enriched sync context sits underneath the caller's context, which wins on conflict.
  defp build_context(table, context) do
    Map.merge(Store.enriched_context(table), stringify_keys(context))
  end

  defp flagd_properties(key), do: %{"flagKey" => key, "timestamp" => System.os_time(:second)}

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
