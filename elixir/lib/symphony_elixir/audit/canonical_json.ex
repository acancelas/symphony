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
      |> Enum.sort_by(fn {key, _item} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode!(key), ?:, encode(item)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  def encode(value) when is_list(value),
    do: [?[, Enum.intersperse(Enum.map(value, &encode/1), ?,), ?]]

  def encode(value) when is_binary(value), do: Jason.encode!(value)
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(nil), do: "null"

  def encode(value) when is_float(value) do
    raise ArgumentError, "floating point values are forbidden in BOS audit payloads: #{inspect(value)}"
  end
end
