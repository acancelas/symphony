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
    recover_incomplete_rebases(root)
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
    case state.runs[run_id] do
      %{pending: []} ->
        state

      %{pending: pending, issue: issue} = run_state ->
        flush_pending_batch(state, run_id, run_state, issue, Enum.take(pending, @batch_size))
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

  defp persist_batch_result({:ok, receipt}, state, run_id, run_state, pending, batch_id, batch_path) do
    receipt_path = Path.join([state.root, run_id, "receipts", batch_id <> ".json"])
    File.mkdir_p!(Path.dirname(receipt_path))
    atomic_write(receipt_path, Jason.encode!(receipt))
    File.rm(batch_path)
    Enum.each(pending, fn event -> File.rm(event_path(state.root, run_id, event)) end)
    confirmed_ids = MapSet.new(Enum.map(pending, & &1["eventId"]))
    remaining = Enum.reject(run_state.pending, &MapSet.member?(confirmed_ids, &1["eventId"]))
    next = put_in(state, [:runs, run_id], %{run_state | pending: remaining})
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
       when (status == 409 and code in ["audit_chain_conflict", "audit_sequence_gap"]) or
              (status == 422 and code in ["audit_event_hash_invalid", "audit_canonicalization_failed"]) do
    case recover_remote_state(run_state.issue) do
      %{remote_confirmed?: true} = remote ->
        rebased = rebase_pending_events(run_state.pending, remote.sequence, remote.previous_hash)
        replace_pending_events(state.root, run_id, run_state.issue, rebased)

        next_run = %{
          run_state
          | pending: rebased,
            sequence: List.last(rebased)["sequence"],
            previous_hash: List.last(rebased)["eventHash"],
            current_attempt_id: remote.current_attempt_id
        }

        Logger.info("Rebased #{length(rebased)} unconfirmed BOS audit events after remote #{code} run_id=#{run_id}")

        Process.send_after(self(), :flush, 1_000)
        put_in(state, [:runs, run_id], next_run)

      _ ->
        Logger.warning("BOS audit conflict could not fetch confirmed chain; flush deferred run_id=#{run_id}")

        state
    end
  end

  defp persist_batch_result({:error, reason}, state, run_id, _run_state, _pending, _batch_id, _batch_path) do
    Logger.warning("BOS audit flush deferred run_id=#{run_id}: #{inspect(reason)}")
    state
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

  defp summary(method, %{"command" => command} = payload)
       when method in ["item/started", "item/completed"] and is_binary(command) do
    result = if is_integer(payload["exitCode"]), do: " (exit #{payload["exitCode"]})", else: ""
    "Codex command #{if method == "item/started", do: "started", else: "completed"}: #{command}#{result}"
  end

  defp summary(method, %{"tool" => tool}) when is_binary(tool),
    do: "Codex tool #{if String.ends_with?(method, "started"), do: "requested", else: "confirmed"}: #{tool}"

  defp summary(method, _payload), do: "Codex App Server event: #{method}"

  @doc false
  @spec normalize_codex_payload(String.t(), map(), String.t()) :: map()
  def normalize_codex_payload(method, payload, occurred_at) do
    sanitized = sanitize(payload)

    case {method, codex_item(payload)} do
      {lifecycle, item} when lifecycle in ["item/started", "item/completed"] and is_map(item) ->
        normalize_item_payload(lifecycle, item, sanitized, occurred_at)

      _ ->
        sanitized
    end
  end

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

  defp command_payload(method, item, sanitized, occurred_at) do
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
      "redacted" => true,
      "source" => sanitized
    }
  end

  defp tool_payload(item, sanitized) do
    %{
      "toolCallId" => item["id"],
      "tool" => item["name"] || item["tool"] || item["server"],
      "status" => item["status"],
      "source" => sanitized
    }
  end

  defp codex_item(payload),
    do: get_in(payload, ["params", "item"]) || payload["item"]

  defp normalize_command(command) when is_binary(command), do: normalize_paths(command)

  defp normalize_command(command) when is_list(command) do
    command
    |> Enum.map_join(" ", &to_string/1)
    |> normalize_paths()
  end

  defp normalize_command(_command), do: nil

  defp normalize_optional_path(path) when is_binary(path), do: normalize_paths(path)
  defp normalize_optional_path(_path), do: nil

  defp output_summary(output) when is_binary(output) do
    output
    |> normalize_paths()
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
  defp implementation_agent_id, do: System.get_env("BOS_IMPLEMENTATION_AGENT_ID") || "implementation-agent"

  defp normalize_paths(value) do
    value
    |> String.replace(File.cwd!(), "$WORKSPACE")
    |> String.replace(System.user_home!(), "$HOME")
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
