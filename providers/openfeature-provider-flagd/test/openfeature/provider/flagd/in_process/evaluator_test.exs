defmodule OpenFeature.Provider.Flagd.InProcess.EvaluatorTest do
  use ExUnit.Case, async: true

  alias OpenFeature.Provider.Flagd.InProcess.Evaluator
  alias OpenFeature.Provider.Flagd.InProcess.FlagSet
  alias OpenFeature.Provider.Flagd.InProcess.Store
  alias OpenFeature.ResolutionDetails

  @fixture Path.expand("../../../../fixtures/flagd-testbed/testkit-flags.json", __DIR__)

  setup_all do
    {:ok, flag_set} = @fixture |> File.read!() |> FlagSet.parse()
    table = Store.new()
    Store.put(table, flag_set, %{}, [])
    %{table: table}
  end

  defp resolve(table, type, key, default, context \\ %{}) do
    Evaluator.resolve(table, type, key, default, context)
  end

  describe "evaluation.feature" do
    test "resolves basic values", %{table: table} do
      assert {:ok, %ResolutionDetails{value: true, reason: :static}} = resolve(table, :boolean, "boolean-flag", false)
      assert {:ok, %ResolutionDetails{value: "hi"}} = resolve(table, :string, "string-flag", "bye")
      assert {:ok, %ResolutionDetails{value: 10}} = resolve(table, :number, "integer-flag", 1)
      assert {:ok, %ResolutionDetails{value: 0.5}} = resolve(table, :number, "float-flag", 0.1)

      assert {:ok,
              %ResolutionDetails{
                value: %{"showImages" => true, "title" => "Check out these pics!", "imagesPerPage" => 100}
              }} =
               resolve(table, :map, "object-flag", %{})
    end
  end

  describe "errors.feature" do
    test "flag not found", %{table: table} do
      assert {:error, :flag_not_found} = resolve(table, :string, "missing-flag", "uh-oh")
    end

    test "type mismatch", %{table: table} do
      assert {:ok, %ResolutionDetails{value: 13, reason: :error, error_code: :type_mismatch}} =
               resolve(table, :number, "wrong-flag", 13)
    end
  end

  describe "disabled.feature" do
    for {key, type, default} <- [
          {"disabled-boolean-flag", :boolean, false},
          {"disabled-string-flag", :string, "bye"},
          {"disabled-integer-flag", :number, 1},
          {"disabled-float-flag", :number, 0.1},
          {"disabled-object-flag", :map, %{}}
        ] do
      test "#{key} resolves the default with reason DISABLED", %{table: table} do
        assert {:ok, %ResolutionDetails{value: unquote(Macro.escape(default)), reason: :disabled, variant: nil}} =
                 resolve(table, unquote(type), unquote(key), unquote(Macro.escape(default)))
      end
    end
  end

  describe "zero-values.feature" do
    for {key, type, default, expected} <- [
          {"boolean-zero-flag", :boolean, true, false},
          {"string-zero-flag", :string, "hi", ""},
          {"integer-zero-flag", :number, 1, 0},
          {"float-zero-flag", :number, 0.1, 0.0},
          {"object-zero-flag", :map, %{"a" => 1}, %{}}
        ] do
      test "#{key} resolves statically", %{table: table} do
        assert {:ok, %ResolutionDetails{value: value, reason: :static}} =
                 resolve(table, unquote(type), unquote(key), unquote(Macro.escape(default)))

        assert value == unquote(Macro.escape(expected))
      end
    end

    for {key, type, default, expected} <- [
          {"boolean-targeted-zero-flag", :boolean, true, false},
          {"string-targeted-zero-flag", :string, "hi", ""},
          {"integer-targeted-zero-flag", :number, 1, 0},
          {"float-targeted-zero-flag", :number, 0.1, 0.0}
        ] do
      test "#{key} resolves with targeting match", %{table: table} do
        context = %{"email" => "ballmer@macrosoft.com"}

        assert {:ok, %ResolutionDetails{value: value, reason: :targeting_match}} =
                 resolve(table, unquote(type), unquote(key), unquote(Macro.escape(default)), context)

        assert value == unquote(Macro.escape(expected))
      end

      test "#{key} resolves the default variant when targeting misses", %{table: table} do
        context = %{"email" => "ballmer@none.com"}

        assert {:ok, %ResolutionDetails{value: value, reason: :default}} =
                 resolve(table, unquote(type), unquote(key), unquote(Macro.escape(default)), context)

        assert value == unquote(Macro.escape(expected))
      end
    end
  end

  describe "no-default-variant.feature" do
    for {key, type, email, default, expected, reason} <- [
          {"null-default-flag", :boolean, nil, true, true, :default},
          {"null-default-flag", :boolean, nil, false, false, :default},
          {"undefined-default-flag", :number, nil, 100, 100, :default},
          {"no-default-flag-null-targeting-variant", :string, "wozniak@orange.com", "Inventor", "Inventor", :default},
          {"no-default-flag-null-targeting-variant", :string, "jobs@orange.com", "CEO", "CEO", :targeting_match},
          {"no-default-flag-undefined-targeting-variant", :string, "wozniak@orange.com", "Retired", "Retired", :default}
        ] do
      test "#{key} with default #{inspect(default)} and email #{inspect(email)}", %{table: table} do
        context = if unquote(email), do: %{"email" => unquote(email)}, else: %{}

        assert {:ok, %ResolutionDetails{value: unquote(expected), reason: unquote(reason)}} =
                 resolve(table, unquote(type), unquote(key), unquote(default), context)
      end
    end
  end

  describe "targeting.feature" do
    test "targeting by targeting key", %{table: table} do
      hit = %{"targetingKey" => "5c3d8535-f81a-4478-a6d3-afaa4d51199e"}
      miss = %{"targetingKey" => "f20bd32d-703b-48b6-bc8e-79d53c85134a"}

      assert {:ok, %ResolutionDetails{value: "hit", reason: :targeting_match}} =
               resolve(table, :string, "targeting-key-flag", "fallback", hit)

      assert {:ok, %ResolutionDetails{value: "miss", reason: :default}} =
               resolve(table, :string, "targeting-key-flag", "fallback", miss)
    end

    test "atom context keys are stringified", %{table: table} do
      context = %{targetingKey: "5c3d8535-f81a-4478-a6d3-afaa4d51199e"}

      assert {:ok, %ResolutionDetails{value: "hit"}} =
               resolve(table, :string, "targeting-key-flag", "fallback", context)
    end
  end

  describe "evaluator-refs.feature" do
    for {key, email, expected} <- [
          {"some-email-targeted-flag", "ballmer@macrosoft.com", "hi"},
          {"some-other-email-targeted-flag", "ballmer@macrosoft.com", "yes"},
          {"ref-whitespace-compact-flag", "ballmer@macrosoft.com", "hi"},
          {"ref-whitespace-space-after-colon-flag", "ballmer@macrosoft.com", "hi"},
          {"ref-whitespace-space-around-colon-flag", "ballmer@macrosoft.com", "hi"},
          {"ref-whitespace-compact-flag", "user@example.com", "bye"},
          {"ref-whitespace-space-after-colon-flag", "user@example.com", "bye"},
          {"ref-whitespace-space-around-colon-flag", "user@example.com", "bye"}
        ] do
      test "#{key} with #{email} resolves #{expected}", %{table: table} do
        assert {:ok, %ResolutionDetails{value: unquote(expected), reason: :targeting_match}} =
                 resolve(table, :string, unquote(key), "fallback", %{"email" => unquote(email)})
      end
    end

    test "ref to nonexistent evaluator yields a parse error", %{table: table} do
      assert {:ok, %ResolutionDetails{value: "fallback", reason: :error, error_code: :parse_error}} =
               resolve(table, :string, "ref-to-nonexistent-evaluator-flag", "fallback")
    end
  end

  describe "fractional.feature" do
    for {name, expected} <- [jack: "hearts", queen: "spades", ten: "clubs", nine: "diamonds", "3": "clubs"] do
      test "fractional operator buckets #{name} into #{expected}", %{table: table} do
        context = %{"user" => %{"name" => unquote(to_string(name))}}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-flag", "fallback", context)
      end
    end

    for {key, expected} <- [{"jon@company.com", "heads"}, {"jane@company.com", "tails"}] do
      test "fractional shorthand buckets #{key} into #{expected}", %{table: table} do
        context = %{"targetingKey" => unquote(key)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-flag-shorthand", "fallback", context)
      end
    end

    for {name, a, b} <- [
          {"seven", "hearts", "ace-of-hearts"},
          {"eight", "diamonds", "ace-of-diamonds"},
          {"nine", "clubs", "ace-of-clubs"},
          {"two", "spades", "ace-of-spades"}
        ] do
      test "shared seed buckets #{name} consistently", %{table: table} do
        context = %{"user" => %{"name" => unquote(name)}}

        assert {:ok, %ResolutionDetails{value: unquote(a)}} =
                 resolve(table, :string, "fractional-flag-A-shared-seed", "fallback", context)

        assert {:ok, %ResolutionDetails{value: unquote(b)}} =
                 resolve(table, :string, "fractional-flag-B-shared-seed", "fallback", context)
      end
    end

    test "single entry always resolves to the only variant", %{table: table} do
      context = %{"targetingKey" => "some-targeting-key"}

      assert {:ok, %ResolutionDetails{value: "single"}} =
               resolve(table, :string, "fractional-single-entry-flag", "fallback", context)
    end

    for {key, expected} <- [
          {"ejOoVL", "lower"},
          {"bY9fO-", "lower"},
          {"SI7p-", "lower"},
          {"6LvT0", "upper"},
          {"ceQdGm", "upper"}
        ] do
      test "hash edge case #{key} resolves #{expected}", %{table: table} do
        context = %{"targetingKey" => unquote(key)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-hash-edge-flag", "fallback", context)
      end
    end

    for {targeting_key, tier, expected} <- [
          {"jon@company.com", "premium", "premium"},
          {"jon@company.com", "basic", "standard"},
          {"user1", "premium", "standard"},
          {"user1", "basic", "standard"}
        ] do
      test "nested if as variant name: #{targeting_key} #{tier}", %{table: table} do
        context = %{"targetingKey" => unquote(targeting_key), "tier" => unquote(tier)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-nested-if-flag", "fallback", context)
      end
    end

    for {targeting_key, color, expected} <- [
          {"jon@company.com", "red", "red"},
          {"jon@company.com", "green", "green"},
          {"user1", "red", "blue"},
          {"jon@company.com", "yellow", "fallback"},
          {"jon@company.com", "", "fallback"}
        ] do
      test "nested var as variant name: #{targeting_key} #{inspect(color)}", %{table: table} do
        context = %{"targetingKey" => unquote(targeting_key), "color" => unquote(color)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-nested-var-flag", "fallback", context)
      end
    end

    for {targeting_key, tier, expected} <- [
          {"jon@company.com", "premium", "red"},
          {"jon@company.com", "basic", "blue"},
          {"user1", "premium", "red"},
          {"user1", "basic", "blue"}
        ] do
      test "nested if as weight: #{targeting_key} #{tier}", %{table: table} do
        context = %{"targetingKey" => unquote(targeting_key), "tier" => unquote(tier)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "fractional-nested-weight-flag", "fallback", context)
      end
    end

    test "fractional as condition", %{table: table} do
      context = %{"targetingKey" => "some-targeting-key"}

      assert {:ok, %ResolutionDetails{value: "hundreds"}} =
               resolve(table, :string, "fractional-as-condition-flag", "zero", context)

      assert {:ok, %ResolutionDetails{value: "ones"}} =
               resolve(table, :string, "fractional-as-condition-false-flag", "zero", context)
    end

    test "missing bucket key falls back to the default variant", %{table: table} do
      assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
               resolve(table, :string, "fractional-null-bucket-key-flag", "wrong")
    end

    test "all-zero weights fall back to the default variant", %{table: table} do
      context = %{"targetingKey" => "any-user"}

      assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
               resolve(table, :string, "fractional-zero-weights-flag", "wrong", context)
    end

    test "negative weight is clamped to zero", %{table: table} do
      context = %{"targetingKey" => "any-user"}

      assert {:ok, %ResolutionDetails{value: "two"}} =
               resolve(table, :string, "fractional-negative-weight-flag", "wrong", context)
    end
  end

  describe "semver.feature" do
    for {version, expected} <- [
          {"2.0.0", "equal"},
          {"2.1.0", "greater"},
          {"1.9.0", "lesser"},
          {"2.0.0-alpha", "lesser"},
          {"2.0.0.0", "none"}
        ] do
      test "numeric comparison #{version} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "equal-greater-lesser-version-flag", "fallback", context)
      end
    end

    for {version, expected} <- [{"3.0.1", "minor"}, {"3.1.0", "major"}, {"4.0.0", "none"}] do
      test "range comparison #{version} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "major-minor-version-flag", "fallback", context)
      end
    end

    for {key, value} <- [{"semver-invalid-version-flag", "not-a-version"}, {"semver-invalid-operator-flag", "1.0.0"}] do
      test "#{key} falls back to the default variant", %{table: table} do
        context = %{"version" => unquote(value)}

        assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
                 resolve(table, :string, unquote(key), "wrong", context)
      end
    end

    for {version, expected} <- [{"1.0.0", "match"}, {"v1.0.0", "match"}, {"V1.0.0", "match"}, {"2.0.0", "no-match"}] do
      test "v prefix #{version} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "semver-v-prefix-flag", "fallback", context)
      end
    end

    for {version, expected} <- [
          {"1.5.0", "match"},
          {"1.0.0", "match"},
          {"1.0", "match"},
          {"1", "match"},
          {1, "match"},
          {1.0, "match"},
          {1.2, "match"},
          {"2.0.0", "no-match"}
        ] do
      test "partial version #{inspect(version)} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "semver-partial-version-flag", "fallback", context)
      end
    end

    for {version, expected} <- [{1.2, "match"}, {1.1, "no-match"}, {2, "match"}, {1, "no-match"}, {"1.2", "match"}] do
      test "numeric context #{inspect(version)} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "semver-numeric-context-flag", "fallback", context)
      end
    end

    for {version, expected} <- [{"1.0.0", "match"}, {"1.0.0+other", "match"}, {"2.0.0", "no-match"}] do
      test "build metadata #{version} is #{expected}", %{table: table} do
        context = %{"version" => unquote(version)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "semver-build-metadata-flag", "fallback", context)
      end
    end

    test "wrong argument count falls back to the default variant", %{table: table} do
      context = %{"version" => "1.0.0"}

      assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
               resolve(table, :string, "semver-wrong-args-flag", "wrong", context)
    end
  end

  describe "string.feature" do
    for {id, expected} <- [{"abcdef", "prefix"}, {"uvwxyz", "postfix"}, {"abcxyz", "prefix"}, {"lmnopq", "none"}] do
      test "substring operators on #{id} give #{expected}", %{table: table} do
        context = %{"id" => unquote(id)}

        assert {:ok, %ResolutionDetails{value: unquote(expected)}} =
                 resolve(table, :string, "starts-ends-flag", "fallback", context)
      end
    end

    for key <- ["starts-with-non-string-flag", "ends-with-non-string-flag"] do
      test "#{key} returns null for non-string input", %{table: table} do
        assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
                 resolve(table, :string, unquote(key), "wrong", %{"num" => 123})
      end
    end

    for key <- ["starts-with-wrong-args-flag", "ends-with-wrong-args-flag"] do
      test "#{key} returns null for wrong argument count", %{table: table} do
        assert {:ok, %ResolutionDetails{value: "fallback", reason: :default}} =
                 resolve(table, :string, unquote(key), "wrong")
      end
    end
  end

  describe "metadata.feature" do
    test "returns flag metadata", %{table: table} do
      assert {:ok, %ResolutionDetails{flag_metadata: metadata}} = resolve(table, :boolean, "metadata-flag", false)
      assert metadata == %{"string" => "1.0.2", "integer" => 2, "float" => 0.1, "boolean" => true}
    end

    for {key, type, default} <- [
          {"boolean-flag", :boolean, true},
          {"integer-flag", :number, 23},
          {"float-flag", :number, 2.3},
          {"string-flag", :string, "value"}
        ] do
      test "#{key} has no metadata", %{table: table} do
        assert {:ok, %ResolutionDetails{flag_metadata: metadata}} =
                 resolve(table, unquote(type), unquote(key), unquote(default))

        assert metadata == %{}
      end
    end

    test "flag set metadata is merged underneath flag metadata" do
      json =
        ~s({"metadata": {"source": "set", "version": "1"}, "flags": {"f": {"state": "ENABLED", "variants": {"on": true}, "defaultVariant": "on", "metadata": {"version": "2", "empty": null}}}})

      {:ok, flag_set} = FlagSet.parse(json)
      table = Store.new()
      Store.put(table, flag_set, %{}, [])

      assert {:ok, %ResolutionDetails{flag_metadata: %{"source" => "set", "version" => "2"}}} =
               resolve(table, :boolean, "f", false)
    end
  end

  describe "targeting outcomes not covered by the testbed" do
    setup do
      json = """
      {"flags": {
        "unknown-variant": {"state": "ENABLED", "variants": {"one": 1}, "defaultVariant": "one", "targeting": {"if": [true, "three", "one"]}},
        "bad-operator": {"state": "ENABLED", "variants": {"one": 1}, "defaultVariant": "one", "targeting": {"invalid": ["x"]}},
        "bool-variant": {"state": "ENABLED", "variants": {"true": 1, "false": 2}, "defaultVariant": "false", "targeting": {"if": [true, true, false]}},
        "number-variant": {"state": "ENABLED", "variants": {"1": "one", "2": "two"}, "defaultVariant": "1", "targeting": {"+": [1, 1]}},
        "context-aware": {"state": "ENABLED", "variants": {"internal": "INTERNAL", "external": "EXTERNAL"}, "defaultVariant": "external", "targeting": {"if": [{"==": [{"var": "fn"}, "flagd"]}, "internal", null]}}
      }}
      """

      {:ok, flag_set} = FlagSet.parse(json)
      table = Store.new()
      Store.put(table, flag_set, %{"fn" => "flagd"}, [])
      %{table: table}
    end

    test "unknown variant is a general error", %{table: table} do
      assert {:ok, %ResolutionDetails{value: 0, reason: :error, error_code: :general}} =
               resolve(table, :number, "unknown-variant", 0)
    end

    test "unknown operator is a parse error", %{table: table} do
      assert {:ok, %ResolutionDetails{value: 0, reason: :error, error_code: :parse_error}} =
               resolve(table, :number, "bad-operator", 0)
    end

    test "boolean and numeric rule results select variants by name", %{table: table} do
      assert {:ok, %ResolutionDetails{value: 1, variant: "true", reason: :targeting_match}} =
               resolve(table, :number, "bool-variant", 0)

      assert {:ok, %ResolutionDetails{value: "two", variant: "2", reason: :targeting_match}} =
               resolve(table, :string, "number-variant", "")
    end

    test "enriched sync context is available to rules and the caller's context wins", %{table: table} do
      assert {:ok, %ResolutionDetails{value: "INTERNAL"}} = resolve(table, :string, "context-aware", "not")

      assert {:ok, %ResolutionDetails{value: "EXTERNAL"}} =
               resolve(table, :string, "context-aware", "not", %{"fn" => "other"})
    end

    test "a deleted table reports the provider as not ready instead of raising" do
      table = Store.new()
      :ets.delete(table)

      assert {:ok, %ResolutionDetails{value: "x", reason: :error, error_code: :provider_not_ready}} =
               resolve(table, :string, "anything", "x")
    end
  end
end
