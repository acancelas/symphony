defmodule SymphonyElixir.Audit.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Audit.CanonicalJson

  test "sorts object keys recursively and preserves array order" do
    value = %{"z" => [3, 2, 1], "a" => %{"b" => true, "a" => nil}}
    assert IO.iodata_to_binary(CanonicalJson.encode(value)) == ~s({"a":{"a":null,"b":true},"z":[3,2,1]})
  end

  test "matches the cross-runtime RFC 8785 and SHA-256 fixture" do
    value = %{
      "z" => [3, 2, 1],
      "occurredAt" => "2026-07-19T18:42:15.438Z",
      "a" => %{"b" => true, "a" => nil}
    }

    canonical = value |> CanonicalJson.encode() |> IO.iodata_to_binary()

    assert canonical ==
             ~s({"a":{"a":null,"b":true},"occurredAt":"2026-07-19T18:42:15.438Z","z":[3,2,1]})

    assert Base.encode16(:crypto.hash(:sha256, canonical), case: :lower) ==
             "0fe4d5a111d188b2d2bc833a3fca93ee27617b91cec3eb71d843beeb8b9c88ff"
  end

  test "rejects floating point audit values" do
    assert_raise ArgumentError, fn -> CanonicalJson.encode(%{"value" => 1.5}) end
  end

  test "uses RFC 8785 lowercase hexadecimal escapes for ANSI control bytes" do
    value = %{"outputSummary" => "\e[0;32mpassed\e[0m"}
    canonical = value |> CanonicalJson.encode() |> IO.iodata_to_binary()

    assert canonical == ~S({"outputSummary":"\u001b[0;32mpassed\u001b[0m"})

    assert Base.encode16(:crypto.hash(:sha256, canonical), case: :lower) ==
             "09fe4ade10659bdf95036a8ccab87866e39ec58c8d00e628d3a6ecadf2e67d8e"
  end
end
