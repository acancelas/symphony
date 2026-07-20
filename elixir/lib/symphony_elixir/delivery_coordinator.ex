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

    with :ok <- review_and_repair(workspace, issue, recipient, worker_host, app_server, client, roles, 1, max_cycles),
         :ok <- run_finalizer(workspace, issue, recipient, worker_host, app_server) do
      :ok
    end
  end

  defp review_and_repair(workspace, issue, recipient, worker_host, app_server, client, roles, cycle, max_cycles) do
    with :ok <- run_reviews(workspace, issue, recipient, worker_host, app_server, roles, cycle),
         {:ok, reviews} <- fetch_cycle_reviews(client, issue, roles, cycle) do
      if Enum.all?(reviews, &(&1["status"] == "passed")) do
        :ok
      else
        if cycle >= max_cycles do
          findings = summarize_findings(reviews)

          with :ok <- run_escalation(workspace, issue, recipient, worker_host, app_server, findings, cycle) do
            {:error, {:review_repair_limit_reached, findings}}
          end
        else
          with :ok <- run_repair(workspace, issue, recipient, worker_host, app_server, reviews, cycle) do
            review_and_repair(
              workspace,
              issue,
              recipient,
              worker_host,
              app_server,
              client,
              roles,
              cycle + 1,
              max_cycles
            )
          end
        end
      end
    end
  end

  defp run_reviews(workspace, issue, recipient, worker_host, app_server, roles, cycle) do
    Enum.reduce_while(roles, :ok, fn role, :ok ->
      prompt = review_prompt(issue, role, cycle)

      case run_role(app_server, workspace, issue, worker_host, "#{role}-reviewer", prompt, recipient) do
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

  defp run_repair(workspace, issue, recipient, worker_host, app_server, reviews, cycle) do
    findings = summarize_findings(reviews)

    prompt = """
    You are the BOS repair agent for #{issue.identifier}, repair cycle #{cycle}.
    Work only in the existing workspace and exact AgentRun. Review the durable
    findings below, inspect the current diff, implement every valid correction,
    run the complete repository validation, commit the repaired exact HEAD, and
    record updated evidence through bos-mcp. Do not approve your own work and do
    not request merge or human approval; fresh independent reviewers run next.

    Findings:
    #{findings}
    """

    run_role(app_server, workspace, issue, worker_host, "repair-agent", prompt, recipient)
  end

  defp run_finalizer(workspace, issue, recipient, worker_host, app_server) do
    prompt = """
    You are the BOS delivery coordinator for #{issue.identifier}. All five
    independent specialist Reviews have passed for the current repair cycle.
    Re-read the exact HEAD, acceptance contract, checks, reviews and evidence
    through bos-mcp. Ensure the PR exists for that HEAD, record the final
    EvidenceReport and Attempt outcome, then request only the next transition
    allowed by the configured risk and approval policy. Never grant Approval,
    lower risk, bypass checks, force merge, or fabricate deployment evidence.
    """

    run_role(app_server, workspace, issue, worker_host, "delivery-coordinator", prompt, recipient)
  end

  defp run_escalation(workspace, issue, recipient, worker_host, app_server, findings, cycle) do
    prompt = """
    You are the BOS delivery coordinator for #{issue.identifier}. Independent
    review and repair exhausted #{cycle} bounded cycles. Record a durable blocker
    through bos_block_issue with the concrete unresolved findings below. Do not
    modify code, approve, merge, deploy, release, or start another Attempt.

    Unresolved findings:
    #{findings}
    """

    run_role(app_server, workspace, issue, worker_host, "delivery-coordinator", prompt, recipient)
  end

  defp run_role(app_server, workspace, issue, worker_host, actor, prompt, recipient) do
    with {:ok, session} <-
           app_server.start_session(workspace,
             worker_host: worker_host,
             environment_overrides: [{"BOS_MCP_ACTOR", actor}]
           ) do
      try do
        case app_server.run_turn(session, prompt, issue, on_message: fn message -> send_update(recipient, issue, actor, message) end) do
          {:ok, _turn} -> :ok
          {:error, reason} -> {:error, reason}
        end
      after
        app_server.stop_session(session)
      end
    end
  end

  defp review_prompt(issue, role, cycle) do
    native_ref = issue.native_ref || %{}
    run_id = native_ref["runId"]
    attempt_id = native_ref["attemptId"]

    """
    You are the independent BOS #{role} reviewer for #{issue.identifier}, cycle #{cycle}.
    Inspect the issue acceptance contract, repository instructions, current diff,
    exact git HEAD, tests and existing evidence. Do not modify files, commits,
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
    reviews
    |> Enum.map(fn review ->
      "#{review["reviewType"]}: #{review["status"]} — #{review["summary"]}\n#{inspect(review["findings"] || [])}"
    end)
    |> Enum.join("\n")
  end

  defp send_update(recipient, %Issue{id: issue_id}, actor, message)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:codex_worker_update, issue_id, Map.put(message, :delivery_actor, actor)})
    :ok
  end

  defp send_update(_recipient, _issue, _actor, _message), do: :ok
end
