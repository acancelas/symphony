defmodule SymphonyElixir.Audit.CanonicalJson do
  @moduledoc """
  RFC 8785 compatible JSON canonicalization for BOS audit values.

  Audit payloads intentionally prohibit floating point values. This keeps
  cross-runtime numeric representation deterministic while supporting every
  value emitted by the orchestrator.
  """

  @spec encode(term()) :: iodata()
  def encode(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(fn {key, _item} -> utf16_sort_key(key) end)
      |> Enum.map(fn {key, item} -> [encode_string(key), ?:, encode(item)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  def encode(value) when is_list(value),
    do: [?[, Enum.intersperse(Enum.map(value, &encode/1), ?,), ?]]

  def encode(value) when is_binary(value), do: encode_string(value)
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(nil), do: "null"

  def encode(value) when is_float(value) do
    raise ArgumentError, "floating point values are forbidden in BOS audit payloads: #{inspect(value)}"
  end

  defp encode_string(value) do
    unless String.valid?(value) do
      raise ArgumentError, "BOS audit strings must be valid UTF-8"
    end

    escaped =
      for <<codepoint::utf8 <- value>> do
        escape_codepoint(codepoint)
      end

    [?", escaped, ?"]
  end

  defp escape_codepoint(?"), do: ~S(\")
  defp escape_codepoint(?\\), do: ~S(\\)
  defp escape_codepoint(0x08), do: ~S(\b)
  defp escape_codepoint(0x09), do: ~S(\t)
  defp escape_codepoint(0x0A), do: ~S(\n)
  defp escape_codepoint(0x0C), do: ~S(\f)
  defp escape_codepoint(0x0D), do: ~S(\r)

  defp escape_codepoint(codepoint) when codepoint <= 0x1F do
    "\\u" <> (codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp escape_codepoint(codepoint), do: <<codepoint::utf8>>

  defp utf16_sort_key(value) do
    case :unicode.characters_to_binary(value, :utf8, {:utf16, :big}) do
      encoded when is_binary(encoded) -> encoded
      _invalid -> raise ArgumentError, "BOS audit object keys must be valid UTF-8"
    end
  end
end
