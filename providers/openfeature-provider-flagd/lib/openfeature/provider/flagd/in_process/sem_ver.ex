defmodule OpenFeature.Provider.Flagd.InProcess.SemVer do
  @moduledoc false

  # The flagd sem_ver JsonLogic operator:
  #
  #     {"sem_ver": [{"var": "version"}, ">=", "1.2.0"]}
  #
  # Operators: =, !=, <, <=, >, >=, ~ (same major and minor) and ^ (same major). Versions follow
  # golang.org/x/mod/semver: an optional leading v, minor and patch may be omitted, and build
  # metadata is ignored when comparing. Elixir's Version handles everything but the optional parts,
  # so those are padded before parsing.

  @operators ~w(= != < <= > >= ~ ^)

  @version_regex ~r/^[vV]?(?<major>\d+)(?<minor>\.\d+)?(?<patch>\.\d+)?(?<rest>[-+].*)?$/

  # Evaluates already-resolved operator arguments; nil for anything that is not a valid comparison.
  @spec evaluate(args :: list()) :: boolean() | nil
  def evaluate([actual, op, target]) when op in @operators do
    with {:ok, actual} <- parse(actual),
         {:ok, target} <- parse(target) do
      compare(op, actual, target)
    else
      :error -> nil
    end
  end

  def evaluate(_args), do: nil

  @spec parse(term()) :: {:ok, Version.t()} | :error
  def parse(value) when is_binary(value) do
    case Regex.named_captures(@version_regex, value) do
      %{"major" => major, "minor" => minor, "patch" => patch, "rest" => rest} ->
        Version.parse(major <> pad(minor) <> pad(patch) <> rest)

      nil ->
        :error
    end
  end

  def parse(value) when is_integer(value), do: parse(Integer.to_string(value))
  def parse(value) when is_float(value), do: parse(Float.to_string(value))
  def parse(_), do: :error

  defp pad(""), do: ".0"
  defp pad(part), do: part

  defp compare("=", a, b), do: Version.compare(a, b) == :eq
  defp compare("!=", a, b), do: Version.compare(a, b) != :eq
  defp compare("<", a, b), do: Version.compare(a, b) == :lt
  defp compare("<=", a, b), do: Version.compare(a, b) != :gt
  defp compare(">", a, b), do: Version.compare(a, b) == :gt
  defp compare(">=", a, b), do: Version.compare(a, b) != :lt
  defp compare("~", a, b), do: a.major == b.major and a.minor == b.minor
  defp compare("^", a, b), do: a.major == b.major
end
