defmodule SymphonyElixir.GameApi.RateLimit do
  @moduledoc """
  Process-wide circuit breaker for `game-api` rate limiting.

  A single upstream `429` stops every Symphony caller, including tracker
  polling, heartbeats, and audit outbox draining. The deadline is held in
  `persistent_term` so independent OTP processes share the same circuit.
  """

  @key {__MODULE__, :blocked_until_ms}
  @default_retry_ms 120_000
  @max_jitter_ms 5_000

  @spec check() :: :ok | {:error, {:game_api_rate_limited, pos_integer()}}
  def check do
    case blocked_until_ms() do
      nil ->
        :ok

      deadline ->
        remaining = deadline - monotonic_ms()

        if remaining > 0 do
          {:error, {:game_api_rate_limited, remaining}}
        else
          :ok
        end
    end
  end

  @spec block(Req.Response.t()) :: pos_integer()
  def block(%Req.Response{} = response) do
    retry_ms = retry_after_ms(response) + jitter_ms()
    deadline = monotonic_ms() + retry_ms
    current = blocked_until_ms() || deadline
    :persistent_term.put(@key, max(current, deadline))
    max((blocked_until_ms() || deadline) - monotonic_ms(), 1)
  end

  @doc false
  @spec block_for(pos_integer()) :: pos_integer()
  def block_for(retry_ms) when is_integer(retry_ms) and retry_ms > 0 do
    deadline = monotonic_ms() + retry_ms
    current = blocked_until_ms() || deadline
    :persistent_term.put(@key, max(current, deadline))
    max((blocked_until_ms() || deadline) - monotonic_ms(), 1)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp retry_after_ms(response) do
    retry_after_seconds(response) || reset_deadline_ms(response) || @default_retry_ms
  end

  defp retry_after_seconds(response) do
    response
    |> header("retry-after")
    |> parse_positive_integer()
    |> case do
      nil -> nil
      seconds -> seconds * 1_000
    end
  end

  defp reset_deadline_ms(response) do
    response
    |> header("x-ratelimit-reset")
    |> parse_positive_integer()
    |> case do
      nil -> nil
      epoch_seconds -> max(epoch_seconds * 1_000 - System.system_time(:millisecond), 1_000)
    end
  end

  defp header(%Req.Response{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp blocked_until_ms, do: :persistent_term.get(@key, nil)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp jitter_ms, do: :rand.uniform(@max_jitter_ms + 1) - 1
end
