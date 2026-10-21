defmodule SymphonyElixir.GovernanceNativeUsage do
  @moduledoc "Host-registered native threads only. Unknown measurements are never zero; cumulative watermarks cannot refund usage."

  @spec new() :: map()
  def new, do: %{}

  @spec register(map(), String.t() | nil, map()) :: {:ok, map()} | {:error, atom()}
  def register(state, thread, witness)
      when is_binary(thread) and byte_size(thread) > 0 and byte_size(thread) <= 200 and is_map(witness) and
             map_size(witness) > 0 do
    case state[thread] do
      nil -> {:ok, Map.put(state, thread, %{witness: witness, known: false, input: nil, cached: nil, uncached: nil})}
      %{witness: ^witness} -> {:ok, state}
      _ -> {:error, :native_thread_identity_changed}
    end
  end

  def register(_, _, _), do: {:error, :native_thread_identity_missing}

  @spec observe(map(), term()) :: {:ok, map()} | {:ignored, map()} | {:error, atom()}
  def observe(state, %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{"threadId" => thread, "turnId" => turn, "tokenUsage" => %{"total" => total}}
      })
      when is_map(total) and is_binary(turn) and byte_size(turn) > 0 do
    with %{known: known, input: before_input, cached: before_cached} = old <- state[thread],
         input when is_integer(input) and input >= 0 <- total["inputTokens"],
         cached when is_integer(cached) and cached >= 0 and cached <= input <- total["cachedInputTokens"],
         true <- not known or (input >= before_input and cached >= before_cached) do
      uncached = max(if(known, do: old.uncached, else: 0), input - cached)
      {:ok, Map.put(state, thread, %{old | known: true, input: input, cached: cached, uncached: uncached})}
    else
      _ -> {:error, :native_usage_unbound_or_regressed}
    end
  end

  def observe(_state, %{"method" => "thread/tokenUsage/updated"}), do: {:error, :native_usage_invalid_protocol}
  def observe(state, _), do: {:ignored, state}

  @spec snapshot(map()) ::
          {:ok,
           %{
             inputTokens: non_neg_integer(),
             cachedInputTokens: non_neg_integer(),
             uncachedInputTokens: non_neg_integer(),
             threads: pos_integer()
           }}
          | {:error, atom()}
  def snapshot(state) do
    if map_size(state) > 0 and Enum.all?(state, fn {_, v} -> v.known end) do
      {:ok,
       Enum.reduce(
         state,
         %{inputTokens: 0, cachedInputTokens: 0, uncachedInputTokens: 0, threads: map_size(state)},
         fn {_, v}, sum ->
           %{
             sum
             | inputTokens: sum.inputTokens + v.input,
               cachedInputTokens: sum.cachedInputTokens + v.cached,
               uncachedInputTokens: sum.uncachedInputTokens + v.uncached
           }
         end
       )}
    else
      {:error, :native_usage_measurement_missing}
    end
  end
end
