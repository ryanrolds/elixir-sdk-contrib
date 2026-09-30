defmodule OpenFeature.Provider.Flagd.InProcess.FlagSetTest do
  use ExUnit.Case, async: true

  alias OpenFeature.Provider.Flagd.InProcess.FlagSet
  alias OpenFeature.Provider.Flagd.InProcess.FlagSet.Flag

  test "parses flags, evaluators and metadata" do
    json = """
    {
      "metadata": {"flagSetId": "x"},
      "$evaluators": {"admin": {"==": [{"var": "role"}, "admin"]}},
      "flags": {
        "f": {"variants": {"on": true, "off": false}, "defaultVariant": "off",
              "targeting": {"if": [{"$ref": "admin"}, "on", {"$ref": "unknown"}]}}
      }
    }
    """

    assert {:ok, %FlagSet{metadata: %{"flagSetId" => "x"}, flags: %{"f" => flag}}} = FlagSet.parse(json)

    assert flag == %Flag{
             state: "ENABLED",
             variants: %{"on" => true, "off" => false},
             default_variant: "off",
             targeting: %{"if" => [%{"==" => [%{"var" => "role"}, "admin"]}, "on", %{"$ref" => "unknown"}]},
             metadata: %{}
           }
  end

  test "accepts the array form with embedded keys" do
    json = ~s({"flags": [{"key": "a", "variants": {"x": 1}, "defaultVariant": "x"}]})
    assert {:ok, %FlagSet{flags: %{"a" => %Flag{default_variant: "x"}}}} = FlagSet.parse(json)
  end

  test "rejects malformed documents" do
    assert {:error, {:invalid_json, _}} = FlagSet.parse("{")
    assert {:error, :invalid_document} = FlagSet.parse("[]")
    assert {:error, {:invalid_field, "flags"}} = FlagSet.parse(~s({"flags": 1}))
    assert {:error, {:invalid_field, "flags"}} = FlagSet.parse(~s({"flags": [{"variants": {}}]}))
    assert {:error, {:invalid_field, "$evaluators"}} = FlagSet.parse(~s({"flags": {}, "$evaluators": []}))

    assert {:error, {:invalid_flag, "f", _}} =
             FlagSet.parse(~s({"flags": {"f": {"variants": {"a": 1}, "defaultVariant": "b"}}}))

    assert {:error, {:invalid_flag, "f", _}} = FlagSet.parse(~s({"flags": {"f": {"variants": []}}}))
    assert {:error, {:invalid_flag, "f", _}} = FlagSet.parse(~s({"flags": {"f": {"variants": {}, "targeting": 1}}}))
    assert {:error, {:invalid_flag, "f", _}} = FlagSet.parse(~s({"flags": {"f": "nope"}}))
  end

  test "changed_keys lists added, removed and modified flags" do
    old = %{"a" => %Flag{}, "b" => %Flag{}, "c" => %Flag{}}
    new = %{"a" => %Flag{}, "b" => %Flag{state: "DISABLED"}, "d" => %Flag{}}

    assert FlagSet.changed_keys(old, new) == ["b", "c", "d"]
    assert FlagSet.changed_keys(old, old) == []
  end
end
