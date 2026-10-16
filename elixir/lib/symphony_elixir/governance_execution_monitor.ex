defmodule SymphonyElixir.GovernanceExecutionMonitor do
  @moduledoc "Independent process reaper: stale authority or measurements cannot wait for a blocked RPC."
  use GenServer
  alias SymphonyElixir.Codex.TurnBudget
  alias SymphonyElixir.GovernanceNativeUsage
  alias SymphonyElixir.GovernanceProcess

  @type gate :: (-> :ok | {:error, term()})
  @type observer :: (map() -> :ok | {:error, term()})
  @type thread_id :: String.t() | nil

  @spec start(port(), map(), gate(), observer(), integer(), thread_id()) :: GenServer.on_start()
  def start(port, admission, validate, observe, started_ms, thread_id \\ nil) do
    GenServer.start(__MODULE__, {port, admission, validate, observe, started_ms, thread_id})
  end

  @spec inference_finished(pid()) :: :ok | {:error, atom()}
  def inference_finished(pid), do: GenServer.call(pid, :inference_finished, 1_000)

  @spec healthy?(pid()) :: :ok | {:error, atom()}
  def healthy?(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :health, 1_000), else: {:error, :governance_monitor_lost}
  catch
    :exit, _ -> {:error, :governance_monitor_lost}
  end

  @spec usage(pid(), map()) :: {:native_usage, map()}
  def usage(pid, payload), do: send(pid, {:native_usage, payload})

  @spec finish(pid()) :: {:ok, map()} | {:error, atom()}
  def finish(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :finish, 5_000), else: {:error, :governance_execution_monitor_lost}
  catch
    :exit, _ -> {:error, :governance_execution_monitor_lost}
  end

  @impl true
  @spec init({port(), map(), gate(), observer(), integer(), thread_id()}) :: {:ok, map()}
  def init({port, admission, validate, observe, started_ms, thread_id}) do
    now = System.monotonic_time(:millisecond)
    {:ok, deadline, _} = DateTime.from_iso8601(admission["deadline"])
    remaining = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)

    state = %{
      port: port,
      validate: validate,
      observe: observe,
      started: started_ms,
      valid_at: now,
      metric_at: now,
      has_metrics: false,
      deadline: now + min(remaining, admission["reservedDurationSeconds"] * 1000),
      tokens: admission["reservedUncachedInputTokens"],
      budget: TurnBudget.new("task-orchestrator", %{}),
      native_usage: registered_usage(thread_id, port),
      in_flight: nil,
      failed: nil,
      sequence: 1,
      inference_finished: false,
      published_at: now
    }

    Process.send_after(self(), :tick, 100)
    {:ok, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({:native_usage, payload}, state) do
    next =
      case GovernanceNativeUsage.observe(state.native_usage, payload) do
        {:ok, usage} -> apply_usage(state, usage)
        {:ignored, _} -> state
        {:error, _} -> fail(state, :governance_execution_measurement_invalid)
      end

    {:noreply, next}
  end

  def handle_info({:validation, ref, result}, %{in_flight: ref} = state) do
    next =
      if result == :ok,
        do: %{state | valid_at: System.monotonic_time(:millisecond)},
        else: fail(state, :governance_execution_authority_lost)

    {:noreply, %{next | in_flight: nil}}
  end

  def handle_info({:validation, _, _}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    next = state |> refresh_completed_inference(now) |> check_limits(now) |> start_validation(now)
    Process.send_after(self(), :tick, 1000)
    {:noreply, next}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()} | {:stop, :normal, term(), map()}
  def handle_call(:health, _from, state),
    do: {:reply, if(state.failed == nil, do: :ok, else: {:error, state.failed}), state}

  def handle_call(:inference_finished, _from, %{has_metrics: true} = state),
    do: {:reply, :ok, %{state | inference_finished: true}}

  def handle_call(:inference_finished, _from, state),
    do: {:reply, {:error, :governance_execution_measurement_missing}, state}

  def handle_call(:finish, _from, state) do
    GovernanceProcess.stop(state.port)

    result =
      if state.has_metrics,
        do: {:ok, Map.put(metrics(state, System.monotonic_time(:millisecond)), :cancelled, state.failed != nil)},
        else: {:error, :governance_execution_measurement_missing}

    {:stop, :normal, result, state}
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(reason, state) do
    if reason != :normal, do: GovernanceProcess.stop(state.port)
    :ok
  end

  defp apply_usage(state, usage) do
    case GovernanceNativeUsage.snapshot(usage) do
      {:ok, total} ->
        budget =
          TurnBudget.observe(state.budget, %{
            "usage" => %{"inputTokens" => total.inputTokens, "cachedInputTokens" => total.cachedInputTokens}
          })

        %{
          state
          | native_usage: usage,
            budget: %{budget | uncached_input_tokens: total.uncachedInputTokens},
            metric_at: System.monotonic_time(:millisecond),
            has_metrics: true
        }

      _ ->
        fail(state, :governance_execution_measurement_missing)
    end
  end

  defp refresh_completed_inference(%{inference_finished: true, has_metrics: true} = state, now),
    do: %{state | metric_at: now}

  defp refresh_completed_inference(state, _now), do: state

  defp check_limits(state, now) do
    cond do
      state.failed != nil -> state
      now >= state.deadline -> fail(state, :governance_execution_deadline)
      state.budget.uncached_input_tokens >= state.tokens -> fail(state, :governance_execution_token_ceiling)
      now - state.valid_at > 3000 -> fail(state, :governance_execution_authority_stale)
      now - state.metric_at > 30_000 -> fail(state, :governance_execution_measurement_stale)
      true -> state
    end
  end

  defp start_validation(%{failed: nil, in_flight: nil} = state, now) do
    owner = self()
    ref = make_ref()
    publish = publish_measurement?(state, now)
    measurement = metrics(state, now)

    spawn(fn ->
      result = validate_and_observe(state.validate, state.observe, measurement, publish)
      send(owner, {:validation, ref, result})
    end)

    state |> Map.put(:in_flight, ref) |> Map.put(:sequence, state.sequence + 1) |> published(publish, now)
  end

  defp start_validation(state, _now), do: state

  defp publish_measurement?(state, now) do
    state.has_metrics and
      (now - state.published_at >= 10_000 or state.budget.uncached_input_tokens > Map.get(state, :published_tokens, -1))
  end

  defp validate_and_observe(validate, observe, measurement, publish) do
    with :ok <- validate.() do
      if publish, do: observe.(measurement), else: :ok
    end
  rescue
    _ -> {:error, :validation_failed}
  catch
    _, _ -> {:error, :validation_failed}
  end

  defp published(state, true, now),
    do: state |> Map.put(:published_at, now) |> Map.put(:published_tokens, state.budget.uncached_input_tokens)

  defp published(state, false, _now), do: state

  defp metrics(state, now) do
    %{
      sequence: state.sequence + 1,
      uncachedInputTokens: if(state.has_metrics, do: state.budget.uncached_input_tokens, else: nil),
      wallTimeSeconds: div(max(now - state.started, 0), 1000),
      observedAt: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp fail(%{failed: nil} = state, reason) do
    GovernanceProcess.stop(state.port)
    %{state | failed: reason}
  end

  defp fail(state, _), do: state

  defp registered_usage(thread_id, port) do
    case GovernanceNativeUsage.register(GovernanceNativeUsage.new(), thread_id, %{port: inspect(port)}) do
      {:ok, state} -> state
      _ -> GovernanceNativeUsage.new()
    end
  end
end
