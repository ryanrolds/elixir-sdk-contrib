defmodule OpenFeature.Provider.Flagd.InProcess.JsonLogicTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias OpenFeature.Provider.Flagd.InProcess.Fractional
  alias OpenFeature.Provider.Flagd.InProcess.JsonLogic
  alias OpenFeature.Provider.Flagd.InProcess.SemVer

  defp apply!(rule, data \\ %{}) do
    {:ok, result} = JsonLogic.evaluate(rule, data)
    result
  end

  test "var reads dotted paths, array indexes and defaults" do
    data = %{"user" => %{"name" => "jo", "tags" => ["a", "b"]}}

    assert apply!(%{"var" => "user.name"}, data) == "jo"
    assert apply!(%{"var" => "user.tags.1"}, data) == "b"
    assert apply!(%{"var" => ["user.age", 30]}, data) == 30
    assert apply!(%{"var" => "missing"}, data) == nil
    assert apply!(%{"var" => ""}, data) == data
    assert apply!(%{"var" => 1}, ["x", "y"]) == "y"
  end

  test "missing and missing_some" do
    data = %{"a" => 1, "b" => nil}

    assert apply!(%{"missing" => ["a", "b", "c"]}, data) == ["b", "c"]
    assert apply!(%{"missing" => "a"}, data) == []
    assert apply!(%{"missing_some" => [1, ["a", "c"]]}, data) == []
    assert apply!(%{"missing_some" => [2, ["a", "c"]]}, data) == ["c"]
  end

  test "if evaluates chains and truthiness" do
    assert apply!(%{"if" => [true, "a", "b"]}) == "a"
    assert apply!(%{"if" => [false, "a", 0, "b", "c"]}) == "c"
    assert apply!(%{"if" => [[], "a"]}) == nil
    assert apply!(%{"if" => [%{}, "a", "b"]}) == "b"
    assert apply!(%{"if" => ["", "a", "b"]}) == "b"
    assert apply!(%{"if" => ["0", "a", "b"]}) == "a"
  end

  test "equality operators" do
    assert apply!(%{"==" => [1, "1"]})
    assert apply!(%{"==" => [1, 1.0]})
    assert apply!(%{"==" => [nil, nil]})
    refute apply!(%{"==" => [nil, false]})
    assert apply!(%{"==" => [true, 1]})
    refute apply!(%{"===" => [1, "1"]})
    assert apply!(%{"!=" => [1, 2]})
    assert apply!(%{"!==" => [1, "1"]})
    assert apply!(%{"!" => [0]})
    assert apply!(%{"!!" => ["x"]})
  end

  test "and and or return the deciding value" do
    assert apply!(%{"and" => [1, "yes"]}) == "yes"
    assert apply!(%{"and" => [1, 0, "yes"]}) == 0
    assert apply!(%{"or" => [0, "yes", 3]}) == "yes"
    assert apply!(%{"or" => [0, ""]}) == ""
  end

  test "comparisons coerce numeric strings and support between" do
    assert apply!(%{"<" => [1, 2, 3]})
    refute apply!(%{"<" => [1, 3, 2]})
    assert apply!(%{"<=" => ["2", 2]})
    assert apply!(%{">" => ["b", "a"]})
    refute apply!(%{">" => [%{}, 1]})
    assert apply!(%{">=" => [true, 1]})
  end

  test "arithmetic" do
    assert apply!(%{"+" => [1, "2", 3.5]}) == 6.5
    assert apply!(%{"-" => [5]}) == -5
    assert apply!(%{"-" => [5, 2]}) == 3
    assert apply!(%{"*" => [2, 3]}) == 6
    assert apply!(%{"/" => [6, 3]}) == 2
    assert apply!(%{"/" => [7, 2]}) == 3.5
    assert apply!(%{"%" => [7, 3]}) == 1
    assert apply!(%{"max" => [1, 9, 3]}) == 9
    assert apply!(%{"min" => [4, 2]}) == 2
  end

  test "strings and arrays" do
    assert apply!(%{"cat" => ["a", 1, 2.5, nil, true]}) == "a12.5true"
    assert apply!(%{"substr" => ["jsonlogic", 4]}) == "logic"
    assert apply!(%{"substr" => ["jsonlogic", -5]}) == "logic"
    assert apply!(%{"substr" => ["jsonlogic", 1, 3]}) == "son"
    assert apply!(%{"substr" => ["jsonlogic", 4, -2]}) == "log"
    assert apply!(%{"in" => ["x", "xyz"]})
    assert apply!(%{"in" => [2, [1, 2]]})
    refute apply!(%{"in" => [2, nil]})
    assert apply!(%{"merge" => [[1, 2], 3, [4]]}) == [1, 2, 3, 4]
  end

  test "array operators" do
    data = %{"n" => [1, 2, 3]}

    assert apply!(%{"map" => [%{"var" => "n"}, %{"*" => [%{"var" => ""}, 2]}]}, data) == [2, 4, 6]
    assert apply!(%{"filter" => [%{"var" => "n"}, %{">" => [%{"var" => ""}, 1]}]}, data) == [2, 3]

    assert apply!(
             %{"reduce" => [%{"var" => "n"}, %{"+" => [%{"var" => "current"}, %{"var" => "accumulator"}]}, 0]},
             data
           ) == 6

    assert apply!(%{"all" => [%{"var" => "n"}, %{">" => [%{"var" => ""}, 0]}]}, data)
    refute apply!(%{"all" => [[], true]})
    assert apply!(%{"some" => [%{"var" => "n"}, %{"==" => [%{"var" => ""}, 2]}]}, data)
    assert apply!(%{"none" => [%{"var" => "n"}, %{"==" => [%{"var" => ""}, 9]}]}, data)
  end

  test "unknown operators and bad arguments are errors, literals pass through" do
    assert {:error, %JsonLogic.Error{}} = JsonLogic.evaluate(%{"nope" => [1]}, %{})
    assert {:error, %JsonLogic.Error{}} = JsonLogic.evaluate(%{"==" => [1]}, %{})
    assert {:error, %JsonLogic.Error{}} = JsonLogic.evaluate(%{"+" => [%{}]}, %{})
    assert apply!("literal") == "literal"
    assert apply!([1, %{"var" => "a"}], %{"a" => 2}) == [1, 2]
    assert apply!(%{"a" => 1, "b" => 2}) == %{"a" => 1, "b" => 2}
  end

  test "to_text renders results the way flagd matches variants" do
    assert JsonLogic.to_text(true) == "true"
    assert JsonLogic.to_text(1) == "1"
    assert JsonLogic.to_text(1.0) == "1"
    assert JsonLogic.to_text(1.5) == "1.5"
    assert JsonLogic.to_text("s") == "s"
    assert JsonLogic.to_text(nil) == ""
  end

  test "murmur3 x86 32 with seed 0 matches the reference vectors" do
    assert Fractional.murmur3_32("") == 0
    assert Fractional.murmur3_32("hello") == 0x248BFA47
    assert Fractional.murmur3_32("The quick brown fox jumps over the lazy dog") == 776_992_547
  end

  test "fractional validates its distributions" do
    data = %{"targetingKey" => "k", "$flagd" => %{"flagKey" => "f"}}

    assert Fractional.evaluate([["a", 1.5]], data) == nil
    assert Fractional.evaluate([["a", "x"]], data) == nil
    assert Fractional.evaluate([["a", 2_147_483_648]], data) == nil
    assert Fractional.evaluate([["a", 2_000_000_000], ["b", 2_000_000_000]], data) == nil
    assert Fractional.evaluate([[%{"nested" => true}, 1]], data) == nil
    assert Fractional.evaluate(["not-a-distribution"], data) == nil
    assert Fractional.evaluate([["a", nil]], data) == "a"
    assert Fractional.evaluate([["a"]], %{"$flagd" => %{"flagKey" => "f"}}) == nil
    assert Fractional.evaluate([["a"]], Map.put(data, "targetingKey", 5)) == nil
    assert Fractional.evaluate([["only"]], %{}) == nil
  end

  test "sem_ver parses loosely and compares strictly" do
    assert SemVer.evaluate(["1.2.3", "=", "v1.2.3"])
    assert SemVer.evaluate(["1.2.3-beta", "<", "1.2.3"])
    assert SemVer.evaluate(["1.2.3-alpha.1", "<", "1.2.3-alpha.2"])
    assert SemVer.evaluate(["1.2.3+1", "=", "1.2.3+2"])
    assert SemVer.evaluate(["1.0.0-rc.1+build.5", "<", "1.0.0"])
    assert SemVer.parse("1.2.3.4") == :error
    assert SemVer.parse("1.2.3-") == :error
    assert SemVer.evaluate(["1.2", "~", "1.2.9"])
    refute SemVer.evaluate(["1.3.0", "~", "1.2.9"])
    assert SemVer.evaluate(["1.9.0", "^", "1.0.0"])
    assert SemVer.evaluate(["2.0.0", "!=", "1.0.0"])
    assert SemVer.evaluate(["2.0.0", ">=", "2.0.0"])
    assert SemVer.evaluate(["2.0.0", "<=", "2.0.0"])
    assert SemVer.evaluate([2, ">", 1.5])
    assert SemVer.evaluate(["1.0.0", "??", "1.0.0"]) == nil
    assert SemVer.evaluate(["1.0.0", "="]) == nil
    assert SemVer.evaluate([nil, "=", "1.0.0"]) == nil
    assert SemVer.evaluate(["1.0.0", "=", "one"]) == nil
  end
end
