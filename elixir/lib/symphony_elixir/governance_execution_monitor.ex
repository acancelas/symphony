defmodule SymphonyElixir.GovernanceExecutionMonitor do
  @moduledoc "Independent process reaper: stale authority or measurements cannot wait for a blocked RPC."
  use GenServer
  alias SymphonyElixir.Codex.TurnBudget

  def start(port, admission, validate, observe, started_ms) do
    GenServer.start(__MODULE__, {port, admission, validate, observe, started_ms})
  end

  def inference_finished(pid), do: GenServer.call(pid, :inference_finished, 1_000)

  def healthy?(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :health, 1_000), else: {:error, :governance_monitor_lost}
  catch
    :exit, _ -> {:error, :governance_monitor_lost}
  end

  def usage(pid, payload), do: send(pid, {:native_usage, payload})

  def finish(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :finish, 5_000), else: {:error, :governance_execution_monitor_lost}
  catch
    :exit, _ -> {:error, :governance_execution_monitor_lost}
  end

  def init({port, admission, validate, observe, started_ms}) do
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
      in_flight: nil,
      failed: nil,
      sequence: 1,
      inference_finished: false,
      published_at: now
    }

    Process.send_after(self(), :tick, 100)
    {:ok, state}
  end

  def handle_info({:native_usage, payload}, state) do
    if actual_usage?(payload) do
      budget = TurnBudget.observe(state.budget, payload)
      {:noreply, %{state | budget: budget, metric_at: System.monotonic_time(:millisecond), has_metrics: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:validation, ref, result}, %{in_flight: ref} = state) do
    now = System.monotonic_time(:millisecond)
    state = if result == :ok, do: %{state | valid_at: now}, else: fail(state, :governance_execution_authority_lost)
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info({:validation, _, _}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    state = if state.inference_finished and state.has_metrics, do: %{state | metric_at: now}, else: state

    state =
      cond do
        state.failed != nil -> state
        now >= state.deadline -> fail(state, :governance_execution_deadline)
        state.budget.uncached_input_tokens >= state.tokens -> fail(state, :governance_execution_token_ceiling)
        now - state.valid_at > 3000 -> fail(state, :governance_execution_authority_stale)
        now - state.metric_at > 30_000 -> fail(state, :governance_execution_measurement_stale)
        true -> state
      end

    state =
      if state.failed == nil and state.in_flight == nil do
        owner = self()
        ref = make_ref()
        validate = state.validate
        observe = state.observe
        measurement = metrics(state, now)
        publish = state.has_metrics and (now - state.published_at >= 10_000 or state.budget.uncached_input_tokens > Map.get(state, :published_tokens, -1))

        spawn(fn ->
          result =
            try do
              with :ok <- validate.(), :ok <- if(publish, do: observe.(measurement), else: :ok), do: :ok
            rescue
              _ -> {:error, :validation_failed}
            catch
              _, _ -> {:error, :validation_failed}
            end

          send(owner, {:validation, ref, result})
        end)

        state
        |> Map.put(:in_flight, ref)
        |> Map.put(:sequence, state.sequence + 1)
        |> then(fn current -> if publish, do: current |> Map.put(:published_at, now) |> Map.put(:published_tokens, state.budget.uncached_input_tokens), else: current end)
      else
        state
      end

    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end

  def handle_call(:health, _from, state), do: {:reply, if(state.failed == nil, do: :ok, else: {:error, state.failed}), state}
  def handle_call(:inference_finished, _from, %{has_metrics: true} = state), do: {:reply, :ok, %{state | inference_finished: true}}
  def handle_call(:inference_finished, _from, state), do: {:reply, {:error, :governance_execution_measurement_missing}, state}

  def handle_call(:finish, _from, state) do
    SymphonyElixir.GovernanceProcess.stop(state.port)
    result = if state.has_metrics, do: {:ok, Map.put(metrics(state, System.monotonic_time(:millisecond)), :cancelled, state.failed != nil)}, else: {:error, :governance_execution_measurement_missing}
    {:stop, :normal, result, state}
  end

  def terminate(reason, state) do
    if reason != :normal, do: SymphonyElixir.GovernanceProcess.stop(state.port)
    :ok
  end

  defp metrics(state, now),
    do: %{
      sequence: state.sequence + 1,
      uncachedInputTokens: if(state.has_metrics, do: state.budget.uncached_input_tokens, else: nil),
      wallTimeSeconds: div(max(now - state.started, 0), 1000),
      observedAt: DateTime.to_iso8601(DateTime.utc_now())
    }

  defp fail(%{failed: nil} = state, reason) do
    SymphonyElixir.GovernanceProcess.stop(state.port)
    %{state | failed: reason}
  end

  defp fail(state, _), do: state

  defp actual_usage?(payload) when is_map(payload) do
    Enum.any?(payload, fn {k, v} -> (k in ~w(input_tokens inputTokens prompt_tokens) and is_integer(v)) or actual_usage?(v) end)
  end

  defp actual_usage?(payload) when is_list(payload), do: Enum.any?(payload, &actual_usage?/1)
  defp actual_usage?(_), do: false
end
