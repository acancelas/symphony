defmodule SymphonyElixir.Codex.TurnBudget do
  @moduledoc """
  Pure state machine for bounded Codex turns.

  Token usage reported by app-server is cumulative within a turn. The budget
  therefore tracks the latest absolute counters and budgets only uncached input
  (`input - cached_input`), while retaining cached usage for observability.
  """

  @type limit :: pos_integer() | nil
  @type t :: %{
          role: String.t(),
          started_at_ms: integer(),
          soft_wall_clock_ms: limit(),
          hard_wall_clock_ms: limit(),
          soft_uncached_input_tokens: limit(),
          hard_uncached_input_tokens: limit(),
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          uncached_input_tokens: non_neg_integer(),
          soft_triggered: boolean(),
          hard_triggered: boolean(),
          pause_reason: atom() | nil
        }

  @spec new(String.t(), map(), integer()) :: t()
  def new(role, limits, now_ms \\ System.monotonic_time(:millisecond)) do
    %{
      role: role,
      started_at_ms: now_ms,
      soft_wall_clock_ms: value(limits, "soft_wall_clock_ms"),
      hard_wall_clock_ms: value(limits, "hard_wall_clock_ms"),
      soft_uncached_input_tokens: value(limits, "soft_uncached_input_tokens"),
      hard_uncached_input_tokens: value(limits, "hard_uncached_input_tokens"),
      input_tokens: 0,
      cached_input_tokens: 0,
      uncached_input_tokens: 0,
      soft_triggered: false,
      hard_triggered: false,
      pause_reason: nil
    }
  end

  @spec observe(t(), map()) :: t()
  def observe(state, payload) do
    case find_usage(payload) do
      nil ->
        state

      usage ->
        input = token(usage, ["input_tokens", "inputTokens", "prompt_tokens"])
        cached = token(usage, ["cached_input_tokens", "cachedInputTokens"])

        %{
          state
          | input_tokens: max(state.input_tokens, input),
            cached_input_tokens: max(state.cached_input_tokens, cached),
            uncached_input_tokens: max(state.uncached_input_tokens, max(input - cached, 0))
        }
    end
  end

  @spec actions(t(), integer()) :: {[atom()], t()}
  def actions(state, now_ms \\ System.monotonic_time(:millisecond)) do
    elapsed = max(now_ms - state.started_at_ms, 0)

    hard_reason =
      limit_reason(
        elapsed,
        state.hard_wall_clock_ms,
        state.uncached_input_tokens,
        state.hard_uncached_input_tokens,
        :hard_wall_clock,
        :hard_uncached_input
      )

    soft_reason =
      limit_reason(
        elapsed,
        state.soft_wall_clock_ms,
        state.uncached_input_tokens,
        state.soft_uncached_input_tokens,
        :soft_wall_clock,
        :soft_uncached_input
      )

    transition(state, hard_reason, soft_reason)
  end

  @spec snapshot(t(), integer()) :: map()
  def snapshot(state, now_ms \\ System.monotonic_time(:millisecond)) do
    Map.take(state, [
      :role,
      :input_tokens,
      :cached_input_tokens,
      :uncached_input_tokens,
      :soft_triggered,
      :hard_triggered,
      :pause_reason
    ])
    |> Map.put(:elapsed_ms, max(now_ms - state.started_at_ms, 0))
  end

  defp exceeded?(_actual, nil), do: false
  defp exceeded?(actual, limit), do: actual >= limit

  defp limit_reason(elapsed, wall_limit, uncached, token_limit, wall_reason, token_reason) do
    cond do
      exceeded?(elapsed, wall_limit) -> wall_reason
      exceeded?(uncached, token_limit) -> token_reason
      true -> nil
    end
  end

  defp transition(%{hard_triggered: true} = state, _hard_reason, _soft_reason), do: {[], state}

  defp transition(state, hard_reason, _soft_reason) when not is_nil(hard_reason) do
    actions = if state.soft_triggered, do: [:interrupt], else: [:checkpoint, :interrupt]
    {actions, %{state | soft_triggered: true, hard_triggered: true, pause_reason: hard_reason}}
  end

  defp transition(%{soft_triggered: false} = state, nil, soft_reason)
       when not is_nil(soft_reason) do
    {[:checkpoint], %{state | soft_triggered: true, pause_reason: soft_reason}}
  end

  defp transition(state, _hard_reason, _soft_reason), do: {[], state}

  defp value(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]

  defp find_usage(payload) when is_map(payload) do
    preferred_usage(payload) ||
      if usage_map?(payload) do
        payload
      else
        payload
        |> Map.values()
        |> Enum.find_value(&find_usage/1)
      end
  end

  defp find_usage(payload) when is_list(payload), do: Enum.find_value(payload, &find_usage/1)
  defp find_usage(_payload), do: nil

  defp usage_map?(map) do
    Enum.any?(["input_tokens", "inputTokens", "prompt_tokens"], fn key ->
      is_integer(map[key])
    end)
  end

  defp preferred_usage(payload) do
    paths = [
      ["params", "tokenUsage", "total"],
      ["params", "msg", "payload", "info", "total_token_usage"],
      ["params", "msg", "info", "total_token_usage"],
      ["usage"]
    ]

    Enum.find_value(paths, fn path ->
      value = get_in(payload, path)
      if is_map(value) and usage_map?(value), do: value
    end)
  end

  defp token(map, keys), do: Enum.find_value(keys, 0, fn key -> if is_integer(map[key]), do: map[key] end)
end
