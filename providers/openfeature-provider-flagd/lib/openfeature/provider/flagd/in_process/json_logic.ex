defmodule OpenFeature.Provider.Flagd.InProcess.JsonLogic do
  @moduledoc false

  # JsonLogic evaluator with the flagd extensions (fractional, sem_ver, starts_with, ends_with).
  # The base operators follow the semantics of the Go JsonLogic library used by flagd, so targeting
  # rules resolve the same way in-process as they do in a flagd instance.

  require Logger

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  alias OpenFeature.Provider.Flagd.InProcess.Fractional
  alias OpenFeature.Provider.Flagd.InProcess.SemVer

  # Malformed rules and unknown operators raise Error, which is returned; anything else is a bug and
  # propagates.
  @spec evaluate(rule :: term(), data :: map()) :: {:ok, term()} | {:error, Exception.t()}
  def evaluate(rule, data) do
    {:ok, eval(rule, data)}
  rescue
    error in Error -> {:error, error}
  end

  # Truthiness as defined by JsonLogic.
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(number) when is_number(number), do: number != 0
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(map) when map == %{}, do: false
  def truthy?(_), do: true

  # Renders a rule result as text, the way flagd does when matching it against variant names.
  @spec to_text(term()) :: binary()
  def to_text(nil), do: ""
  def to_text(value) when is_binary(value), do: value
  def to_text(value) when is_integer(value), do: Integer.to_string(value)

  def to_text(value) when is_float(value) do
    if value == trunc(value) and abs(value) < 1.0e15, do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  def to_text(true), do: "true"
  def to_text(false), do: "false"
  def to_text(value), do: Jason.encode!(value)

  defp eval(rule, data) when is_map(rule) and map_size(rule) == 1 do
    [{op, args}] = Map.to_list(rule)
    operator(op, List.wrap(args), data)
  end

  defp eval(list, data) when is_list(list), do: Enum.map(list, &eval(&1, data))
  defp eval(value, _data), do: value

  # Data access

  defp operator("var", [], data), do: data
  defp operator("var", [path | rest], data), do: var(eval(path, data), List.first(rest), data)

  defp operator("missing", args, data) do
    args
    |> Enum.map(&eval(&1, data))
    |> List.flatten()
    |> Enum.filter(&is_nil(var(&1, nil, data)))
  end

  defp operator("missing_some", [min, keys], data) do
    keys = eval(keys, data)
    missing = operator("missing", [keys], data)

    if length(keys) - length(missing) >= eval(min, data), do: [], else: missing
  end

  # Logic

  defp operator("if", args, data), do: if_chain(args, data)
  defp operator("?:", args, data), do: if_chain(args, data)

  defp operator("==", [a, b], data), do: loose_equal?(eval(a, data), eval(b, data))
  defp operator("!=", [a, b], data), do: not loose_equal?(eval(a, data), eval(b, data))
  defp operator("===", [a, b], data), do: strict_equal?(eval(a, data), eval(b, data))
  defp operator("!==", [a, b], data), do: not strict_equal?(eval(a, data), eval(b, data))
  defp operator("!", [a], data), do: not truthy?(eval(a, data))
  defp operator("!!", [a], data), do: truthy?(eval(a, data))

  defp operator("and", args, data) do
    Enum.reduce_while(args, true, fn arg, _ ->
      value = eval(arg, data)
      if truthy?(value), do: {:cont, value}, else: {:halt, value}
    end)
  end

  defp operator("or", args, data) do
    Enum.reduce_while(args, false, fn arg, _ ->
      value = eval(arg, data)
      if truthy?(value), do: {:halt, value}, else: {:cont, value}
    end)
  end

  # Comparison

  defp operator("<", args, data), do: compare_chain(args, data, &(&1 < &2))
  defp operator("<=", args, data), do: compare_chain(args, data, &(&1 <= &2))
  defp operator(">", args, data), do: compare_chain(args, data, &(&1 > &2))
  defp operator(">=", args, data), do: compare_chain(args, data, &(&1 >= &2))

  # Numeric

  defp operator("max", args, data), do: args |> numbers(data) |> Enum.max(fn -> nil end)
  defp operator("min", args, data), do: args |> numbers(data) |> Enum.min(fn -> nil end)
  defp operator("+", args, data), do: args |> numbers(data) |> Enum.sum()
  defp operator("*", args, data), do: args |> numbers(data) |> Enum.reduce(1, &(&1 * &2))

  defp operator("-", [a], data), do: -to_number(eval(a, data))
  defp operator("-", [a, b], data), do: to_number(eval(a, data)) - to_number(eval(b, data))

  defp operator("/", [a, b], data), do: divide(to_number(eval(a, data)), to_number(eval(b, data)))
  defp operator("%", [a, b], data), do: remainder(to_number(eval(a, data)), to_number(eval(b, data)))

  # Strings and arrays

  defp operator("cat", args, data), do: args |> Enum.map(&eval(&1, data)) |> List.flatten() |> Enum.map_join(&to_text/1)

  defp operator("substr", [subject | rest], data) do
    string = to_text(eval(subject, data))
    graphemes = String.graphemes(string)
    len = length(graphemes)

    {start, count} =
      case Enum.map(rest, &eval(&1, data)) do
        [] ->
          {0, len}

        [start] ->
          {normalize_index(start, len), len}

        [start, count] when count < 0 ->
          {normalize_index(start, len), max(len - normalize_index(start, len) + count, 0)}

        [start, count] ->
          {normalize_index(start, len), count}
      end

    graphemes |> Enum.slice(start, count) |> Enum.join()
  end

  defp operator("in", [needle, haystack], data) do
    case {eval(needle, data), eval(haystack, data)} do
      {n, h} when is_binary(n) and is_binary(h) -> String.contains?(h, n)
      {n, h} when is_list(h) -> Enum.any?(h, &loose_equal?(&1, n))
      _ -> false
    end
  end

  defp operator("merge", args, data), do: args |> Enum.map(&eval(&1, data)) |> List.flatten()

  defp operator("map", [list, fun], data), do: list |> eval_list(data) |> Enum.map(&eval(fun, &1))
  defp operator("filter", [list, fun], data), do: list |> eval_list(data) |> Enum.filter(&truthy?(eval(fun, &1)))

  defp operator("reduce", [list, fun, initial], data) do
    list
    |> eval_list(data)
    |> Enum.reduce(eval(initial, data), fn current, acc -> eval(fun, %{"current" => current, "accumulator" => acc}) end)
  end

  defp operator("all", [list, fun], data) do
    case eval_list(list, data) do
      [] -> false
      items -> Enum.all?(items, &truthy?(eval(fun, &1)))
    end
  end

  defp operator("some", [list, fun], data), do: list |> eval_list(data) |> Enum.any?(&truthy?(eval(fun, &1)))
  defp operator("none", [list, fun], data), do: not operator("some", [list, fun], data)

  defp operator("log", [a], data) do
    value = eval(a, data)
    Logger.debug("JsonLogic log: #{inspect(value)}")
    value
  end

  # flagd extensions. Arguments are evaluated before the operator sees them, as in the Go implementation.

  defp operator("fractional", args, data), do: Fractional.evaluate(Enum.map(args, &eval(&1, data)), data)
  defp operator("sem_ver", args, data), do: SemVer.evaluate(Enum.map(args, &eval(&1, data)))

  defp operator("starts_with", args, data), do: string_compare(args, data, &String.starts_with?/2)
  defp operator("ends_with", args, data), do: string_compare(args, data, &String.ends_with?/2)

  defp operator(op, args, _data) do
    raise Error, "unknown operator or invalid arguments: #{inspect(%{op => args})}"
  end

  defp string_compare(args, data, fun) do
    case Enum.map(args, &eval(&1, data)) do
      [value, target] when is_binary(value) and is_binary(target) -> fun.(value, target)
      _ -> nil
    end
  end

  defp var(path, default, data) do
    case lookup(path, data) do
      nil -> default
      value -> value
    end
  end

  defp lookup(nil, data), do: data
  defp lookup("", data), do: data
  defp lookup(index, data) when is_integer(index) and is_list(data), do: Enum.at(data, index)
  defp lookup(path, data) when is_binary(path), do: path |> String.split(".") |> Enum.reduce_while(data, &step/2)
  defp lookup(_path, _data), do: nil

  defp step(_key, nil), do: {:halt, nil}
  defp step(key, data) when is_map(data), do: {:cont, Map.get(data, key)}

  defp step(key, data) when is_list(data) do
    case Integer.parse(key) do
      {index, ""} -> {:cont, Enum.at(data, index)}
      _ -> {:halt, nil}
    end
  end

  defp step(_key, _data), do: {:halt, nil}

  defp if_chain([], _data), do: nil
  defp if_chain([only], data), do: eval(only, data)

  defp if_chain([condition, consequent | rest], data) do
    if truthy?(eval(condition, data)), do: eval(consequent, data), else: if_chain(rest, data)
  end

  defp compare_chain(args, data, fun) do
    values = Enum.map(args, &eval(&1, data))

    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> compare(a, b, fun) end)
  end

  defp compare(a, b, fun) when is_binary(a) and is_binary(b) do
    case {parse_number(a), parse_number(b)} do
      {{:ok, x}, {:ok, y}} -> fun.(x, y)
      _ -> fun.(a, b)
    end
  end

  defp compare(a, b, fun) do
    case {coerce_number(a), coerce_number(b)} do
      {{:ok, x}, {:ok, y}} -> fun.(x, y)
      _ -> false
    end
  end

  # JavaScript-style loose equality for the combinations that show up in flag rules.
  defp loose_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp loose_equal?(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp loose_equal?(nil, nil), do: true
  defp loose_equal?(nil, _), do: false
  defp loose_equal?(_, nil), do: false

  defp loose_equal?(a, b) do
    case {coerce_number(a), coerce_number(b)} do
      {{:ok, x}, {:ok, y}} -> x == y
      _ -> a == b
    end
  end

  defp strict_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp strict_equal?(a, b), do: a === b

  defp numbers(args, data), do: args |> Enum.map(&eval(&1, data)) |> List.flatten() |> Enum.map(&to_number/1)

  defp to_number(value) do
    case coerce_number(value) do
      {:ok, number} -> number
      :error -> raise Error, "not a number: #{inspect(value)}"
    end
  end

  defp coerce_number(n) when is_number(n), do: {:ok, n}
  defp coerce_number(true), do: {:ok, 1}
  defp coerce_number(false), do: {:ok, 0}
  defp coerce_number(nil), do: {:ok, 0}
  defp coerce_number(s) when is_binary(s), do: parse_number(s)
  defp coerce_number(_), do: :error

  defp parse_number(s) do
    trimmed = String.trim(s)

    case Integer.parse(trimmed) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp divide(a, b) when is_integer(a) and is_integer(b) and b != 0 and rem(a, b) == 0, do: div(a, b)
  defp divide(a, b), do: a / b

  defp remainder(a, b) when is_integer(a) and is_integer(b), do: rem(a, b)
  defp remainder(a, b), do: :math.fmod(a, b)

  defp eval_list(list, data) do
    case eval(list, data) do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp normalize_index(start, len) when start < 0, do: max(len + start, 0)
  defp normalize_index(start, _len), do: start
end
