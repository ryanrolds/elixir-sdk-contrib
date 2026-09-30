defmodule OpenFeature.Provider.Flagd.InProcess.Fractional do
  @moduledoc false

  # The flagd fractional JsonLogic operator: deterministic weighted bucketing.
  #
  #     {"fractional": [{"var": "user.id"}, ["red", 50], ["blue", 50]]}
  #     {"fractional": [["red", 1], ["blue", 1]]}
  #
  # The bucketing key is the first element when it resolves to a string, otherwise
  # flagKey <> targetingKey. Each distribution is [variant] or [variant, weight] and the bucket is
  # (murmur3_x86_32(key) * total_weight) >>> 32, matching flagd's integer scheme.

  import Bitwise

  require Logger

  @max_int32 2_147_483_647

  # MurmurHash3 x86 32-bit constants
  @c1 0xCC9E2D51
  @c2 0x1B873593

  # Evaluates already-resolved operator arguments; nil on any malformed input.
  @spec evaluate(args :: list(), data :: map()) :: term()
  def evaluate(args, data) when is_list(args) and args != [] and is_map(data) do
    flag_key = get_in(data, ["$flagd", "flagKey"]) || ""

    case bucket_key(args, flag_key, data) do
      {:ok, key, distributions} ->
        distribute(key, distributions, flag_key)

      # Not an error: flagd falls through to the default variant when there is nothing to bucket on.
      {:error, :no_targeting_key} ->
        nil

      {:error, reason} ->
        log_ignored(flag_key, reason)
        nil
    end
  end

  def evaluate(_args, _data), do: nil

  # MurmurHash3 x86 32-bit with seed 0, as an unsigned integer.
  @spec murmur3_32(binary()) :: non_neg_integer()
  def murmur3_32(key) when is_binary(key), do: murmur_body(key, 0, byte_size(key))

  defp bucket_key([key | distributions], _flag_key, _data) when is_binary(key), do: {:ok, key, distributions}

  defp bucket_key([first | rest], flag_key, data) do
    distributions = if is_nil(first), do: rest, else: [first | rest]

    case Map.get(data, "targetingKey") do
      nil -> {:error, :no_targeting_key}
      "" -> {:error, :no_targeting_key}
      key when is_binary(key) -> {:ok, flag_key <> key, distributions}
      _ -> {:error, "targetingKey is not a string"}
    end
  end

  defp distribute(key, distributions, flag_key) do
    case parse_distributions(distributions) do
      {:ok, _variants, 0} ->
        nil

      {:ok, variants, total} ->
        pick((murmur3_32(key) * total) >>> 32, variants, 0)

      {:error, reason} ->
        log_ignored(flag_key, reason)
        nil
    end
  end

  defp parse_distributions(distributions) do
    distributions
    |> Enum.reduce_while({:ok, [], 0}, fn distribution, {:ok, acc, total} ->
      case parse_distribution(distribution) do
        {:ok, _variant, weight} when total + weight > @max_int32 -> {:halt, {:error, "sum of weights exceeds int32"}}
        {:ok, variant, weight} -> {:cont, {:ok, [{variant, weight} | acc], total + weight}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> finish_distributions()
  end

  defp finish_distributions({:ok, reversed, total}), do: {:ok, Enum.reverse(reversed), total}
  defp finish_distributions({:error, _} = error), do: error

  defp parse_distribution([variant])
       when is_binary(variant) or is_boolean(variant) or is_number(variant) or is_nil(variant),
       do: {:ok, variant, 1}

  defp parse_distribution([variant, weight | _])
       when is_binary(variant) or is_boolean(variant) or is_number(variant) or is_nil(variant),
       do: with({:ok, weight} <- parse_weight(weight), do: {:ok, variant, weight})

  defp parse_distribution([_ | _]), do: {:error, "variant must be a string, bool, number or null"}
  defp parse_distribution(_), do: {:error, "distribution must be a non-empty array"}

  defp parse_weight(nil), do: {:ok, 1}
  defp parse_weight(weight) when is_integer(weight) and weight > @max_int32, do: {:error, "weight exceeds int32"}
  defp parse_weight(weight) when is_integer(weight), do: {:ok, max(weight, 0)}

  defp parse_weight(weight) when is_float(weight) do
    if weight == trunc(weight), do: parse_weight(trunc(weight)), else: {:error, "weights must be integers"}
  end

  defp parse_weight(_), do: {:error, "weight must be a number"}

  # Walks the distributions accumulating weight until the bucket falls inside one.
  defp pick(_bucket, [], _range_end), do: nil

  defp pick(bucket, [{variant, weight} | rest], range_end) do
    range_end = range_end + weight
    if bucket < range_end, do: variant, else: pick(bucket, rest, range_end)
  end

  # Debug level: this runs on every evaluation of a misconfigured flag.
  defp log_ignored(flag_key, reason) do
    Logger.debug("fractional evaluation for flag #{inspect(flag_key)} ignored: #{reason}")
  end

  defp murmur_body(<<k::little-32, rest::binary>>, h, len) do
    h = bxor(h, mix_k(k))
    h = rotl32(h, 13)
    h = h * 5 + 0xE6546B64 &&& 0xFFFFFFFF
    murmur_body(rest, h, len)
  end

  defp murmur_body(tail, h, len) do
    k =
      case tail do
        <<a, b, c>> -> c <<< 16 ||| b <<< 8 ||| a
        <<a, b>> -> b <<< 8 ||| a
        <<a>> -> a
        <<>> -> 0
      end

    h = if k == 0, do: h, else: bxor(h, mix_k(k))
    fmix32(bxor(h, len))
  end

  defp mix_k(k) do
    k = k * @c1 &&& 0xFFFFFFFF
    k = rotl32(k, 15)
    k * @c2 &&& 0xFFFFFFFF
  end

  defp rotl32(x, r), do: (x <<< r ||| x >>> (32 - r)) &&& 0xFFFFFFFF

  defp fmix32(h) do
    h = bxor(h, h >>> 16)
    h = h * 0x85EBCA6B &&& 0xFFFFFFFF
    h = bxor(h, h >>> 13)
    h = h * 0xC2B2AE35 &&& 0xFFFFFFFF
    bxor(h, h >>> 16)
  end
end
