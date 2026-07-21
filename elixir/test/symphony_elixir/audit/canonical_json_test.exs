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

  test "uses lowercase RFC 8785 escapes for control characters" do
    canonical = %{"output" => <<27, 0, 31, 8, 9, 10, 12, 13>>} |> CanonicalJson.encode() |> IO.iodata_to_binary()

    assert canonical == ~S({"output":"\u001b\u0000\u001f\b\t\n\f\r"})
  end

  test "sorts object properties by UTF-16 code units" do
    canonical = %{<<0xE000::utf8>> => 1, "😀" => 2} |> CanonicalJson.encode() |> IO.iodata_to_binary()
    assert canonical == ~s({"😀":2,"":1})
  end

  test "rejects invalid UTF-8 strings" do
    assert_raise ArgumentError, fn -> CanonicalJson.encode(%{"value" => <<255>>}) end
  end
end
