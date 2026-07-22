defmodule SymphonyElixir.GoalPlanningCoordinator do
  @moduledoc """
  Converts an approved product Goal into a reviewed, durable delivery proposal.

  The analyst and reviewer run in independent Codex sessions. The coordinator
  advances the Goal to the human decision queue only after game-api confirms a
  persisted proposal and a passed independent review.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @max_cycles 3

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword(), String.t() | nil) ::
          :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, recipient, opts, worker_host) do
    context = %{
      workspace: workspace,
      issue: issue,
      recipient: recipient,
      worker_host: worker_host,
      app_server: Keyword.get(opts, :app_server_module, AppServer),
      client: Keyword.get(opts, :game_api_client_module, Client),
      max_cycles: Keyword.get(opts, :max_goal_planning_cycles, @max_cycles)
    }

    plan(context, 1)
  end

  defp plan(context, cycle) do
    with :ok <- run_analyst(context, cycle),
         :ok <- run_reviewer(context, cycle),
         {:ok, planning} <- fetch_planning(context) do
      evaluate_review(context, planning, cycle)
    end
  end

  defp evaluate_review(context, %{"proposal" => proposal, "review" => review}, cycle)
       when is_map(proposal) and is_map(review) do
    case review["status"] do
      "passed" ->
        request_human_decision(context)

      status when status in ["changes_requested", "inconclusive"] and cycle < context.max_cycles ->
        plan(context, cycle + 1)

      status when status in ["changes_requested", "inconclusive"] ->
        block_exhausted(context, review, cycle)

      other ->
        {:error, {:invalid_goal_review_status, other}}
    end
  end

  defp evaluate_review(_context, planning, _cycle),
    do: {:error, {:goal_planning_artifacts_missing, planning}}

  defp run_analyst(context, cycle) do
    issue = context.issue
    native_ref = issue.native_ref || %{}

    prompt = """
    You are the BOS product and delivery analyst for Goal #{issue.identifier},
    analysis cycle #{cycle}. Inspect this repository, its AGENTS.md, architecture,
    related modules, tests, reusable capabilities, cross-repository dependencies,
    risks, security boundaries and the full Goal context. Use bos-mcp for global
    BOS state. Produce the simplest complete delivery decomposition that fulfils
    the Goal without reducing scope or introducing temporary contracts.

    Persist exactly one new proposal with bos_propose_goal_breakdown using:
    issueNumber #{native_ref["issueNumber"]}, runId #{native_ref["runId"]}, and a
    unique operationId ending in cycle #{cycle}. Each capability must contain a
    stable key, title, context, expectedOutcome, scope, outOfScope,
    acceptanceCriteria, risk, autonomy, and an issues array. Each issue must
    contain a stable key, title, context, expectedOutcome, scope, outOfScope,
    acceptanceCriteria, dependencies (stable issue keys), risk and autonomy.
    Include explicit rationale, cross-capability dependencies and risks. Do not
    create Capabilities or Issues yet, modify product code, approve the proposal,
    or transition the Goal. End only after the durable receipt is confirmed.
    """

    run_role(context, "goal-analyst", prompt)
  end

  defp run_reviewer(context, cycle) do
    issue = context.issue
    native_ref = issue.native_ref || %{}

    prompt = """
    You are the independent BOS Goal proposal reviewer for #{issue.identifier},
    review cycle #{cycle}. Start a fresh analysis: retrieve the latest proposal
    with bos_get_goal_planning, inspect the repository and challenge duplication,
    simpler alternatives, compatibility, security, reversibility, missing scope,
    unverifiable acceptance criteria, dependency order and over-engineering.
    Do not modify files or the proposal.

    Persist exactly one bos_record_goal_breakdown_review with issueNumber
    #{native_ref["issueNumber"]}, runId #{native_ref["runId"]}, reviewId
    goal_review_#{native_ref["runId"]}_#{cycle}, operationId
    goal_review_#{native_ref["runId"]}_#{cycle}, status passed,
    changes_requested, or inconclusive, plus concrete findings and summary.
    Passing requires affirmative evidence and a complete executable hierarchy.
    Never approve on behalf of a human or create the proposed work items.
    """

    run_role(context, "goal-proposal-reviewer", prompt)
  end

  defp fetch_planning(context) do
    native_ref = context.issue.native_ref || %{}

    context.client.fetch_goal_planning(
      native_ref["repositoryId"],
      native_ref["issueNumber"]
    )
  end

  defp request_human_decision(context) do
    case context.client.request_goal_breakdown_approval(context.issue) do
      {:ok, %{"status" => "completed"}} -> :ok
      {:ok, response} -> {:error, {:goal_approval_request_rejected, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp block_exhausted(context, review, cycle) do
    prompt = """
    You are the BOS delivery coordinator for #{context.issue.identifier}.
    Goal analysis and independent review exhausted #{cycle} cycles. Record a
    durable blocker through bos_block_issue containing this exact unresolved
    review: #{inspect(review)}. Do not create work items, approve, or continue.
    """

    with :ok <- run_role(context, "delivery-coordinator", prompt) do
      {:error, {:goal_planning_cycles_exhausted, review}}
    end
  end

  defp run_role(context, actor, prompt) do
    with {:ok, session} <-
           context.app_server.start_session(context.workspace,
             worker_host: context.worker_host,
             environment_overrides: [{"BOS_MCP_ACTOR", actor}]
           ) do
      try do
        callback = fn message ->
          send_update(context.recipient, context.issue, actor, message)
        end

        case context.app_server.run_turn(session, prompt, context.issue,
               on_message: callback,
               role: actor
             ) do
          {:ok, _turn} -> :ok
          {:error, reason} -> {:error, reason}
        end
      after
        context.app_server.stop_session(session)
      end
    end
  end

  defp send_update(recipient, %Issue{id: issue_id}, actor, message)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:codex_worker_update, issue_id, Map.put(message, :delivery_actor, actor)})
    :ok
  end

  defp send_update(_recipient, _issue, _actor, _message), do: :ok
end
