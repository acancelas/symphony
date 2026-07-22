defmodule SymphonyElixir.GameApi.ProviderCircuit do
  @moduledoc """
  Process-wide circuit breaker for the shared `game-api`/GitHub provider budget.

  A rate limit belongs to the provider, not to an Issue or AgentRun. Keeping the
  gate here prevents independent scheduler and audit workers from rotating
  through work while the same upstream quota is exhausted.
  """

  @state_key {__MODULE__, :state}
  @lock_key {__MODULE__, :lock}
  @initial_backoff_ms 60_000
  @maximum_backoff_ms 900_000
  @maximum_provider_retry_ms 86_400_000
  @maximum_jitter_ms 30_000

  @spec before_request() :: :ok | {:error, {:game_api_rate_limited, non_neg_integer()}}
  def before_request do
    locked(fn ->
      now = monotonic_ms()

      case :persistent_term.get(@state_key, nil) do
        nil ->
          :ok

        %{half_open: true} ->
          {:error, {:game_api_rate_limited, 1_000}}

        %{due_at_ms: due_at_ms} = state when now >= due_at_ms ->
          :persistent_term.put(@state_key, %{state | half_open: true})
          :ok

        %{due_at_ms: due_at_ms} ->
          {:error, {:game_api_rate_limited, max(due_at_ms - now, 0)}}
      end
    end)
  end

  @spec rate_limited(non_neg_integer() | nil) :: non_neg_integer()
  def rate_limited(provider_retry_ms \\ nil) do
    rate_limited_with_jitter(provider_retry_ms, &random_jitter_ms/1)
  end

  @doc false
  @spec rate_limited_for_test(non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer()
  def rate_limited_for_test(provider_retry_ms, jitter_ms) when is_integer(jitter_ms) and jitter_ms >= 0 do
    rate_limited_with_jitter(provider_retry_ms, fn jitter_window_ms ->
      min(jitter_ms, jitter_window_ms)
    end)
  end

  defp rate_limited_with_jitter(provider_retry_ms, jitter_fun) do
    locked(fn ->
      now = monotonic_ms()
      state = :persistent_term.get(@state_key, nil)

      if state && state.due_at_ms > now && !state.half_open do
        state.due_at_ms - now
      else
        attempt = (state && state.attempt) || 0
        next_attempt = attempt + 1
        base_delay_ms = max(backoff_ms(next_attempt), bounded_provider_delay(provider_retry_ms))
        delay_ms = base_delay_ms + jitter_fun.(jitter_window_ms(base_delay_ms))

        :persistent_term.put(@state_key, %{
          attempt: next_attempt,
          due_at_ms: now + delay_ms,
          half_open: false
        })

        delay_ms
      end
    end)
  end

  @spec succeeded() :: :ok
  def succeeded do
    locked(fn ->
      case :persistent_term.get(@state_key, nil) do
        %{half_open: true} -> :persistent_term.erase(@state_key)
        _state -> :ok
      end

      :ok
    end)
  end

  @doc """
  Reopens the circuit after a multi-repository read recovered a non-empty,
  last-confirmed queue before a later repository failed.

  The caller must only use this narrow escape hatch to let atomic operations on
  those already confirmed Issues probe their own provider path.
  """
  @spec allow_confirmed_partial_progress() :: :ok
  def allow_confirmed_partial_progress do
    locked(fn ->
      :persistent_term.erase(@state_key)
      :ok
    end)
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    locked(fn ->
      :persistent_term.erase(@state_key)
      :ok
    end)
  end

  @doc false
  @spec state_for_test() :: map() | nil
  def state_for_test, do: :persistent_term.get(@state_key, nil)

  @doc false
  @spec expire_for_test() :: :ok
  def expire_for_test do
    locked(fn ->
      state = :persistent_term.get(@state_key)
      :persistent_term.put(@state_key, %{state | due_at_ms: monotonic_ms() - 1})
      :ok
    end)
  end

  defp backoff_ms(attempt) do
    exponent = min(max(attempt - 1, 0), 20)
    min(@initial_backoff_ms * Integer.pow(2, exponent), @maximum_backoff_ms)
  end

  defp bounded_provider_delay(delay_ms) when is_integer(delay_ms) and delay_ms > 0,
    do: min(delay_ms, @maximum_provider_retry_ms)

  defp bounded_provider_delay(_delay_ms), do: 0

  defp jitter_window_ms(delay_ms), do: min(max(div(delay_ms, 10), 1), @maximum_jitter_ms)
  defp random_jitter_ms(jitter_window_ms), do: :rand.uniform(jitter_window_ms)

  defp locked(fun), do: :global.trans(@lock_key, fun)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
