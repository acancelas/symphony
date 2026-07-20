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
  @batch_size 25
  @sensitive_key ~r/(authorization|cookie|credential|password|secret|token)/i
  @bearer ~r/Bearer\s+[A-Za-z0-9._~+\/-]+=*/i
  @max_inline_string_bytes 8_000

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
    runs = recover_pending(root)
    if map_size(runs) > 0, do: send(self(), :flush)
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:ok, %{root: root, runs: runs}}
  end

  @impl true
  def handle_cast({:record, issue, update}, state) do
    case build_event(issue, update, state) do
      {:ok, event, run_state} ->
        run_id = event["runId"]
        next = put_in(state, [:runs, run_id], run_state)
        next = persist_pending(next, issue, event)

        if critical?(update) or length(run_state.pending) >= @batch_size do
          {:noreply, flush_run(next, run_id)}
        else
          {:noreply, next}
        end

      {:error, reason} ->
        Logger.warning("Skipping invalid BOS audit event: #{inspect(reason)}")
        {:noreply, state}
    end
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

      event = %{
        "schemaVersion" => "1.0",
        "eventId" => event_id,
        "occurredAt" => timestamp(now),
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
        "actor" => %{"type" => "runner", "subjectId" => runner_id()},
        "runner" => %{"id" => runner_id(), "type" => "local"},
        "eventType" => event_type(method, update.payload || %{}),
        "status" => event_status(update),
        "summary" => summary(method),
        "references" => %{"branch" => issue.branch_name},
        "evidence" => [],
        "redaction" => %{"applied" => true, "policyVersion" => "1.0"},
        "retention" => %{"category" => "permanent"},
        "payload" => sanitize(update.payload || %{})
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
    case state.runs[run_id] do
      %{pending: []} ->
        state

      %{pending: pending, issue: issue} = run_state ->
        flush_pending_batch(state, run_id, run_state, issue, pending)
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

    persist_batch_result(Client.append_audit_batch(request), state, run_id, run_state, pending, batch_id, batch_path)
  end

  defp persist_batch_result({:ok, receipt}, state, run_id, run_state, pending, batch_id, batch_path) do
    receipt_path = Path.join([state.root, run_id, "receipts", batch_id <> ".json"])
    File.mkdir_p!(Path.dirname(receipt_path))
    atomic_write(receipt_path, Jason.encode!(receipt))
    File.rm(batch_path)
    Enum.each(pending, fn event -> File.rm(event_path(state.root, run_id, event)) end)
    put_in(state, [:runs, run_id], %{run_state | pending: []})
  end

  defp persist_batch_result({:error, reason}, state, run_id, _run_state, _pending, _batch_id, _batch_path) do
    Logger.warning("BOS audit flush deferred run_id=#{run_id}: #{inspect(reason)}")
    state
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
    confirmed_event_ids = confirmed_event_ids(root)

    Path.wildcard(Path.join([root, "*", "events", "*.json"]))
    |> Enum.reduce(%{}, fn path, runs ->
      with {:ok, contents} <- File.read(path),
           {:ok, %{"issue" => identity, "event" => event}} <- Jason.decode(contents),
           run_id when is_binary(run_id) <- event["runId"],
           false <- MapSet.member?(confirmed_event_ids, event["eventId"]) do
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

  defp confirmed_event_ids(root) do
    Path.wildcard(Path.join([root, "*", "receipts", "*.json"]))
    |> Enum.reduce(MapSet.new(), fn path, confirmed ->
      with {:ok, contents} <- File.read(path),
           {:ok, receipt} <- Jason.decode(contents),
           event_ids when is_list(event_ids) <- receipt["eventIds"] do
        Enum.reduce(event_ids, confirmed, &MapSet.put(&2, &1))
      else
        _ -> confirmed
      end
    end)
  end

  defp recover_remote_state(%Issue{native_ref: native_ref} = issue) do
    repository_id = native_ref["repositoryId"]
    run_id = native_ref["runId"]

    case Client.fetch_run(repository_id, run_id) do
      {:ok, %{"auditChain" => chain} = manifest} when is_map(chain) ->
        %{
          sequence: chain["lastSequence"] || 0,
          previous_hash: chain["lastEventHash"],
          pending: [],
          issue: issue,
          current_attempt_id: manifest["currentAttemptId"]
        }

      _ ->
        %{sequence: 0, previous_hash: nil, pending: [], issue: issue, current_attempt_id: nil}
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

  defp critical?(%{event: event}) when event in [:turn_completed, :turn_failed, :turn_cancelled], do: true
  defp critical?(_update), do: false

  defp event_type("item/completed", payload), do: item_event_type(payload, "completed")
  defp event_type("item/started", payload), do: item_event_type(payload, "started")
  defp event_type("turn/completed", _payload), do: "agent.turn_completed"
  defp event_type("turn/failed", _payload), do: "agent.turn_failed"
  defp event_type("turn/cancelled", _payload), do: "agent.turn_cancelled"
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

  defp summary(method), do: "Codex App Server event: #{method}"

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
    sanitized = @bearer |> Regex.replace(value, "Bearer [REDACTED]") |> normalize_paths()

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

  defp timestamp(datetime) do
    base = Calendar.strftime(datetime, "%Y-%m-%dT%H:%M:%S")
    milliseconds = div(datetime.microsecond |> elem(0), 1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    base <> "." <> milliseconds <> "Z"
  end

  defp outbox_root do
    System.get_env("BOS_OUTBOX_ROOT") || Path.expand("~/.bos/outbox")
  end

  defp runner_id, do: System.get_env("BOS_RUNNER_ID") || "x1"

  defp normalize_paths(value) do
    value
    |> String.replace(File.cwd!(), "$WORKSPACE")
    |> String.replace(System.user_home!(), "$HOME")
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
