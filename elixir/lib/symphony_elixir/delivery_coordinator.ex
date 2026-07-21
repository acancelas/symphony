defmodule SymphonyElixir.DeliveryCoordinator do
  @moduledoc """
  Runs independent specialist reviews, bounded repair cycles, and the final
  policy hand-off after the implementation agent has finished a workspace turn.

  Every role receives a fresh Codex session and a distinct BOS MCP actor. The
  durable Review documents in GitHub, rather than model prose, decide whether
  the delivery can advance.
  """

  require Logger

  alias SymphonyElixir.CandidateHead
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @review_roles ~w(functional architecture security quality visual)
  @max_repair_cycles 3
  @max_review_record_attempts 2
  @max_review_lookup_attempts 3

  @doc """
  Returns whether this AgentRun has already crossed the durable review-stage
  boundary. Scheduler retries use this projection to avoid reopening the
  implementation Codex session after at least one specialist Review exists.
  """
  @spec review_stage_started?(Issue.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def review_stage_started?(%Issue{} = issue, opts \\ []) do
    client = Keyword.get(opts, :game_api_client_module, Client)
    native_ref = issue.native_ref || %{}

    with repository_id when is_binary(repository_id) <- native_ref["repositoryId"],
         run_id when is_binary(run_id) <- native_ref["runId"],
         {:ok, artifacts} <- client.fetch_run_artifacts(repository_id, run_id, "reviews") do
      {:ok, artifacts != []}
    else
      nil -> {:ok, false}
      {:error, reason} -> {:error, reason}
      _ -> {:ok, false}
    end
  end

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword(), String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, recipient, opts, worker_host) do
    app_server = Keyword.get(opts, :app_server_module, AppServer)
    client = Keyword.get(opts, :game_api_client_module, Client)
    roles = Keyword.get(opts, :review_roles, @review_roles)
    max_cycles = Keyword.get(opts, :max_repair_cycles, @max_repair_cycles)
    max_lookup_attempts = Keyword.get(opts, :max_review_lookup_attempts, @max_review_lookup_attempts)
    sleep_fn = Keyword.get(opts, :review_lookup_sleep, &Process.sleep/1)
    candidate_head = Keyword.get(opts, :candidate_head_module, CandidateHead)

    context = %{
      workspace: workspace,
      issue: issue,
      recipient: recipient,
      worker_host: worker_host,
      app_server: app_server,
      client: client,
      roles: roles,
      max_lookup_attempts: max_lookup_attempts,
      sleep_fn: sleep_fn,
      candidate_head: candidate_head
    }

    with {:ok, _reviewed_candidate} <- review_and_repair(context, 1, max_cycles),
         {:ok, final_candidate} <- candidate_head.confirm(workspace, issue, worker_host) do
      run_finalizer(workspace, issue, recipient, worker_host, app_server, final_candidate)
    end
  end

  defp review_and_repair(context, cycle, max_cycles) do
    with {:ok, candidate} <-
           context.candidate_head.confirm(
             context.workspace,
             context.issue,
             context.worker_host
           ),
         :ok <- run_reviews(context, cycle, candidate),
         {:ok, reviews} <- fetch_cycle_reviews(context, cycle) do
      handle_reviews(context, reviews, candidate, cycle, max_cycles)
    end
  end

  defp handle_reviews(context, reviews, candidate, cycle, max_cycles) do
    if Enum.all?(reviews, &(&1["status"] == "passed")) do
      {:ok, candidate}
    else
      continue_review_cycle(context, reviews, cycle, max_cycles)
    end
  end

  defp continue_review_cycle(context, reviews, cycle, max_cycles) do
    findings = summarize_findings(reviews)

    if cycle >= max_cycles do
      with :ok <- run_escalation(context, findings, cycle) do
        {:error, {:review_repair_limit_reached, findings}}
      end
    else
      with :ok <- run_repair(context, reviews, cycle) do
        review_and_repair(context, cycle + 1, max_cycles)
      end
    end
  end

  defp run_reviews(context, cycle, candidate) do
    Enum.reduce_while(context.roles, :ok, fn role, :ok ->
      case run_or_reuse_review(context, role, cycle, candidate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_or_reuse_review(context, role, cycle, candidate) do
    case review_recorded?(context, role, cycle) do
      {:ok, true} ->
        Logger.info("Reusing durable specialist Review role=#{role} cycle=#{cycle}")
        :ok

      {:ok, false} ->
        run_review_until_durable(context, role, cycle, candidate, 1)

      {:error, reason} ->
        {:error, {:review_lookup_failed, role, reason}}
    end
  end

  defp run_review_until_durable(context, role, cycle, candidate, record_attempt) do
    prompt = review_prompt(context.issue, role, cycle, candidate, record_attempt)

    case run_role(
           context.app_server,
           context.workspace,
           context.issue,
           context.worker_host,
           "#{role}-reviewer",
           prompt,
           context.recipient
         ) do
      :ok -> verify_or_retry_review(context, role, cycle, candidate, record_attempt)
      {:error, reason} -> {:error, {:reviewer_failed, role, reason}}
    end
  end

  defp verify_or_retry_review(context, role, cycle, candidate, record_attempt) do
    case review_recorded?(context, role, cycle) do
      {:ok, true} ->
        :ok

      {:ok, false} when record_attempt < @max_review_record_attempts ->
        Logger.warning("Reviewer ended without a durable artifact; retrying role=#{role} cycle=#{cycle} record_attempt=#{record_attempt + 1}")

        run_review_until_durable(context, role, cycle, candidate, record_attempt + 1)

      {:ok, false} ->
        {:error, {:review_artifact_missing, role, cycle}}

      {:error, reason} ->
        {:error, {:review_lookup_failed, role, reason}}
    end
  end

  defp review_recorded?(context, role, cycle) do
    native_ref = context.issue.native_ref || %{}
    expected_id = "review_#{native_ref["runId"]}_#{cycle}_#{role}"

    with {:ok, artifacts} <- fetch_review_artifacts(context) do
      {:ok, Enum.any?(artifacts, &(&1["reviewId"] == expected_id))}
    end
  end

  defp fetch_cycle_reviews(context, cycle) do
    native_ref = context.issue.native_ref || %{}
    run_id = native_ref["runId"]

    with {:ok, artifacts} <- fetch_review_artifacts(context) do
      expected_ids = Map.new(context.roles, &{&1, "review_#{run_id}_#{cycle}_#{&1}"})

      reviews =
        Enum.map(context.roles, fn role ->
          Enum.find(artifacts, &(&1["reviewId"] == expected_ids[role]))
        end)

      case Enum.find_index(reviews, &is_nil/1) do
        nil -> {:ok, reviews}
        index -> {:error, {:review_artifact_missing, Enum.at(context.roles, index), cycle}}
      end
    end
  end

  defp fetch_review_artifacts(context, attempt \\ 1) do
    native_ref = context.issue.native_ref || %{}

    case context.client.fetch_run_artifacts(
           native_ref["repositoryId"],
           native_ref["runId"],
           "reviews"
         ) do
      {:error, {:game_api_rate_limited, retry_after_ms}}
      when attempt < context.max_lookup_attempts and is_integer(retry_after_ms) and retry_after_ms >= 0 ->
        delay_ms = max(retry_after_ms, 50)

        Logger.warning(
          "Review lookup paused by the shared provider circuit; preserving the completed Codex stage " <>
            "attempt=#{attempt} delay_ms=#{delay_ms}"
        )

        context.sleep_fn.(delay_ms)
        fetch_review_artifacts(context, attempt + 1)

      result ->
        result
    end
  end

  defp run_repair(context, reviews, cycle) do
    findings = summarize_findings(reviews)

    prompt = """
    You are the BOS repair agent for #{context.issue.identifier}, repair cycle #{cycle}.
    Work only in the existing workspace and exact AgentRun. Review the durable
    findings below, inspect the current diff, implement every valid correction,
    run the complete repository validation, commit the repaired exact HEAD, and
    record updated evidence through bos-mcp. Do not approve your own work and do
    not request merge or human approval; fresh independent reviewers run next.

    Findings:
    #{findings}
    """

    run_role(
      context.app_server,
      context.workspace,
      context.issue,
      context.worker_host,
      "repair-agent",
      prompt,
      context.recipient
    )
  end

  defp run_finalizer(workspace, issue, recipient, worker_host, app_server, candidate) do
    prompt = """
    You are the BOS delivery coordinator for #{issue.identifier}. All five
    independent specialist Reviews have passed for the current repair cycle.
    Re-read the exact confirmed candidate HEAD `#{candidate.head_sha}`, acceptance
    contract, checks, reviews and evidence through bos-mcp. Confirm the remote
    `#{candidate.branch}` branch still equals that SHA. Ensure the PR exists for
    that HEAD, record the final
    EvidenceReport and Attempt outcome, then request only the next transition
    allowed by the configured risk and approval policy. Never grant Approval,
    lower risk, bypass checks, force merge, or fabricate deployment evidence.
    """

    run_role(app_server, workspace, issue, worker_host, "delivery-coordinator", prompt, recipient)
  end

  defp run_escalation(context, findings, cycle) do
    prompt = """
    You are the BOS delivery coordinator for #{context.issue.identifier}. Independent
    review and repair exhausted #{cycle} bounded cycles. Record a durable blocker
    through bos_block_issue with the concrete unresolved findings below. Do not
    modify code, approve, merge, deploy, release, or start another Attempt.

    Unresolved findings:
    #{findings}
    """

    run_role(
      context.app_server,
      context.workspace,
      context.issue,
      context.worker_host,
      "delivery-coordinator",
      prompt,
      context.recipient
    )
  end

  defp run_role(app_server, workspace, issue, worker_host, actor, prompt, recipient) do
    with {:ok, session} <-
           app_server.start_session(workspace,
             worker_host: worker_host,
             environment_overrides: [{"BOS_MCP_ACTOR", actor}]
           ) do
      try do
        callback = fn message -> send_update(recipient, issue, actor, message) end

        case app_server.run_turn(session, prompt, issue, on_message: callback) do
          {:ok, _turn} -> :ok
          {:error, reason} -> {:error, reason}
        end
      after
        app_server.stop_session(session)
      end
    end
  end

  defp review_prompt(issue, role, cycle, candidate, record_attempt) do
    native_ref = issue.native_ref || %{}
    run_id = native_ref["runId"]
    attempt_id = native_ref["attemptId"]

    """
    You are the independent BOS #{role} reviewer for #{issue.identifier}, cycle #{cycle}.
    Begin with the compact delivery context, issue acceptance contract, current
    diff, exact confirmed git HEAD `#{candidate.head_sha}` and existing evidence.
    Confirm the local HEAD and remote `#{candidate.branch}` branch both still
    equal that SHA. Inspect only the instructions and files needed to decide this
    review; do not repeatedly load broad context or rerun an unchanged passing
    validation unless its evidence is missing, stale or insufficient for the
    #{role} decision. Prefer targeted search and summaries before full documents.
    Do not modify files, commits,
    issue state, PR state, risk or approvals. Record exactly one typed Review via
    bos_record_review with reviewId `review_#{run_id}_#{cycle}_#{role}`, runId
    `#{run_id}`, attemptId `#{attempt_id}`, reviewType `#{role}`, actor type
    `agent` and subjectId `#{role}-reviewer`, the exact HEAD SHA, a status of
    `passed`, `changes_requested`, or `inconclusive`, concrete findings, and a
    concise summary. Passing requires affirmative evidence; missing evidence is
    inconclusive. End after the durable Review receipt is confirmed.
    #{review_record_retry_instruction(record_attempt)}
    """
  end

  defp review_record_retry_instruction(1), do: ""

  defp review_record_retry_instruction(record_attempt) do
    "A prior reviewer session ended without the required durable Review. This is record attempt #{record_attempt}; call bos_record_review and confirm its receipt before doing anything else."
  end

  defp summarize_findings(reviews) do
    Enum.map_join(reviews, "\n", fn review ->
      "#{review["reviewType"]}: #{review["status"]} — #{review["summary"]}\n#{inspect(review["findings"] || [])}"
    end)
  end

  defp send_update(recipient, %Issue{id: issue_id}, actor, message)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:codex_worker_update, issue_id, Map.put(message, :delivery_actor, actor)})
    :ok
  end

  defp send_update(_recipient, _issue, _actor, _message), do: :ok
end
