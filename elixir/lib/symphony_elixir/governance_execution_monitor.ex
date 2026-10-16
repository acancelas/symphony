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
    GenServer.start(__MODULE__, {port, admission, validate, observe, started_ms, thread_id, self()})
  end

  @doc "Host-only fixed QA transport: the independent monitor owns the port and forwards output to its Run owner."
  @spec open_command(pid(), String.t(), list()) :: {:ok, port()} | {:error, atom()}
  def open_command(pid, executable, options), do: GenServer.call(pid, {:open_command, executable, options}, 2_000)

  @spec close_command(pid(), port()) :: :ok | {:error, atom()}
  def close_command(pid, port) do
    if Process.alive?(pid), do: GenServer.call(pid, {:close_command, port}, 2_000), else: GovernanceProcess.stop(port)
  catch
    :exit, _ -> GovernanceProcess.stop(port)
  end

  @spec inference_finished(pid()) :: :ok | {:error, atom()}
  def inference_finished(pid), do: GenServer.call(pid, :inference_finished, 1_000)

  @spec worker_retired(pid()) :: :ok | {:error, atom()}
  def worker_retired(pid), do: GenServer.call(pid, :worker_retired, 1_000)

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
  @spec init({port(), map(), gate(), observer(), integer(), thread_id(), pid()}) :: {:ok, map()}
  def init({port, admission, validate, observe, started_ms, thread_id, owner}) do
    Process.flag(:trap_exit, true)
    now = System.monotonic_time(:millisecond)
    {:ok, deadline, _} = DateTime.from_iso8601(admission["deadline"])
    remaining = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)

    state = %{
      port: port,
      owner: owner,
      owner_ref: Process.monitor(owner),
      command_ports: %{},
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
      worker_retired: false,
      published_at: now
    }

    Process.send_after(self(), :tick, 100)
    {:ok, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({:DOWN, ref, :process, owner, _}, %{owner_ref: ref, owner: owner} = state) do
    stop_owned_ports(state)
    {:stop, :normal, %{state | failed: :governance_run_owner_lost}}
  end

  def handle_info({port, payload}, state) when is_port(port) do
    if Map.has_key?(state.command_ports, port), do: send(state.owner, {port, payload})
    commands = if match?({:exit_status, _}, payload), do: Map.delete(state.command_ports, port), else: state.command_ports
    {:noreply, %{state | command_ports: commands}}
  end

  def handle_info({:EXIT, port, _}, state) when is_port(port), do: {:noreply, state}

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
  def handle_call({:open_command, executable, options}, {owner, _}, %{owner: owner, worker_retired: true, has_metrics: true} = state) do
    next = check_limits(state, System.monotonic_time(:millisecond))

    if next.failed == nil do
      port = Port.open({:spawn_executable, String.to_charlist(executable)}, options)
      {:reply, {:ok, port}, %{next | command_ports: Map.put(next.command_ports, port, true)}}
    else
      {:reply, {:error, next.failed}, next}
    end
  rescue
    _ -> {:reply, {:error, :governance_qa_port_unavailable}, state}
  end

  def handle_call({:open_command, _, _}, _from, state),
    do: {:reply, {:error, :governance_qa_custody_unverified}, state}

  def handle_call({:close_command, port}, {owner, _}, %{owner: owner} = state) do
    if Map.has_key?(state.command_ports, port), do: GovernanceProcess.stop(port)
    {:reply, :ok, %{state | command_ports: Map.delete(state.command_ports, port)}}
  end

  def handle_call({:close_command, _}, _from, state),
    do: {:reply, {:error, :governance_qa_custody_unverified}, state}

  def handle_call(:health, _from, state),
    do: {:reply, if(state.failed == nil, do: :ok, else: {:error, state.failed}), state}

  def handle_call(:inference_finished, _from, %{has_metrics: true} = state),
    do: {:reply, :ok, %{state | inference_finished: true}}

  def handle_call(:inference_finished, _from, state),
    do: {:reply, {:error, :governance_execution_measurement_missing}, state}

  def handle_call(:worker_retired, _from, %{has_metrics: true} = state) do
    case Port.info(state.port) do
      nil -> {:reply, :ok, %{state | worker_retired: true, inference_finished: true}}
      _ -> {:reply, {:error, :governance_worker_still_attached}, state}
    end
  rescue
    ArgumentError -> {:reply, :ok, %{state | worker_retired: true, inference_finished: true}}
  end

  def handle_call(:worker_retired, _from, state),
    do: {:reply, {:error, :governance_execution_measurement_missing}, state}

  def handle_call(:finish, _from, state) do
    stop_owned_ports(state)

    result =
      if state.has_metrics,
        do: {:ok, Map.put(metrics(state, System.monotonic_time(:millisecond)), :cancelled, state.failed != nil)},
        else: {:error, :governance_execution_measurement_missing}

    {:stop, :normal, result, state}
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    stop_owned_ports(state)
    Process.demonitor(state.owner_ref, [:flush])
    :ok
  end

  defp stop_owned_ports(state) do
    GovernanceProcess.stop(state.port)
    Enum.each(Map.keys(state.command_ports), &GovernanceProcess.stop/1)
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
      workerState: if(state.worker_retired, do: "worker_stopped", else: "running"),
      uncachedInputTokens: if(state.has_metrics, do: state.budget.uncached_input_tokens, else: nil),
      wallTimeSeconds: div(max(now - state.started, 0), 1000),
      observedAt: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp fail(%{failed: nil} = state, reason) do
    stop_owned_ports(state)
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
