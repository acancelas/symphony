defmodule SymphonyElixir.DeliveryCoordinator do
  @moduledoc """
  Runs independent specialist reviews, bounded repair cycles, and the final
  policy hand-off after the implementation agent has finished a workspace turn.

  Every role receives a fresh Codex session and a distinct BOS MCP actor. The
  durable Review documents in GitHub, rather than model prose, decide whether
  the delivery can advance.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.CandidateHead
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @review_roles ~w(functional architecture security quality visual)
  @max_repair_cycles 3

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword(), String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, recipient, opts, worker_host) do
    app_server = Keyword.get(opts, :app_server_module, AppServer)
    client = Keyword.get(opts, :game_api_client_module, Client)
    roles = Keyword.get(opts, :review_roles, @review_roles)
    max_cycles = Keyword.get(opts, :max_repair_cycles, @max_repair_cycles)
    candidate_head = Keyword.get(opts, :candidate_head_module, CandidateHead)

    context = %{
      workspace: workspace,
      issue: issue,
      recipient: recipient,
      worker_host: worker_host,
      app_server: app_server,
      client: client,
      roles: roles,
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
         {:ok, reviews} <- fetch_cycle_reviews(context.client, context.issue, context.roles, cycle) do
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
      prompt = review_prompt(context.issue, role, cycle, candidate)

      case run_role(
             context.app_server,
             context.workspace,
             context.issue,
             context.worker_host,
             "#{role}-reviewer",
             prompt,
             context.recipient
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:reviewer_failed, role, reason}}}
      end
    end)
  end

  defp fetch_cycle_reviews(client, issue, roles, cycle) do
    native_ref = issue.native_ref || %{}
    repository_id = native_ref["repositoryId"]
    run_id = native_ref["runId"]

    with {:ok, artifacts} <- client.fetch_run_artifacts(repository_id, run_id, "reviews") do
      expected_ids = Map.new(roles, &{&1, "review_#{run_id}_#{cycle}_#{&1}"})

      reviews =
        Enum.map(roles, fn role ->
          Enum.find(artifacts, &(&1["reviewId"] == expected_ids[role]))
        end)

      case Enum.find_index(reviews, &is_nil/1) do
        nil -> {:ok, reviews}
        index -> {:error, {:review_artifact_missing, Enum.at(roles, index), cycle}}
      end
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

  defp review_prompt(issue, role, cycle, candidate) do
    native_ref = issue.native_ref || %{}
    run_id = native_ref["runId"]
    attempt_id = native_ref["attemptId"]

    """
    You are the independent BOS #{role} reviewer for #{issue.identifier}, cycle #{cycle}.
    Inspect the issue acceptance contract, repository instructions, current diff,
    exact git HEAD `#{candidate.head_sha}`, tests and existing evidence. Confirm
    that the local HEAD and remote `#{candidate.branch}` branch both still equal
    that SHA. Do not modify files, commits,
    issue state, PR state, risk or approvals. Record exactly one typed Review via
    bos_record_review with reviewId `review_#{run_id}_#{cycle}_#{role}`, runId
    `#{run_id}`, attemptId `#{attempt_id}`, reviewType `#{role}`, actor type
    `agent` and subjectId `#{role}-reviewer`, the exact HEAD SHA, a status of
    `passed`, `changes_requested`, or `inconclusive`, concrete findings, and a
    concise summary. Passing requires affirmative evidence; missing evidence is
    inconclusive. End after the durable Review receipt is confirmed.
    """
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
