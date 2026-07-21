defmodule SymphonyElixir.PostApprovalCoordinator do
  @moduledoc """
  Continues an approved exact-HEAD delivery through merge, deployment evidence,
  runner-confirmed runtime probing, release, and terminal state.

  The verification agent may exercise browsers and repository test tooling, but
  it cannot authenticate the probe. Symphony reads the bounded handoff file and
  records it with the runner-only credential before the final release turn.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @probe_path ".bos-local/deployment-probe.json"
  @readiness_path ".bos-local/pull-request-readiness.json"

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword(), String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, recipient, opts, worker_host) do
    app_server = Keyword.get(opts, :app_server_module, AppServer)
    client = Keyword.get(opts, :game_api_client_module, Client)

    with :ok <- require_local_probe_handoff(worker_host),
         {:ok, readiness} <- prepare_readiness_intent(client, workspace, issue),
         :ok <- ensure_pull_request_ready(client, app_server, workspace, issue, recipient, worker_host, readiness),
         :ok <- prepare_probe_handoff(workspace),
         :ok <- run_verification_turn(app_server, workspace, issue, recipient, worker_host),
         {:ok, request} <- load_probe_request(workspace, issue),
         {:ok, receipt} <- client.record_runtime_probe(request),
         :ok <- require_confirmed_receipt(receipt),
         :ok <- run_release_turn(app_server, workspace, issue, recipient, worker_host) do
      verify_terminal_state(client, issue, request["probe"])
    end
  end

  defp prepare_readiness_intent(client, workspace, %Issue{native_ref: native_ref}) do
    repository_id = native_ref["repositoryId"]
    run_id = native_ref["runId"]

    with {:ok, run} <- client.fetch_run(repository_id, run_id),
         {:ok, identity} <- readiness_identity(native_ref, run) do
      load_or_create_readiness_handoff(workspace, identity)
    end
  end

  defp readiness_identity(native_ref, run) do
    head_sha = run["headCommit"]
    pull_request_number = run["pullRequestNumber"]
    run_id = native_ref["runId"]

    cond do
      not is_binary(head_sha) or head_sha == "" ->
        {:error, :readiness_head_missing}

      not is_integer(pull_request_number) or pull_request_number <= 0 ->
        {:error, :readiness_pull_request_missing}

      true ->
        {:ok,
         %{
           "schemaVersion" => 1,
           "operationId" => "pr_ready_#{run_id}_#{head_sha}",
           "repositoryId" => native_ref["repositoryId"],
           "issueNumber" => native_ref["issueNumber"],
           "runId" => run_id,
           "pullRequestNumber" => pull_request_number,
           "expectedHeadSha" => head_sha
         }}
    end
  end

  defp load_or_create_readiness_handoff(workspace, identity) do
    path = Path.join(workspace, @readiness_path)

    case File.read(path) do
      {:ok, content} ->
        with {:ok, handoff} when is_map(handoff) <- Jason.decode(content),
             true <- readiness_identity_matches?(handoff, identity) || {:error, :readiness_identity_changed} do
          {:ok, handoff}
        else
          {:error, reason} -> {:error, {:readiness_handoff_invalid, reason}}
          false -> {:error, {:readiness_handoff_invalid, :readiness_identity_changed}}
        end

      {:error, :enoent} ->
        handoff = Map.put(identity, "status", "pending")

        with :ok <- atomic_write(path, Jason.encode!(handoff)) do
          {:ok, handoff}
        end

      {:error, reason} ->
        {:error, {:readiness_handoff_invalid, reason}}
    end
  end

  defp ensure_pull_request_ready(client, _app_server, _workspace, _issue, _recipient, _worker_host, %{"status" => "confirmed"} = handoff) do
    confirm_authoritative_readiness(client, handoff)
  end

  defp ensure_pull_request_ready(client, app_server, workspace, issue, recipient, worker_host, readiness) do
    prompt = """
    You are the BOS pull-request readiness coordinator for #{issue.identifier}.
    Symphony durably recorded the exact readiness intent at #{@readiness_path}.
    Read it, then call bos_mark_pull_request_ready exactly for its operationId,
    runId, issueNumber, pullRequestNumber, and expectedHeadSha. Do not create a
    pull request, change code, request merge, approve, deploy, or use GitHub
    directly. The BOS operation is idempotent: if the PR is already ready,
    confirm its current state without a second provider mutation.

    After bos-mcp returns a durable receipt, replace the handoff atomically while
    preserving every identity field. For success set status `confirmed` and add
    pullRequest with number, headSha, state, and draft from the confirmed result,
    plus the complete receipt. For failure set status `rejected`, failureKind to
    exactly one of `stale_head`, `closed_pull_request`, or `provider_failure`, and
    preserve the returned error in failure. Never report confirmed unless the PR
    is open, non-draft, and still has the exact expected HEAD.
    """

    with :ok <- run_role(app_server, workspace, issue, worker_host, "pull-request-readiness-coordinator", prompt, recipient),
         {:ok, handoff} <- read_readiness_handoff(workspace, readiness),
         :ok <- readiness_outcome(handoff) do
      confirm_authoritative_readiness(client, handoff)
    end
  end

  defp read_readiness_handoff(workspace, identity) do
    path = Path.join(workspace, @readiness_path)

    with {:ok, content} <- File.read(path),
         {:ok, handoff} when is_map(handoff) <- Jason.decode(content),
         true <- readiness_identity_matches?(handoff, identity) || {:error, :readiness_identity_changed} do
      {:ok, handoff}
    else
      {:error, reason} -> {:error, {:readiness_handoff_invalid, reason}}
      false -> {:error, {:readiness_handoff_invalid, :readiness_identity_changed}}
    end
  end

  defp readiness_outcome(%{"status" => "confirmed"} = handoff), do: validate_confirmed_readiness(handoff)

  defp readiness_outcome(%{"status" => "rejected", "failureKind" => kind, "failure" => failure})
       when kind in ["stale_head", "closed_pull_request", "provider_failure"],
       do: {:error, {:pull_request_readiness_rejected, kind, failure}}

  defp readiness_outcome(handoff), do: {:error, {:pull_request_readiness_unconfirmed, handoff["status"]}}

  defp validate_confirmed_readiness(handoff) do
    pull_request = handoff["pullRequest"] || %{}

    if is_map(handoff["receipt"]) and
         pull_request["number"] == handoff["pullRequestNumber"] and
         pull_request["headSha"] == handoff["expectedHeadSha"] and
         pull_request["state"] == "open" and pull_request["draft"] == false do
      :ok
    else
      {:error, :pull_request_readiness_confirmation_invalid}
    end
  end

  defp confirm_authoritative_readiness(client, readiness) do
    with {:ok, receipt} <- client.mark_pull_request_ready(readiness),
         :ok <- validate_readiness_receipt(receipt),
         {:ok, pull_request} <-
           client.fetch_pull_request(readiness["repositoryId"], readiness["pullRequestNumber"]) do
      validate_current_pull_request(pull_request, readiness)
    end
  end

  defp validate_readiness_receipt(%{"status" => "completed", "receipt" => receipt}) when is_map(receipt), do: :ok
  defp validate_readiness_receipt(other), do: {:error, {:pull_request_readiness_not_confirmed, other}}

  defp validate_current_pull_request(pull_request, readiness) do
    if pull_request["number"] == readiness["pullRequestNumber"] and
         get_in(pull_request, ["head", "sha"]) == readiness["expectedHeadSha"] and
         pull_request["state"] == "open" and pull_request["draft"] == false do
      :ok
    else
      {:error, {:pull_request_readiness_current_state_invalid, pull_request}}
    end
  end

  defp readiness_identity_matches?(left, right) do
    Enum.all?(
      ~w(schemaVersion operationId repositoryId issueNumber runId pullRequestNumber expectedHeadSha),
      &(left[&1] == right[&1])
    )
  end

  defp atomic_write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.write(temporary, content, [:binary, :sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:readiness_handoff_write_failed, reason}}
    end
  end

  defp run_verification_turn(app_server, workspace, issue, recipient, worker_host) do
    prompt = """
    You are the BOS post-approval deployment verifier for #{issue.identifier}.
    The human Approval is durable. Re-read the exact PR HEAD, approval and
    evidence through bos-mcp. Symphony has confirmed that the exact AgentRun PR
    is open and ready for review. Request the policy-checked merge; never force it.
    Perform the repository's real deployment or rollback workflow for that exact
    commit, create the GitHub Deployment through bos-mcp, and invoke the matching
    Vercel or VPS provider inspection. Against the real external URL, execute the
    health/version check, smoke tests, critical functional tests, browser console
    and network inspection, server/runtime diagnostics, dependency checks, and a
    stability observation. A provider READY or successful script alone is not a
    pass. Use the actual tools and preserve their command evidence.

    After the checks, write only the structured DeploymentRuntimeProbe object to
    #{@probe_path}. It must include probeId, deploymentId, repositoryId, exact
    commitSha, environment, target, status, startedAt, completedAt,
    externalAvailability, deployedVersion, runtimeHealth, smokeTests,
    functionalTests, browserDiagnostics, serverDiagnostics,
    criticalDependencies, stability, residualRisk, and evidenceReferences.
    Do not call the runner-only probe endpoint, record final DeploymentVerification,
    create a Release, or mark the Issue done. If verification fails, encode the
    real failed status and evidence; never manufacture a passed result.
    """

    run_role(app_server, workspace, issue, worker_host, "deployment-verifier", prompt, recipient)
  end

  defp run_release_turn(app_server, workspace, issue, recipient, worker_host) do
    prompt = """
    You are the BOS release manager for #{issue.identifier}. Symphony has now
    persisted the runner-authenticated DeploymentRuntimeProbe. Retrieve that
    probe and the provider inspection through bos-mcp. Record the final
    DeploymentVerification only when their exact commit, deployment, environment,
    provider result and runtime fields agree. Only a passed verification may
    complete the Deployment or Release. Create the GitHub Release when required,
    record learnings, finalize the AgentRun and Attempt, and transition the Issue
    from agent:merging to agent:done. On any mismatch or failed/inconclusive probe,
    diagnose and perform only the controlled retry or rollback allowed by policy;
    every rollback requires a new full verification. Never fabricate evidence or
    bypass the human Approval and exact-HEAD checks.
    """

    run_role(app_server, workspace, issue, worker_host, "release-manager", prompt, recipient)
  end

  defp load_probe_request(workspace, %Issue{native_ref: native_ref}) do
    path = Path.join(workspace, @probe_path)

    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular || {:error, :probe_handoff_not_regular},
         true <- stat.size <= 1_000_000 || {:error, :probe_handoff_too_large},
         {:ok, content} <- File.read(path),
         {:ok, probe} when is_map(probe) <- Jason.decode(content),
         :ok <- validate_probe_identity(probe, native_ref) do
      {:ok,
       %{
         "operationId" => "runtime_probe_#{probe["probeId"]}",
         "repository" => %{
           "repositoryId" => native_ref["repositoryId"],
           "owner" => native_ref["repositoryOwner"],
           "repo" => native_ref["repositoryName"]
         },
         "issueNumber" => native_ref["issueNumber"],
         "runId" => native_ref["runId"],
         "probe" => probe
       }}
    else
      false -> {:error, :probe_handoff_invalid}
      {:error, reason} -> {:error, {:probe_handoff_invalid, reason}}
    end
  end

  defp validate_probe_identity(probe, native_ref) do
    cond do
      probe["repositoryId"] != native_ref["repositoryId"] -> {:error, :repository_mismatch}
      not is_binary(probe["probeId"]) or probe["probeId"] == "" -> {:error, :probe_id_missing}
      not is_binary(probe["deploymentId"]) or probe["deploymentId"] == "" -> {:error, :deployment_id_missing}
      not is_binary(probe["commitSha"]) -> {:error, :commit_missing}
      probe["status"] not in ["passed", "failed", "inconclusive", "cancelled"] -> {:error, :status_invalid}
      true -> :ok
    end
  end

  defp prepare_probe_handoff(workspace) do
    case File.rm(Path.join(workspace, @probe_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:probe_handoff_cleanup_failed, reason}}
    end
  end

  defp verify_terminal_state(client, %Issue{native_ref: native_ref}, probe) do
    repository_id = native_ref["repositoryId"]
    issue_number = native_ref["issueNumber"]
    run_id = native_ref["runId"]

    with {:ok, issue} <- client.fetch_issue(repository_id, issue_number),
         true <- "agent:done" in (issue["labels"] || []) || {:error, :issue_not_done},
         {:ok, run} <- client.fetch_run(repository_id, run_id),
         true <- run["status"] == "completed" || {:error, :run_not_completed},
         {:ok, verifications} <- client.fetch_run_artifacts(repository_id, run_id, "deployment-verifications"),
         :ok <- require_exact_passed_verification(verifications, probe),
         {:ok, attempts} <- client.fetch_run_artifacts(repository_id, run_id, "attempts"),
         :ok <- require_completed_attempt(attempts, run["currentAttemptId"]),
         {:ok, learnings} <- client.fetch_run_artifacts(repository_id, run_id, "learnings"),
         true <- learnings != [] || {:error, :learning_missing} do
      :ok
    else
      {:error, reason} -> {:error, {:terminal_delivery_not_confirmed, reason}}
      false -> {:error, {:terminal_delivery_not_confirmed, :invalid_terminal_state}}
    end
  end

  defp require_exact_passed_verification(verifications, probe) do
    matched =
      Enum.any?(verifications, fn verification ->
        verification["status"] == "passed" and
          verification["deploymentId"] == probe["deploymentId"] and
          verification["commitSha"] == probe["commitSha"] and
          verification["environment"] == probe["environment"]
      end)

    if matched, do: :ok, else: {:error, :exact_deployment_verification_missing}
  end

  defp require_completed_attempt(attempts, current_attempt_id) do
    completed =
      Enum.any?(attempts, fn attempt ->
        attempt["attemptId"] == current_attempt_id and
          attempt["status"] in ["passed", "failed", "cancelled", "blocked"] and
          not is_nil(attempt["completedAt"])
      end)

    if completed, do: :ok, else: {:error, :attempt_not_completed}
  end

  defp require_confirmed_receipt(%{"status" => "completed", "receipt" => receipt}) when is_map(receipt), do: :ok
  defp require_confirmed_receipt(other), do: {:error, {:runtime_probe_not_confirmed, other}}

  defp require_local_probe_handoff(nil), do: :ok
  defp require_local_probe_handoff(_worker_host), do: {:error, :remote_probe_handoff_not_supported}

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

  defp send_update(recipient, %Issue{id: issue_id}, actor, message)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:codex_worker_update, issue_id, Map.put(message, :delivery_actor, actor)})
    :ok
  end

  defp send_update(_recipient, _issue, _actor, _message), do: :ok
end
