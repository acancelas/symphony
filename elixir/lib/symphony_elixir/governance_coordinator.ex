defmodule SymphonyElixir.GovernanceCoordinator do
  @moduledoc """
  Opt-in committee driver over the existing game-api Issue projection and bos-mcp
  artifact tools. Only durable readbacks advance gates. Transport/technical failures
  return to the existing scheduler without opening a new committee round or budget.
  """
  alias SymphonyElixir.{CandidateHead, GovernanceCatalog, GovernanceSession}
  alias SymphonyElixir.GameApi.Client

  @read_tools ~w(bos_get_project_context bos_get_delivery_context bos_get_issue bos_get_delivery_run bos_get_goal_execution bos_get_run_history bos_get_evidence)
  @coordinator_tools @read_tools ++ ~w(bos_record_governance)
  @review_tools @read_tools ++ ~w(bos_record_review bos_record_governance)
  @arbiter_tools @read_tools ++ ~w(bos_record_governance)

  def enabled?(issue, opts) do
    native = issue.native_ref || %{}
    Keyword.get(opts, :governance_enabled, false) or is_map(native["governance"])
  end

  def run(phase, workspace, issue, recipient, opts, worker_host) when phase in [:planning, :implementation] do
    if enabled?(issue, opts) do
      config = Application.get_env(:symphony_elixir, :governance, [])

      context = %{
        workspace: workspace,
        issue: issue,
        recipient: recipient,
        worker_host: worker_host,
        phase: Atom.to_string(phase),
        client: Keyword.get(opts, :game_api_client_module, Client),
        broker: Keyword.get(opts, :governance_session_broker, config[:session_broker]),
        catalog_path: Keyword.get(opts, :governance_catalog_path, config[:catalog_path]),
        candidate_head: Keyword.get(opts, :candidate_head_module, CandidateHead),
        require_ready: Keyword.get(opts, :governance_require_ready, true)
      }

      with :ok <- GovernanceSession.available?(context),
           {:ok, catalog} <- GovernanceCatalog.load(context.catalog_path),
           context = Map.put(context, :catalog, catalog),
           {:ok, candidate, manifest} <- prepare_candidate(context),
           {:ok, state} <- read_state(context) do
        context = Map.merge(context, %{catalog: catalog, manifest: manifest, sha: candidate.head_sha})
        planning = get_in(state, ["phases", "planning"])

        context =
          if phase == :planning and is_map(planning) and planning["planHash"] == manifest["planHash"] and planning["catalogCommitSha"] == GovernanceCatalog.commit(),
            do: %{context | sha: planning["candidateCommitSha"]},
            else: context

        convene(context, state)
      end
    else
      :ok
    end
  end

  defp prepare_candidate(context) do
    with {:ok, candidate} <- context.candidate_head.confirm(context.workspace, context.issue, context.worker_host) do
      case read_manifest(context, candidate.head_sha) do
        {:ok, manifest} ->
          {:ok, candidate, manifest}

        {:error, :governance_manifest_unverified} ->
          prompt =
            "Prepare the versioned BOS dossier for Issue #{context.issue.native_ref["issueNumber"]} from original BOS scope and acceptance criteria. Write docs/issues/{issueNumber}/plan.md and manifest.json with issueNumber, planHash sha256 of exact plan bytes, catalogCommitSha #{GovernanceCatalog.commit()}, scope, acceptanceCriteria and requirement IDs. Preserve concurrent requirements. Do not implement product code or approve. Validate and publish a clean issue-branch candidate through existing governed operations."

          policy = %{sandbox: %{"type" => "workspaceWrite", "networkAccess" => false}, tools: @read_tools, verified_m2m: true, fresh_session: true, check_goal_authorization: true}

          with :ok <- GovernanceSession.run(context, "task-orchestrator", prompt, policy),
               {:ok, next} <- context.candidate_head.confirm(context.workspace, context.issue, context.worker_host),
               {:ok, manifest} <- read_manifest(context, next.head_sha) do
            {:ok, next, manifest}
          end
      end
    end
  end

  defp read_manifest(context, sha) do
    number = context.issue.native_ref["issueNumber"]
    path = "docs/issues/#{number}"

    with {bytes, 0} <- System.cmd("git", ["-C", context.workspace, "show", "#{sha}:#{path}/manifest.json"], stderr_to_stdout: true),
         {:ok, manifest} <- Jason.decode(bytes),
         {plan, 0} <- System.cmd("git", ["-C", context.workspace, "show", "#{sha}:#{path}/plan.md"], stderr_to_stdout: true),
         true <- manifest["issueNumber"] == number,
         true <- manifest["catalogCommitSha"] == GovernanceCatalog.commit(),
         true <- manifest["planHash"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, plan), case: :lower) do
      {:ok, manifest}
    else
      _ -> {:error, :governance_manifest_unverified}
    end
  end

  defp read_state(context) do
    native = context.issue.native_ref

    case context.client.fetch_issue(native["repositoryId"], native["issueNumber"]) do
      {:ok, %{"governance" => state}} when is_map(state) -> {:ok, state}
      {:ok, _} -> {:error, :governance_projection_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current(context, state), do: get_in(state, ["phases", context.phase])
  defp version(context), do: %{"planHash" => context.manifest["planHash"], "catalogCommitSha" => GovernanceCatalog.commit(), "candidateCommitSha" => context.sha}
  defp matches?(context, phase) when is_map(phase), do: Enum.all?(version(context), fn {k, v} -> phase[k] == v end)
  defp matches?(_, _), do: false

  @doc false
  def resume(context, state), do: convene(context, state)

  defp convene(context, state) do
    phase = current(context, state)

    cond do
      not matches?(context, phase) ->
        with {:ok, next} <- record(context, "task-orchestrator", "candidate", 0, "Register exact candidate; preserve issue counters and Goal consumption.", &matches?(context, current(context, &1))) do
          convene(context, next)
        end

      passed?(phase) ->
        finish(context, state)

      is_map(phase["verdict"]) ->
        verdict_result(context, phase)

      phase["round"] == 0 ->
        start_round(context, state)

      true ->
        review_round(context, state)
    end
  end

  defp start_round(context, state) do
    round = get_in(state, ["counters", context.phase]) + 1
    phase = current(context, state)

    cond do
      round > 3 ->
        {:error, :governance_committee_exhausted}

      round == 3 and not is_map(phase["exception"]) ->
        with {:ok, next} <-
               record(
                 context,
                 "governance-arbiter",
                 "exception",
                 3,
                 "Evaluate whether a third exceptional committee round is warranted. Only persist an exception if independently justified with concrete evidence and at least 20 characters of rationale. Exhaustion is never approval. Do not convene the round yourself or invent a justification.",
                 &is_map(get_in(&1, ["phases", context.phase, "exception"]))
               ) do
          start_round(context, next)
        end

      true ->
        with {:ok, next} <-
               record(
                 context,
                 "task-orchestrator",
                 "round_started",
                 round,
                 "Convene committee using the issue-wide round counter, independent of Attempts.",
                 &(get_in(&1, ["phases", context.phase, "round"]) == round)
               ) do
          review_round(context, next)
        end
    end
  end

  defp review_round(context, state) do
    result =
      Enum.reduce_while(context.catalog["committee"], {:ok, state}, fn role, {:ok, latest} ->
        phase = current(context, latest)

        if is_map(phase["votes"][role["id"]]) do
          {:cont, {:ok, latest}}
        else
          detail =
            "Evaluate applicability first. Persist a justified NOT_APPLICABLE (applicable=false), or record a version-bound Review and applicability with applicable=true, matching status and reviewIds. Missing mandatory evidence is UNVERIFIED. Use original evidence; never invent a review or authority.\nCanonical role definition: #{Jason.encode!(role)}"

          case record(context, role["id"], "applicability", phase["round"], detail, &is_map(get_in(&1, ["phases", context.phase, "votes", role["id"]]))) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
        end
      end)

    with {:ok, latest} <- result,
         round = current(context, latest)["round"],
         {:ok, decided} <-
           record(
             context,
             "governance-arbiter",
             "verdict",
             round,
             "Independently resolve all ten applicability decisions, original Reviews and evidence. Use canonical phase verdicts with matching status. Never waive a critical defect or mandatory UNVERIFIED requirement. Include all required evidenceIds for implementation. Canonical role: #{Jason.encode!(Enum.find(context.catalog["roles"], &(&1["id"] == "governance-arbiter")))}",
             &is_map(get_in(&1, ["phases", context.phase, "verdict"]))
           ) do
      convene(context, decided)
    end
  end

  defp verdict_result(context, phase) do
    case phase["verdict"]["verdict"] do
      verdict when verdict in ["REVISION_REQUIRED", "CHANGES_REQUIRED"] ->
        repair(context, phase)

      verdict ->
        {:error, {:governance_decision_required, verdict, phase["verdict"]}}
    end
  end

  defp repair(context, phase) do
    if phase["round"] >= 3 do
      {:error, :governance_committee_exhausted}
    else
      policy = %{
        sandbox: %{"type" => "workspaceWrite", "networkAccess" => false},
        tools: @read_tools,
        verified_m2m: true,
        fresh_session: true,
        check_goal_authorization: true,
        task_kind: :derived_repair
      }

      prompt =
        "Repair only the approved acceptance criteria from this durable verdict: #{Jason.encode!(phase["verdict"])}. Preserve this Issue/Run, Goal authorization, aggregate budgets, branch and evidence. Update the versioned plan dossier for planning revisions. Run required validation and publish a clean exact candidate through the existing governed contract; no merge or production."

      with :ok <- GovernanceSession.run(context, "task-orchestrator", prompt, policy),
           {:ok, candidate} <- context.candidate_head.confirm(context.workspace, context.issue, context.worker_host),
           {:ok, manifest} <- read_manifest(context, candidate.head_sha),
           true <- candidate.head_sha != context.sha,
           true <- context.phase != "planning" or manifest["planHash"] != context.manifest["planHash"],
           {:ok, state} <- read_state(context) do
        convene(%{context | sha: candidate.head_sha, manifest: manifest}, state)
      else
        false -> {:error, :governance_repair_did_not_change_candidate}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp passed?(phase), do: get_in(phase, ["verdict", "status"]) == "passed"

  defp finish(%{phase: "planning", require_ready: false}, _state), do: :ok

  defp finish(%{phase: "planning"} = context, state) do
    if matches?(context, state["readiness"]) do
      :ok
    else
      with {:ok, _} <-
             record(
               context,
               "task-orchestrator",
               "readiness",
               current(context, state)["round"],
               "Check inherited Goal authorization, aggregate budgets, dependencies and execution window via existing BOS contracts. Persist READY only if authorized; then continue automatically without generic confirmation.",
               &matches?(context, &1["readiness"])
             ) do
        :ok
      end
    end
  end

  defp finish(%{phase: "implementation"}, _state), do: :ok

  defp record(context, role, event, round, detail, confirmed?) do
    key = [context.issue.native_ref["runId"], context.phase, event, round, context.sha, context.manifest["planHash"], role] |> Jason.encode!()
    id = "gov_" <> Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    artifact = Map.merge(version(context), %{"governanceId" => id, "runId" => context.issue.native_ref["runId"], "phase" => context.phase, "event" => event, "round" => round})

    prompt = """
    Recover BOS Issue #{context.issue.native_ref["issueNumber"]} and the existing AgentRun.
    #{detail}
    Use bos_record_governance with issueNumber #{context.issue.native_ref["issueNumber"]}, operationId #{id}, runId #{context.issue.native_ref["runId"]}.
    Required artifact base: #{Jason.encode!(artifact)}. Add a concise summary and the event-specific top-level fields. No payload, actor or role fields: authority is server-derived.
    Reuse existing IDs/receipts; never reset Goal budgets or committee counters on technical/transport recovery. Do not implement, merge, deploy, or grant permissions. End only after durable confirmation.
    """

    tools =
      cond do
        role == "task-orchestrator" -> @coordinator_tools
        role == "governance-arbiter" -> @arbiter_tools
        true -> @review_tools
      end

    policy = %{
      sandbox: %{"type" => "readOnly", "networkAccess" => false},
      tools: tools,
      verified_m2m: true,
      fresh_session: true,
      check_goal_authorization: true,
      independent_of_executor: role != "task-orchestrator"
    }

    with :ok <- GovernanceSession.run(context, role, prompt, policy),
         {:ok, state} <- read_state(context),
         true <- confirmed?.(state) do
      {:ok, state}
    else
      false -> {:error, {:governance_receipt_missing, event, role, id}}
      {:error, reason} -> {:error, reason}
    end
  end
end
