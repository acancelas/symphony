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

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword(), String.t() | nil) :: :ok | {:error, term()}
  def run(workspace, %Issue{} = issue, recipient, opts, worker_host) do
    app_server = Keyword.get(opts, :app_server_module, AppServer)
    client = Keyword.get(opts, :game_api_client_module, Client)

    with :ok <- require_local_probe_handoff(worker_host),
         :ok <- run_verification_turn(app_server, workspace, issue, recipient, worker_host),
         {:ok, request} <- load_probe_request(workspace, issue),
         {:ok, receipt} <- client.record_runtime_probe(request),
         :ok <- require_confirmed_receipt(receipt) do
      run_release_turn(app_server, workspace, issue, recipient, worker_host)
    end
  end

  defp run_verification_turn(app_server, workspace, issue, recipient, worker_host) do
    prompt = """
    You are the BOS post-approval deployment verifier for #{issue.identifier}.
    The human Approval is durable. Re-read the exact PR HEAD, approval and
    evidence through bos-mcp. Request the policy-checked merge; never force it.
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
