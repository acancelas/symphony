defmodule SymphonyElixir.Audit.Outbox do
  @moduledoc """
  Durable local outbox for automatic Codex App Server audit events.

  Files remain append-only and retryable until `game-api` confirms that their
  corresponding audit batch is present on GitHub's `bos/audit` branch.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @flush_interval_ms 60_000
  @batch_size 50
  @initial_backoff_ms 2_000
  @maximum_backoff_ms 300_000
  @provider_initial_backoff_ms 60_000
  @provider_maximum_backoff_ms 900_000
  @sensitive_key ~r/(authorization|cookie|credential|password|secret|token)/i
  @bearer ~r/Bearer\s+[A-Za-z0-9._~+\/-]+=*/i
  @max_inline_string_bytes 8_000
  @max_checkpoint_bytes 3_000_000
  @max_event_summary_characters 2_000
  @sensitive_assignment ~r/(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|COOKIE|AUTHORIZATION|API[_-]?KEY)[A-Z0-9_]*)(\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s]+)/
  @sensitive_json_pair ~r/(?i)(["']?(?:authorization|cookie|credential|password|secret|token|api[_-]?key)["']?\s*:\s*)(?:"[^"]*"|'[^']*'|[^\s,}\]]+)/
  @sensitive_flag ~r/(?i)(--?(?:authorization|cookie|credential|password|secret|token|api[_-]?key)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s]+)/
  @durable_event_types MapSet.new([
                         "agent.turn_started",
                         "agent.turn_completed",
                         "agent.turn_failed",
                         "agent.turn_cancelled",
                         "command.started",
                         "command.completed",
                         "workspace.checkpointed",
                         "tool.requested",
                         "tool.confirmed"
                       ])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec record(Issue.t(), map()) :: :ok
  def record(%Issue{} = issue, update) when is_map(update) do
    GenServer.cast(__MODULE__, {:record, issue, update})
  end

  @spec flush_all() :: :ok
  def flush_all, do: GenServer.call(__MODULE__, :flush_all, 30_000)

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, outbox_root())
    File.mkdir_p!(root)
    recover_incomplete_rebases(root)
    compact_confirmed_receipts(root)
    compact_confirmed_outbox_files(root)
    compact_legacy_telemetry(root)
    compact_legacy_quarantine(root)
    runs = root |> recover_pending() |> repair_recovered_chains(root)
    if map_size(runs) > 0, do: send(self(), :flush)
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:ok, %{root: root, runs: runs, backoffs: %{}, provider_backoff: nil}}
  end

  @impl true
  def handle_cast({:record, issue, update}, state) do
    if auditable_update?(update), do: record_auditable(issue, update, state), else: {:noreply, state}
  end

  defp record_auditable(issue, update, state) do
    case build_event(issue, update, state) do
      {:ok, event, run_state} ->
        run_id = event["runId"]

        next =
          state
          |> put_in([:runs, run_id], run_state)
          |> persist_pending(issue, event)
          |> maybe_flush_run(run_id, update, run_state)

        {:noreply, next}

      {:error, reason} ->
        Logger.warning("Skipping invalid BOS audit event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp maybe_flush_run(state, run_id, update, run_state) do
    if critical?(update) or length(run_state.pending) >= @batch_size,
      do: flush_run(state, run_id),
      else: state
  end

  @impl true
  def handle_call(:flush_all, _from, state) do
    next = Enum.reduce(Map.keys(state.runs), state, &flush_run(&2, &1))
    {:reply, :ok, next}
  end

  @impl true
  def handle_info(:flush, state) do
    next = Enum.reduce(Map.keys(state.runs), state, &flush_run(&2, &1))
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:noreply, next}
  end

  defp build_event(%Issue{native_ref: native_ref} = issue, update, state) do
    run_id = native_ref["runId"]
    repository_id = native_ref["repositoryId"]

    if blank?(run_id) or blank?(repository_id) do
      {:error, :missing_run_identity}
    else
      current = Map.get_lazy(state.runs, run_id, fn -> recover_remote_state(issue) end)
      sequence = current.sequence + 1
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      unique = System.unique_integer([:positive, :monotonic])
      event_id = "event_#{System.system_time(:millisecond)}_#{unique}"
      method = get_in(update, [:payload, "method"]) || Atom.to_string(update.event)
      occurred_at = timestamp(now)
      normalized_payload = normalize_codex_payload(method, update.payload || %{}, occurred_at)

      event = %{
        "schemaVersion" => "1.0",
        "eventId" => event_id,
        "occurredAt" => occurred_at,
        "scopeType" => "run",
        "scopeId" => run_id,
        "sequence" => sequence,
        "previousEventHash" => current.previous_hash,
        "correlationId" => run_id,
        "operationId" => "op_#{event_id}",
        "repositoryId" => repository_id,
        "issueNumber" => native_ref["issueNumber"],
        "runId" => run_id,
        "attemptId" => attempt_id(issue, current),
        "actor" => actor_for_update(update, method),
        "runner" => %{"id" => runner_id(), "type" => "local"},
        "eventType" => event_type(method, update.payload || %{}),
        "status" => event_status(update),
        "summary" => summary(method, normalized_payload),
        "references" => %{"branch" => issue.branch_name},
        "evidence" => [],
        "redaction" => %{"applied" => true, "policyVersion" => "1.0"},
        "retention" => retention_for(method, normalized_payload),
        "payload" => normalized_payload
      }

      hash = event |> Map.delete("eventHash") |> CanonicalJson.encode() |> IO.iodata_to_binary() |> sha256()
      event = Map.put(event, "eventHash", hash)

      run_state = %{
        current
        | sequence: sequence,
          previous_hash: hash,
          pending: current.pending ++ [event],
          issue: issue
      }

      {:ok, event, run_state}
    end
  rescue
    error -> {:error, error}
  end

  defp persist_pending(state, issue, event) do
    run_id = event["runId"]
    path = Path.join([state.root, run_id, "events", String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    atomic_write(path, Jason.encode!(%{"issue" => issue_identity(issue), "event" => event}))
    state
  end

  defp flush_run(state, run_id) do
    if provider_backoff_active?(state) or flush_backoff_active?(state, run_id) do
      state
    else
      case state.runs[run_id] do
        %{pending: []} ->
          clear_flush_backoff(state, run_id)

        %{pending: pending, issue: issue} = run_state ->
          flush_pending_batch(state, run_id, run_state, issue, Enum.take(pending, @batch_size))
      end
    end
  end

  defp flush_pending_batch(state, run_id, run_state, issue, pending) do
    batch_id = "batch_#{run_id}_#{hd(pending)["sequence"]}_#{List.last(pending)["sequence"]}"

    request = %{
      "operationId" => "append_#{batch_id}",
      "batchId" => batch_id,
      "repository" => repository_identity(issue),
      "events" => pending
    }

    batch_path = Path.join([state.root, run_id, "batches", batch_id <> ".json"])
    File.mkdir_p!(Path.dirname(batch_path))
    atomic_write(batch_path, Jason.encode!(request))

    client = Application.get_env(:symphony_elixir, :game_api_client_module, Client)
    persist_batch_result(client.append_audit_batch(request), state, run_id, run_state, pending, batch_id, batch_path)
  end

  defp persist_batch_result({:ok, receipt}, state, run_id, run_state, pending, _batch_id, batch_path) do
    persist_confirmed_watermark(state.root, run_id, pending, receipt)
    File.rm(batch_path)
    Enum.each(pending, fn event -> File.rm(event_path(state.root, run_id, event)) end)
    confirmed_ids = MapSet.new(Enum.map(pending, & &1["eventId"]))
    remaining = Enum.reject(run_state.pending, &MapSet.member?(confirmed_ids, &1["eventId"]))

    next =
      state
      |> put_in([:runs, run_id], %{run_state | pending: remaining})
      |> clear_flush_backoff(run_id)
      |> clear_provider_backoff()

    if remaining == [], do: next, else: flush_run(next, run_id)
  end

  defp persist_batch_result(
         {:error, {:game_api_http_error, status, code}},
         state,
         run_id,
         run_state,
         _pending,
         _batch_id,
         _batch_path
       )
       when status in [409, 422] and
              code in [
                "audit_canonicalization_failed",
                "audit_chain_conflict",
                "audit_chain_start_invalid",
                "audit_event_hash_invalid",
                "audit_hash_chain_mismatch",
                "audit_sequence_gap"
              ] do
    case recover_remote_state(run_state.issue) do
      %{remote_confirmed?: true} = remote ->
        rebased = rebase_pending_events(run_state.pending, remote.sequence, remote.previous_hash)
        replace_pending_events(state.root, run_id, run_state.issue, rebased)

        next_run =
          Map.merge(run_state, %{
            pending: rebased,
            sequence: List.last(rebased)["sequence"],
            previous_hash: List.last(rebased)["eventHash"],
            current_attempt_id: remote.current_attempt_id
          })

        Logger.info("Rebased #{length(rebased)} unconfirmed BOS audit events after remote #{code} run_id=#{run_id}")

        Process.send_after(self(), :flush, 1_000)
        put_in(state, [:runs, run_id], next_run)

      _ ->
        Logger.warning("BOS audit conflict could not fetch confirmed chain; flush deferred run_id=#{run_id}")

        state
    end
  end

  defp persist_batch_result({:error, reason}, state, run_id, _run_state, _pending, _batch_id, _batch_path) do
    if provider_rate_limited?(reason) do
      {delay_ms, next} = schedule_provider_backoff(state)

      Logger.warning("BOS audit provider circuit opened retry_in_ms=#{delay_ms} trigger_run_id=#{run_id}: #{inspect(reason)}")

      next
    else
      {delay_ms, next} = schedule_flush_backoff(state, run_id)
      Logger.warning("BOS audit flush deferred run_id=#{run_id} retry_in_ms=#{delay_ms}: #{inspect(reason)}")
      next
    end
  end

  defp provider_backoff_active?(state) do
    case state.provider_backoff do
      %{due_at_ms: due_at_ms} -> System.monotonic_time(:millisecond) < due_at_ms
      _ -> false
    end
  end

  defp clear_provider_backoff(state), do: %{state | provider_backoff: nil}

  defp schedule_provider_backoff(state) do
    attempt = get_in(state, [:provider_backoff, :attempt]) || 0
    next_attempt = attempt + 1
    delay_ms = provider_backoff_delay(next_attempt)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    Process.send_after(self(), :flush, delay_ms)

    {delay_ms, %{state | provider_backoff: %{attempt: next_attempt, due_at_ms: due_at_ms}}}
  end

  defp provider_rate_limited?({:game_api_http_error, status}) when status in [403, 429], do: true
  defp provider_rate_limited?({:game_api_http_error, status, _code}) when status in [403, 429], do: true
  defp provider_rate_limited?({:game_api_rate_limited, _retry_after_ms}), do: true
  defp provider_rate_limited?(_reason), do: false

  defp flush_backoff_active?(state, run_id) do
    case get_in(state, [:backoffs, run_id]) do
      %{due_at_ms: due_at_ms} -> System.monotonic_time(:millisecond) < due_at_ms
      _ -> false
    end
  end

  defp clear_flush_backoff(state, run_id), do: update_in(state, [:backoffs], &Map.delete(&1, run_id))

  defp schedule_flush_backoff(state, run_id) do
    attempt = get_in(state, [:backoffs, run_id, :attempt]) || 0
    next_attempt = attempt + 1
    delay_ms = backoff_delay(next_attempt)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    Process.send_after(self(), :flush, delay_ms)

    next =
      put_in(state, [:backoffs, run_id], %{
        attempt: next_attempt,
        due_at_ms: due_at_ms
      })

    {delay_ms, next}
  end

  defp backoff_delay(attempt) do
    {base, maximum} = backoff_delay_bounds_for_test(attempt)
    jitter = :rand.uniform(max(div(base, 4), 1)) - 1
    min(base + jitter, maximum)
  end

  defp provider_backoff_delay(attempt) do
    {base, maximum} = provider_backoff_delay_bounds_for_test(attempt)
    jitter = :rand.uniform(max(maximum - base + 1, 1)) - 1
    min(base + jitter, maximum)
  end

  @doc false
  @spec backoff_delay_bounds_for_test(pos_integer()) :: {pos_integer(), pos_integer()}
  def backoff_delay_bounds_for_test(attempt) when is_integer(attempt) and attempt > 0 do
    exponent = min(attempt - 1, 16)
    base = min(@initial_backoff_ms * Integer.pow(2, exponent), @maximum_backoff_ms)
    {base, min(base + max(div(base, 4) - 1, 0), @maximum_backoff_ms)}
  end

  @doc false
  @spec provider_backoff_delay_bounds_for_test(pos_integer()) :: {pos_integer(), pos_integer()}
  def provider_backoff_delay_bounds_for_test(attempt) when is_integer(attempt) and attempt > 0 do
    exponent = min(attempt - 1, 16)
    base = min(@provider_initial_backoff_ms * Integer.pow(2, exponent), @provider_maximum_backoff_ms)
    {base, min(base + max(div(base, 4) - 1, 0), @provider_maximum_backoff_ms)}
  end

  @doc false
  @spec provider_rate_limited_for_test?(term()) :: boolean()
  def provider_rate_limited_for_test?(reason), do: provider_rate_limited?(reason)

  @doc false
  @spec immediate_flush_for_test?(map()) :: boolean()
  def immediate_flush_for_test?(update), do: critical?(update)

  @doc false
  @spec event_summary_for_test(String.t(), map()) :: String.t()
  def event_summary_for_test(method, payload), do: summary(method, payload)

  @doc false
  @spec hash_event_for_test(map()) :: String.t()
  def hash_event_for_test(event) do
    event
    |> CanonicalJson.encode()
    |> IO.iodata_to_binary()
    |> sha256()
  end

  @doc false
  @spec rebase_pending_events([map()], non_neg_integer(), String.t() | nil) :: [map()]
  def rebase_pending_events(events, confirmed_sequence, confirmed_hash)
      when is_list(events) and is_integer(confirmed_sequence) and confirmed_sequence >= 0 do
    events
    |> Enum.sort_by(& &1["sequence"])
    |> Enum.map_reduce({confirmed_sequence, confirmed_hash}, fn event, {sequence, previous_hash} ->
      next_sequence = sequence + 1

      rebased =
        event
        |> normalize_recovered_event()
        |> Map.put("sequence", next_sequence)
        |> Map.put("previousEventHash", previous_hash)
        |> Map.delete("eventHash")

      hash =
        rebased
        |> CanonicalJson.encode()
        |> IO.iodata_to_binary()
        |> sha256()

      rebased = Map.put(rebased, "eventHash", hash)
      {rebased, {next_sequence, hash}}
    end)
    |> elem(0)
  end

  defp replace_pending_events(root, run_id, issue, events) do
    run_dir = Path.join(root, run_id)
    events_dir = Path.join(run_dir, "events")
    token = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    rebase_dir = Path.join(run_dir, ".events.rebase.#{token}")
    backup_dir = Path.join(run_dir, ".events.backup.#{token}")
    File.mkdir_p!(rebase_dir)

    Enum.each(events, fn event ->
      path =
        Path.join(
          rebase_dir,
          String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"
        )

      atomic_write(path, Jason.encode!(%{"issue" => issue_identity(issue), "event" => event}))
    end)

    if File.dir?(events_dir), do: File.rename!(events_dir, backup_dir)

    try do
      File.rename!(rebase_dir, events_dir)
      File.rm_rf!(backup_dir)
      File.rm_rf!(Path.join(run_dir, "batches"))
    rescue
      error ->
        if not File.dir?(events_dir) and File.dir?(backup_dir),
          do: File.rename!(backup_dir, events_dir)

        reraise error, __STACKTRACE__
    end
  end

  defp repository_identity(%Issue{native_ref: native_ref}) do
    %{
      "repositoryId" => native_ref["repositoryId"],
      "owner" => native_ref["repositoryOwner"],
      "repo" => native_ref["repositoryName"]
    }
  end

  defp issue_identity(%Issue{native_ref: native_ref, branch_name: branch_name}) do
    native_ref
    |> Map.take(["repositoryId", "repositoryOwner", "repositoryName", "issueNumber", "runId", "attemptId"])
    |> Map.put("branchName", branch_name)
  end

  defp event_path(root, run_id, event) do
    Path.join([root, run_id, "events", String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"])
  end

  @doc false
  @spec recover_pending(Path.t()) :: map()
  def recover_pending(root) do
    recover_incomplete_rebases(root)
    compact_confirmed_receipts(root)
    compact_confirmed_outbox_files(root)
    confirmed = confirmed_markers(root)

    Path.wildcard(Path.join([root, "*", "events", "*.json"]))
    |> Enum.reduce(%{}, fn path, runs ->
      with {:ok, contents} <- File.read(path),
           {:ok, %{"issue" => identity, "event" => raw_event}} <- Jason.decode(contents),
           event <- raw_event,
           run_id when is_binary(run_id) <- event["runId"],
           false <- confirmed_event?(confirmed, run_id, event) do
        current =
          Map.get(runs, run_id, %{
            pending: [],
            issue: issue_from_identity(identity),
            sequence: 0,
            previous_hash: nil
          })

        Map.put(runs, run_id, %{current | pending: current.pending ++ [event]})
      else
        _ -> runs
      end
    end)
    |> Map.new(fn {run_id, run_state} ->
      pending = Enum.sort_by(run_state.pending, & &1["sequence"])
      last = List.last(pending)

      {run_id,
       %{
         run_state
         | pending: pending,
           sequence: last["sequence"],
           previous_hash: last["eventHash"]
       }}
    end)
  end

  @doc false
  @spec repair_recovered_chains(map(), Path.t(), (Issue.t() -> map())) :: map()
  def repair_recovered_chains(runs, root, remote_resolver \\ &recover_remote_state/1)
      when is_map(runs) and is_function(remote_resolver, 1) do
    Enum.reduce(runs, %{}, fn {run_id, run_state}, repaired ->
      next = repair_recovered_run(root, run_id, run_state, remote_resolver)
      Map.put(repaired, run_id, next)
    end)
  end

  defp repair_recovered_run(root, run_id, run_state, remote_resolver) do
    if pending_chain_valid?(run_state.pending) and not pending_requires_normalization?(run_state.pending) do
      run_state
    else
      case remote_resolver.(run_state.issue) do
        %{remote_confirmed?: true} = remote ->
          pending = attach_legacy_summary(root, run_id, run_state.pending)
          rebased = rebase_pending_events(pending, remote.sequence, remote.previous_hash)
          replace_pending_events(root, run_id, run_state.issue, rebased)

          Logger.warning("Rebased #{length(rebased)} legacy unconfirmed BOS audit events after safe telemetry compaction run_id=#{run_id}")

          Map.merge(run_state, %{
            pending: rebased,
            sequence: List.last(rebased)["sequence"],
            previous_hash: List.last(rebased)["eventHash"],
            current_attempt_id: remote.current_attempt_id
          })

        _ ->
          Logger.warning("Preserving non-contiguous legacy BOS audit events because the confirmed remote chain is unavailable run_id=#{run_id}")

          run_state
      end
    end
  end

  defp pending_requires_normalization?(events) do
    Enum.any?(events, fn
      %{"summary" => summary} when is_binary(summary) ->
        String.length(summary) > @max_event_summary_characters

      _event ->
        false
    end)
  end

  defp normalize_recovered_event(%{"summary" => summary} = event) when is_binary(summary),
    do: Map.put(event, "summary", bounded_summary(summary))

  defp normalize_recovered_event(event), do: event

  defp pending_chain_valid?([]), do: true
  defp pending_chain_valid?([event]), do: event_hash_valid?(event)

  defp pending_chain_valid?([first | rest]) do
    if event_hash_valid?(first) do
      rest
      |> Enum.reduce_while(first, &continue_valid_chain/2)
      |> case do
        false -> false
        _last -> true
      end
    else
      false
    end
  end

  defp continue_valid_chain(event, previous) do
    if event_hash_valid?(event) and
         event["sequence"] == previous["sequence"] + 1 and
         event["previousEventHash"] == previous["eventHash"] do
      {:cont, event}
    else
      {:halt, false}
    end
  end

  defp event_hash_valid?(event) do
    expected =
      event
      |> Map.delete("eventHash")
      |> CanonicalJson.encode()
      |> IO.iodata_to_binary()
      |> sha256()

    event["eventHash"] == expected
  end

  defp attach_legacy_summary(root, run_id, [first | rest]) do
    summary = read_json_map(Path.join([root, run_id, "legacy-telemetry-summary.json"]))

    if summary == %{} do
      [first | rest]
    else
      payload =
        first
        |> Map.get("payload", %{})
        |> legacy_summary_payload()
        |> Map.put("legacyTelemetryCompaction", summary)

      [Map.put(first, "payload", payload) | rest]
    end
  end

  defp attach_legacy_summary(_root, _run_id, []), do: []

  defp legacy_summary_payload(value) when is_map(value), do: value
  defp legacy_summary_payload(value), do: %{"original" => value}

  @doc false
  @spec compact_confirmed_receipts(Path.t()) :: non_neg_integer()
  def compact_confirmed_receipts(root) do
    Path.wildcard(Path.join([root, "*", "receipts"]))
    |> Enum.map(&compact_receipts_directory/1)
    |> Enum.sum()
  end

  defp compact_receipts_directory(receipts_dir) do
    receipt_paths = Path.wildcard(Path.join(receipts_dir, "*.json"))

    case receipt_paths do
      [] -> 0
      paths -> persist_compacted_receipts(receipts_dir, paths)
    end
  end

  defp persist_compacted_receipts(receipts_dir, receipt_paths) do
    run_dir = Path.dirname(receipts_dir)
    run_id = Path.basename(run_dir)

    case read_receipt_files(receipt_paths) do
      {:ok, receipts} ->
        watermark =
          Enum.reduce(receipts, read_confirmed_watermark(run_dir), fn {receipt, filename}, acc ->
            merge_receipt_watermark(acc, receipt, filename)
          end)
          |> Map.put("runId", run_id)
          |> Map.put("updatedAt", timestamp(DateTime.utc_now() |> DateTime.truncate(:millisecond)))

        atomic_write(Path.join(run_dir, "confirmed.json"), Jason.encode!(watermark))
        File.rm_rf!(receipts_dir)
        length(receipt_paths)

      {:error, path, reason} ->
        Logger.warning("Preserving uncompactable BOS receipt path=#{path} reason=#{inspect(reason)}")
        0
    end
  end

  @doc false
  @spec compact_confirmed_outbox_files(Path.t()) :: non_neg_integer()
  def compact_confirmed_outbox_files(root) do
    confirmed = confirmed_markers(root)

    event_count =
      Path.wildcard(Path.join([root, "*", "events", "*.json"]))
      |> Enum.count(&remove_confirmed_event_file(&1, confirmed))

    batch_count =
      Path.wildcard(Path.join([root, "*", "batches", "*.json"]))
      |> Enum.count(&remove_confirmed_batch_file(&1, confirmed))

    event_count + batch_count
  end

  defp remove_confirmed_event_file(path, confirmed) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"event" => %{"runId" => run_id} = event}} <- Jason.decode(contents),
         true <- confirmed_event?(confirmed, run_id, event),
         :ok <- File.rm(path) do
      true
    else
      _ -> false
    end
  end

  defp remove_confirmed_batch_file(path, confirmed) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"events" => [%{"runId" => run_id} | _rest] = events}} <- Jason.decode(contents),
         true <- Enum.all?(events, &confirmed_event?(confirmed, run_id, &1)),
         :ok <- File.rm(path) do
      true
    else
      _ -> false
    end
  end

  defp read_receipt_files(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, receipts} ->
      with {:ok, contents} <- File.read(path),
           {:ok, receipt} when is_map(receipt) <- Jason.decode(contents) do
        {:cont, {:ok, [{receipt, Path.basename(path)} | receipts]}}
      else
        {:error, reason} -> {:halt, {:error, path, reason}}
        other -> {:halt, {:error, path, other}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      error -> error
    end
  end

  @doc false
  @spec compact_legacy_telemetry(Path.t()) :: %{kept: non_neg_integer(), quarantined: non_neg_integer()}
  def compact_legacy_telemetry(root) do
    confirmed = confirmed_markers(root)

    Path.wildcard(Path.join([root, "*", "events", "*.json"]))
    |> Enum.reduce(%{kept: 0, quarantined: 0}, &compact_legacy_event(&1, &2, confirmed))
  end

  defp compact_legacy_event(event_path, counts, confirmed) do
    with {:ok, contents} <- File.read(event_path),
         {:ok, %{"event" => event}} <- Jason.decode(contents) do
      classify_legacy_event(event, event_path, counts, confirmed)
    else
      _ -> counts
    end
  end

  defp classify_legacy_event(event, event_path, counts, confirmed) do
    run_id = event["runId"]

    if not durable_recovered_event?(event) and confirmed_event?(confirmed, run_id, event) do
      quarantine_legacy_event(event_path)
      Map.update!(counts, :quarantined, &(&1 + 1))
    else
      Map.update!(counts, :kept, &(&1 + 1))
    end
  end

  defp durable_recovered_event?(%{"eventType" => event_type} = event) do
    MapSet.member?(@durable_event_types, event_type) or
      (event_type == "agent.progress_recorded" and get_in(event, ["payload", "method"]) == "turn/started")
  end

  defp durable_recovered_event?(_event), do: false

  defp quarantine_legacy_event(event_path) do
    events_dir = Path.dirname(event_path)
    run_dir = Path.dirname(events_dir)
    quarantine_dir = Path.join(run_dir, "legacy-telemetry")
    File.mkdir_p!(quarantine_dir)
    File.rename!(event_path, Path.join(quarantine_dir, Path.basename(event_path)))
  end

  @doc false
  @spec compact_legacy_quarantine(Path.t()) :: non_neg_integer()
  def compact_legacy_quarantine(root) do
    confirmed = confirmed_markers(root)

    Path.wildcard(Path.join([root, "*", "legacy-telemetry"]))
    |> Enum.map(&compact_legacy_quarantine_directory(&1, confirmed))
    |> Enum.sum()
  end

  defp compact_legacy_quarantine_directory(quarantine_dir, confirmed) do
    paths = Path.wildcard(Path.join(quarantine_dir, "*.json"))
    run_id = quarantine_dir |> Path.dirname() |> Path.basename()

    {confirmed_paths, pending_paths} =
      Enum.split_with(paths, &confirmed_legacy_path?(&1, confirmed, run_id))

    restore_unconfirmed_legacy_events(quarantine_dir, pending_paths)

    case confirmed_paths do
      [] ->
        remove_empty_directory(quarantine_dir)
        0

      _ ->
        run_dir = Path.dirname(quarantine_dir)
        summary_path = Path.join(run_dir, "legacy-telemetry-summary.json")
        existing = read_json_map(summary_path)

        summary =
          confirmed_paths
          |> Enum.reduce(existing_telemetry_summary(existing), &accumulate_legacy_telemetry/2)
          |> Map.put("schemaVersion", "1.0")
          |> Map.put("runId", Path.basename(run_dir))
          |> Map.put("retention", "aggregated")
          |> Map.put("updatedAt", timestamp(DateTime.utc_now() |> DateTime.truncate(:millisecond)))

        atomic_write(summary_path, Jason.encode!(summary))
        Enum.each(confirmed_paths, &File.rm!/1)
        remove_empty_directory(quarantine_dir)
        length(confirmed_paths)
    end
  end

  defp restore_unconfirmed_legacy_events(_quarantine_dir, []), do: :ok

  defp restore_unconfirmed_legacy_events(quarantine_dir, paths) do
    events_dir = Path.join(Path.dirname(quarantine_dir), "events")
    File.mkdir_p!(events_dir)

    Enum.each(paths, fn path ->
      destination = Path.join(events_dir, Path.basename(path))
      if File.exists?(destination), do: File.rm!(path), else: File.rename!(path, destination)
    end)

    :ok
  end

  defp remove_empty_directory(path) do
    case File.ls(path) do
      {:ok, []} -> File.rmdir(path)
      _ -> :ok
    end
  end

  defp confirmed_legacy_path?(path, confirmed, run_id) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"event" => event}} <- Jason.decode(contents) do
      confirmed_event?(confirmed, run_id, event)
    else
      _ -> false
    end
  end

  defp existing_telemetry_summary(existing) do
    %{
      "totalEvents" => existing["totalEvents"] || 0,
      "sourceBytes" => existing["sourceBytes"] || 0,
      "eventTypes" => existing["eventTypes"] || %{},
      "firstOccurredAt" => existing["firstOccurredAt"],
      "lastOccurredAt" => existing["lastOccurredAt"]
    }
  end

  defp accumulate_legacy_telemetry(path, summary) do
    bytes =
      case File.stat(path) do
        {:ok, stat} -> stat.size
        _ -> 0
      end

    event =
      with {:ok, contents} <- File.read(path),
           {:ok, decoded} <- Jason.decode(contents) do
        decoded["event"] || %{}
      else
        _ -> %{}
      end

    event_type = event["eventType"] || "unknown"
    occurred_at = event["occurredAt"]

    summary
    |> Map.update!("totalEvents", &(&1 + 1))
    |> Map.update!("sourceBytes", &(&1 + bytes))
    |> update_in(["eventTypes"], &Map.update(&1, event_type, 1, fn count -> count + 1 end))
    |> Map.put("firstOccurredAt", earliest_timestamp(summary["firstOccurredAt"], occurred_at))
    |> Map.put("lastOccurredAt", latest_timestamp(summary["lastOccurredAt"], occurred_at))
  end

  defp earliest_timestamp(nil, candidate), do: candidate
  defp earliest_timestamp(current, nil), do: current
  defp earliest_timestamp(current, candidate), do: min(current, candidate)

  defp latest_timestamp(nil, candidate), do: candidate
  defp latest_timestamp(current, nil), do: current
  defp latest_timestamp(current, candidate), do: max(current, candidate)

  defp read_json_map(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(contents) do
      decoded
    else
      _ -> %{}
    end
  end

  defp recover_incomplete_rebases(root) do
    Path.wildcard(Path.join([root, "*"]))
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(fn run_dir ->
      events_dir = Path.join(run_dir, "events")

      entries =
        case File.ls(run_dir) do
          {:ok, names} -> names
          {:error, _reason} -> []
        end

      rebases =
        entries
        |> Enum.filter(&String.starts_with?(&1, ".events.rebase."))
        |> Enum.map(&Path.join(run_dir, &1))
        |> Enum.sort()

      backups =
        entries
        |> Enum.filter(&String.starts_with?(&1, ".events.backup."))
        |> Enum.map(&Path.join(run_dir, &1))
        |> Enum.sort()

      cond do
        File.dir?(events_dir) ->
          Enum.each(rebases ++ backups, &File.rm_rf!/1)

        rebases != [] ->
          selected = List.last(rebases)
          File.rename!(selected, events_dir)
          Enum.each(List.delete(rebases, selected) ++ backups, &File.rm_rf!/1)

        backups != [] ->
          selected = List.last(backups)
          File.rename!(selected, events_dir)
          Enum.each(List.delete(backups, selected), &File.rm_rf!/1)

        true ->
          :ok
      end
    end)
  end

  defp confirmed_markers(root) do
    Path.wildcard(Path.join([root, "*", "confirmed.json"]))
    |> Map.new(fn path ->
      run_id = path |> Path.dirname() |> Path.basename()
      {run_id, read_confirmed_watermark(Path.dirname(path))}
    end)
  end

  defp confirmed_event?(confirmed, run_id, event) do
    marker = Map.get(confirmed, run_id, %{})
    sequence = event["sequence"] || 0
    confirmed_through = marker["confirmedThroughSequence"] || 0
    event_ids = MapSet.new(marker["exceptionEventIds"] || [])
    sequence <= confirmed_through or MapSet.member?(event_ids, event["eventId"])
  end

  defp persist_confirmed_watermark(root, run_id, pending, receipt) do
    run_dir = Path.join(root, run_id)
    existing = read_confirmed_watermark(run_dir)
    confirmed_through = pending |> Enum.map(&(&1["sequence"] || 0)) |> Enum.max(fn -> 0 end)
    last_event = Enum.max_by(pending, &(&1["sequence"] || 0), fn -> %{} end)

    watermark =
      existing
      |> Map.put("schemaVersion", "1.0")
      |> Map.put("runId", run_id)
      |> Map.put("confirmedThroughSequence", max(existing["confirmedThroughSequence"] || 0, confirmed_through))
      |> Map.put("lastEventHash", last_event["eventHash"] || existing["lastEventHash"])
      |> Map.put("lastReceipt", receipt_summary(receipt))
      |> Map.put("updatedAt", timestamp(DateTime.utc_now() |> DateTime.truncate(:millisecond)))

    atomic_write(Path.join(run_dir, "confirmed.json"), Jason.encode!(watermark))
  end

  defp read_confirmed_watermark(run_dir) do
    path = Path.join(run_dir, "confirmed.json")

    with {:ok, contents} <- File.read(path),
         {:ok, marker} when is_map(marker) <- Jason.decode(contents) do
      marker
    else
      _ -> %{"schemaVersion" => "1.0", "confirmedThroughSequence" => 0, "exceptionEventIds" => []}
    end
  end

  defp merge_receipt_watermark(watermark, receipt, filename) do
    batch_id = receipt["batchId"] || Path.rootname(filename)

    case batch_end_sequence(batch_id) do
      sequence when is_integer(sequence) ->
        watermark
        |> Map.put("schemaVersion", "1.0")
        |> Map.put("confirmedThroughSequence", max(watermark["confirmedThroughSequence"] || 0, sequence))
        |> Map.put("lastReceipt", receipt_summary(receipt))

      _ ->
        exception_ids = MapSet.new((watermark["exceptionEventIds"] || []) ++ (receipt["eventIds"] || []))
        Map.put(watermark, "exceptionEventIds", MapSet.to_list(exception_ids))
    end
  end

  defp batch_end_sequence(batch_id) when is_binary(batch_id) do
    case Regex.run(~r/_(\d+)_(\d+)$/, batch_id) do
      [_, _start, finish] -> String.to_integer(finish)
      _ -> nil
    end
  end

  defp batch_end_sequence(_batch_id), do: nil

  defp receipt_summary(receipt) do
    Map.take(receipt, [
      "receiptId",
      "batchId",
      "auditCommitSha",
      "confirmedHeadSha",
      "recordedAt",
      "repositoryId"
    ])
  end

  defp recover_remote_state(%Issue{native_ref: native_ref} = issue) do
    repository_id = native_ref["repositoryId"]
    run_id = native_ref["runId"]

    client = Application.get_env(:symphony_elixir, :game_api_client_module, Client)

    case client.fetch_run(repository_id, run_id) do
      {:ok, %{"auditChain" => chain} = manifest} when is_map(chain) ->
        %{
          sequence: chain["lastSequence"] || 0,
          previous_hash: chain["lastEventHash"],
          pending: [],
          issue: issue,
          current_attempt_id: manifest["currentAttemptId"],
          remote_confirmed?: true
        }

      _ ->
        %{
          sequence: 0,
          previous_hash: nil,
          pending: [],
          issue: issue,
          current_attempt_id: nil,
          remote_confirmed?: false
        }
    end
  end

  defp issue_from_identity(identity) do
    %Issue{
      id: "#{identity["repositoryId"]}:#{identity["issueNumber"]}",
      identifier: "#{identity["repositoryId"]}-#{identity["issueNumber"]}",
      native_ref: identity,
      branch_name: identity["branchName"]
    }
  end

  defp attempt_id(%Issue{native_ref: native_ref}, current) do
    native_ref["attemptId"] || Map.get(current, :current_attempt_id) || "attempt_#{native_ref["runId"]}_1"
  end

  defp atomic_write(path, contents) do
    temporary = path <> ".tmp"
    File.write!(temporary, contents, [:binary, :sync])
    File.rename!(temporary, path)
  end

  @doc false
  @spec auditable_update?(map()) :: boolean()
  def auditable_update?(update) when is_map(update) do
    method = get_in(update, [:payload, "method"]) || update |> Map.get(:event) |> event_method()

    cond do
      method in ["turn/started", "turn/completed", "turn/failed", "turn/cancelled"] ->
        true

      method in ["item/started", "item/completed"] ->
        update
        |> Map.get(:payload, %{})
        |> codex_item()
        |> auditable_item?()

      method == "turn/diff/updated" ->
        true

      true ->
        false
    end
  end

  defp auditable_item?(item) when is_map(item) do
    item_kind(String.downcase(to_string(Map.get(item, ~s(type))))) in [:command, :tool]
  end

  defp auditable_item?(_item), do: false

  defp event_method(event) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", "/")
  defp event_method(_event), do: ""

  defp critical?(%{event: event}) when event in [:turn_completed, :turn_failed, :turn_cancelled], do: true
  defp critical?(_update), do: false

  defp event_type("item/completed", payload), do: item_event_type(payload, "completed")
  defp event_type("item/started", payload), do: item_event_type(payload, "started")
  defp event_type("turn/started", _payload), do: "agent.turn_started"
  defp event_type("turn/completed", _payload), do: "agent.turn_completed"
  defp event_type("turn/failed", _payload), do: "agent.turn_failed"
  defp event_type("turn/cancelled", _payload), do: "agent.turn_cancelled"
  defp event_type("turn/diff/updated", _payload), do: "workspace.checkpointed"
  defp event_type(_method, _payload), do: "agent.progress_recorded"

  defp item_event_type(payload, suffix) do
    type = get_in(payload, ["params", "item", "type"]) || get_in(payload, ["item", "type"]) || ""
    normalized = String.downcase(to_string(type))

    cond do
      String.contains?(normalized, "command") ->
        "command.#{suffix}"

      String.contains?(normalized, "mcp") or String.contains?(normalized, "tool") ->
        if suffix == "started", do: "tool.requested", else: "tool.confirmed"

      true ->
        "agent.item_#{suffix}"
    end
  end

  defp event_status(%{event: :turn_failed}), do: "failed"
  defp event_status(%{event: :turn_cancelled}), do: "cancelled"
  defp event_status(_update), do: "completed"

  defp summary(method, %{"command" => command} = payload)
       when method in ["item/started", "item/completed"] and is_binary(command) do
    result = if is_integer(payload["exitCode"]), do: " (exit #{payload["exitCode"]})", else: ""

    bounded_summary("Codex command #{if method == "item/started", do: "started", else: "completed"}: #{command}#{result}")
  end

  defp summary(method, %{"tool" => tool}) when is_binary(tool),
    do: bounded_summary("Codex tool #{if String.ends_with?(method, "started"), do: "requested", else: "confirmed"}: #{tool}")

  defp summary(method, _payload), do: bounded_summary("Codex App Server event: #{method}")

  defp bounded_summary(value) do
    suffix = "… [truncated]"

    if String.length(value) <= @max_event_summary_characters do
      value
    else
      String.slice(value, 0, @max_event_summary_characters - String.length(suffix)) <> suffix
    end
  end

  @doc false
  @spec normalize_codex_payload(String.t(), map(), String.t()) :: map()
  def normalize_codex_payload("turn/diff/updated", payload, _occurred_at) do
    diff = get_in(payload, ["params", "diff"])

    %{
      "method" => "turn/diff/updated",
      "params" => %{"diff" => checkpoint_diff(diff)}
    }
  end

  def normalize_codex_payload(method, payload, occurred_at) do
    sanitized = sanitize(payload)

    case {method, codex_item(payload)} do
      {lifecycle, item} when lifecycle in ["item/started", "item/completed"] and is_map(item) ->
        normalize_item_payload(lifecycle, item, sanitized, occurred_at)

      _ ->
        sanitized
    end
  end

  defp checkpoint_diff(diff) when is_binary(diff) do
    sanitized = diff |> normalize_paths() |> redact_sensitive_text()
    content_hash = sha256(sanitized)

    if byte_size(sanitized) <= @max_checkpoint_bytes do
      %{
        "content" => sanitized,
        "contentHash" => content_hash,
        "encoding" => "utf-8",
        "format" => "unified_diff",
        "retention" => "permanent",
        "truncated" => false
      }
    else
      %{
        "contentHash" => content_hash,
        "maximumBytes" => @max_checkpoint_bytes,
        "retention" => "summary_only",
        "truncated" => true
      }
    end
  end

  defp checkpoint_diff(diff), do: sanitize(diff)

  defp normalize_item_payload(method, item, sanitized, occurred_at) do
    type = String.downcase(to_string(item["type"] || ""))

    case item_kind(type) do
      :command -> command_payload(method, item, sanitized, occurred_at)
      :tool -> tool_payload(item, sanitized)
      :other -> sanitized
    end
    |> drop_nil_values()
  end

  defp item_kind(type) do
    cond do
      String.contains?(type, "command") -> :command
      String.contains?(type, "mcp") or String.contains?(type, "tool") -> :tool
      true -> :other
    end
  end

  defp command_payload(method, item, _sanitized, occurred_at) do
    command = normalize_command(item["command"] || item["parsedCmd"])
    output = item["aggregatedOutput"] || item["output"] || item["stdout"]

    %{
      "commandId" => item["id"] || "command_unknown",
      "command" => command || "[command unavailable]",
      "workingDirectory" => normalize_optional_path(item["cwd"]),
      "startedAt" => if(method == "item/started", do: occurred_at, else: item["startedAt"]),
      "finishedAt" => if(method == "item/completed", do: occurred_at, else: nil),
      "exitCode" => item["exitCode"],
      "durationMs" => item["durationMs"] || item["duration_ms"],
      "status" => item["status"],
      "outputSummary" => output_summary(output),
      "stdoutReference" => nil,
      "stderrReference" => nil,
      "environmentPolicy" => "restricted",
      "redacted" => true
    }
  end

  defp tool_payload(item, _sanitized) do
    %{
      "toolCallId" => item["id"],
      "tool" => item["name"] || item["tool"] || item["server"],
      "status" => item["status"]
    }
  end

  defp codex_item(payload),
    do: get_in(payload, ["params", "item"]) || payload["item"]

  defp normalize_command(command) when is_binary(command), do: command |> normalize_paths() |> redact_sensitive_text()

  defp normalize_command(command) when is_list(command) do
    command
    |> Enum.map_join(" ", &to_string/1)
    |> normalize_paths()
    |> redact_sensitive_text()
  end

  defp normalize_command(_command), do: nil

  defp normalize_optional_path(path) when is_binary(path), do: normalize_paths(path)
  defp normalize_optional_path(_path), do: nil

  defp output_summary(output) when is_binary(output) do
    output
    |> normalize_paths()
    |> redact_sensitive_text()
    |> String.slice(0, 2_000)
  end

  defp output_summary(_output), do: nil

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @doc false
  @spec actor_for_codex_method(String.t()) :: map()
  def actor_for_codex_method(method) when is_binary(method) do
    if String.starts_with?(method, ["item/", "turn/", "thread/"]) do
      %{"type" => "agent", "subjectId" => implementation_agent_id()}
    else
      %{"type" => "runner", "subjectId" => runner_id()}
    end
  end

  @doc false
  @spec actor_for_update(map(), String.t()) :: map()
  def actor_for_update(%{delivery_actor: actor}, method)
      when is_binary(actor) and actor != "" and is_binary(method) do
    if String.starts_with?(method, ["item/", "turn/", "thread/"]) do
      %{"type" => "agent", "subjectId" => actor}
    else
      actor_for_codex_method(method)
    end
  end

  def actor_for_update(_update, method), do: actor_for_codex_method(method)

  defp retention_for(_method, %{"exitCode" => exit_code}) when is_integer(exit_code) and exit_code != 0,
    do: %{"category" => "long"}

  defp retention_for(_method, _payload), do: %{"category" => "permanent"}

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if Regex.match?(@sensitive_key, to_string(key)) do
        {to_string(key), "[REDACTED]"}
      else
        {to_string(key), sanitize(item)}
      end
    end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_binary(value) do
    sanitized = value |> normalize_paths() |> redact_sensitive_text()

    if byte_size(sanitized) > @max_inline_string_bytes do
      %{
        "summary" => String.slice(sanitized, 0, @max_inline_string_bytes),
        "truncated" => true,
        "contentHash" => sha256(sanitized),
        "retention" => "summary_only"
      }
    else
      sanitized
    end
  end

  defp sanitize(value) when is_integer(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize(value) when is_float(value), do: inspect(value)
  defp sanitize(value), do: inspect(value)

  defp sha256(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp redact_sensitive_text(value) do
    value
    |> then(&Regex.replace(@bearer, &1, "Bearer [REDACTED]"))
    |> then(&Regex.replace(@sensitive_assignment, &1, "\\1\\2[REDACTED]"))
    |> then(&Regex.replace(@sensitive_json_pair, &1, "\\1[REDACTED]"))
    |> then(&Regex.replace(@sensitive_flag, &1, "\\1[REDACTED]"))
  end

  defp timestamp(datetime) do
    base = Calendar.strftime(datetime, "%Y-%m-%dT%H:%M:%S")
    milliseconds = div(datetime.microsecond |> elem(0), 1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    base <> "." <> milliseconds <> "Z"
  end

  defp outbox_root do
    System.get_env("BOS_OUTBOX_ROOT") ||
      Application.get_env(:symphony_elixir, :audit_outbox_root) ||
      Path.expand("~/.bos/outbox")
  end

  defp runner_id, do: System.get_env("BOS_RUNNER_ID") || "x1"
  defp implementation_agent_id, do: System.get_env("BOS_IMPLEMENTATION_AGENT_ID") || "implementation-agent"

  defp normalize_paths(value) do
    value
    |> String.replace(File.cwd!(), "$WORKSPACE")
    |> String.replace(System.user_home!(), "$HOME")
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
