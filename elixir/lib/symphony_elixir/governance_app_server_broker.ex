defmodule SymphonyElixir.GovernanceAppServerBroker do
  @moduledoc "Concrete host broker: private BOS MCP transport, server-bound invocation, pinned native AppServer and scoped source tools."
  @behaviour SymphonyElixir.GovernanceSession
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.GovernanceCatalog
  alias SymphonyElixir.GovernanceHostStore
  alias SymphonyElixir.GovernancePrivateMcp
  alias SymphonyElixir.GovernanceRuntime
  alias SymphonyElixir.GovernanceSourceTools
  alias SymphonyElixir.GovernanceToolBoundary
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Tracker.Issue

  @doc false
  @spec host_read(map(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def host_read(context, tool, arguments)
      when tool in ~w(bos_get_issue bos_get_goal_planning bos_get_goal_execution bos_get_delivery_run) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, "task-orchestrator", configuration),
         {:ok, _, principal} <- effective(cached, context, "task-orchestrator", configuration),
         {:ok, arguments} <-
           GovernanceToolBoundary.arguments(tool, arguments, Map.put(context, :principal, principal), [tool]),
         {:ok, raw} <- GovernancePrivateMcp.call(cached.client, tool, arguments),
         {:ok, value} <- GovernanceToolBoundary.decode_result(raw) do
      {:ok, GovernanceToolBoundary.safe_output(value)}
    end
  end

  @doc "Trusted snapshot collector callback; raw text never enters model output or general host_read."
  @spec host_snapshot_read(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def host_snapshot_read(context, tool, arguments) do
    with {:ok, _} <- GovernanceToolBoundary.snapshot_read_arguments(tool, arguments, context),
         {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, "task-orchestrator", configuration),
         {:ok, _, principal} <- effective(cached, context, "task-orchestrator", configuration),
         bound = Map.put(context, :principal, principal),
         {:ok, arguments} <- GovernanceToolBoundary.snapshot_read_arguments(tool, arguments, bound),
         {:ok, raw} when is_map(raw) <- GovernancePrivateMcp.call(cached.client, tool, arguments),
         true <- raw["isError"] != true do
      {:ok, raw}
    else
      _ -> {:error, :governance_snapshot_raw_read_unconfirmed}
    end
  end

  @doc false
  @spec reserve_existing_run(map(), map()) :: :ok | {:error, term()}
  def reserve_existing_run(context, run) do
    with true <- SymphonyElixir.GovernanceReservation.run_matches?(context, run),
         {:ok, source} <-
           host_read(context, "bos_get_issue", %{"issueNumber" => context.issue.native_ref["issueNumber"]}) do
      case SymphonyElixir.GovernanceReservation.verify(context, run, source) do
        :ok -> :ok
        {:error, _} -> request_reservation(context, run)
      end
    else
      _ -> {:error, :governance_existing_run_reservation_denied}
    end
  end

  defp request_reservation(context, run) do
    native = context.issue.native_ref

    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, "task-orchestrator", configuration),
         {:ok, _, _} <- effective(cached, context, "task-orchestrator", configuration),
         operation =
           "governance-intake-" <>
             Base.encode16(
               :crypto.hash(
                 :sha256,
                 Jason.encode!([
                   native["repositoryId"],
                   native["runId"],
                   cached.invocation_id,
                   cached.reservation_bucket
                 ])
               ),
               case: :lower
             ),
         lease = DateTime.to_iso8601(DateTime.from_unix!(cached.reservation_bucket + 3600)),
         {:ok, raw} <-
           GovernancePrivateMcp.call(cached.client, "bos_claim_issue", %{
             "issueNumber" => native["issueNumber"],
             "runId" => native["runId"],
             "runnerId" => get_in(run, ["runner", "id"]),
             "operationId" => operation,
             "leaseExpiresAt" => lease
           }),
         {:ok, result} <- GovernanceToolBoundary.decode_result(raw),
         {:ok, source} <- host_read(context, "bos_get_issue", %{"issueNumber" => native["issueNumber"]}),
         :ok <- SymphonyElixir.GovernanceReservation.verify_response(result, context, run, source) do
      :ok
    else
      _ -> {:error, :governance_existing_run_reservation_denied}
    end
  end

  @doc "Observe and register readiness evidence on the host before any model readiness turn."
  @spec prepare_readiness(map()) :: {:ok, String.t()} | {:error, term()}
  def prepare_readiness(context) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, "task-orchestrator", configuration),
         {:ok, source, principal} <- effective(cached, context, "task-orchestrator", configuration),
         {:ok, run_raw} <-
           GovernancePrivateMcp.call(cached.client, "bos_get_delivery_run", %{
             "runId" => context.issue.native_ref["runId"]
           }),
         {:ok, run} <- GovernanceToolBoundary.decode_result(run_raw),
         {:ok, artifact} <- SymphonyElixir.GovernanceHostEvidence.observe(context, configuration, source, run),
         bound =
           context
           |> Map.put(:principal, principal)
           |> Map.put(:host_observed_evidence, %{artifact["evidenceId"] => artifact}),
         {:ok, args} <-
           GovernanceToolBoundary.arguments(
             "bos_record_evidence",
             %{
               "issueNumber" => context.issue.native_ref["issueNumber"],
               "runId" => context.issue.native_ref["runId"],
               "operationId" => artifact["evidenceId"],
               "artifact" => artifact
             },
             bound,
             ["bos_record_evidence"]
           ),
         {:ok, raw} <-
           observed_mcp_call(cached, bound, "task-orchestrator", configuration, "bos_record_evidence", args),
         {:ok, %{"status" => "completed"}} <- GovernanceToolBoundary.decode_result(raw),
         {:ok, evidence_raw} <-
           GovernancePrivateMcp.call(cached.client, "bos_get_evidence", %{
             "runId" => context.issue.native_ref["runId"]
           }),
         {:ok, evidence} <- GovernanceToolBoundary.decode_result(evidence_raw),
         true <-
           Enum.any?(
             evidence["artifacts"] || [],
             &(&1["evidenceId"] == artifact["evidenceId"] and &1["commitSha"] == context.sha and
                 &1["status"] == "passed")
           ),
         {:ok, _fresh, ^principal} <- effective(cached, context, "task-orchestrator", configuration),
         {:ok, _snapshot} <-
           SymphonyElixir.GovernanceObservedSnapshot.refresh(
             bound,
             Map.get(configuration, :observed_snapshot),
             configuration.execution,
             fn tool, args -> host_snapshot_read(bound, tool, args) end
           ) do
      {:ok, artifact["evidenceId"]}
    else
      _ -> {:error, :governance_host_readiness_evidence_unconfirmed}
    end
  after
    release(context, "task-orchestrator")
  end

  @spec prepare_context(map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare_context(context, policy), do: SymphonyElixir.GovernanceHostContext.prepare(context, policy)

  @spec identity(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def identity(context, role) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, role, configuration),
         {:ok, source, principal} <- effective(cached, context, role, configuration) do
      Process.put(key(context, role), %{cached | source: source, principal: principal})
      {:ok, principal}
    end
  end

  @spec capabilities(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def capabilities(_context, _role) do
    with {:ok, configuration} <- configuration(),
         :ok <- GovernanceRuntime.validate(configuration.runtime) do
      {:ok,
       %{
         read_only: :enforced,
         tool_allowlist: :enforced,
         minimal_environment: :enforced,
         read_roots: :enforced,
         private_mcp_credentials: :enforced
       }}
    end
  end

  @spec run(map(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def run(context, role, prompt, policy) do
    with {:ok, _} <- execute(context, role, prompt, policy, nil), do: :ok
  end

  @spec draft(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def draft(context, prompt, policy) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "plan" => %{"type" => "string"},
        "manifest" => %{
          "type" => "object",
          "properties" => %{
            "scope" => %{"type" => "array", "items" => %{"type" => "string"}},
            "acceptanceCriteria" => %{"type" => "array", "items" => %{"type" => "string"}},
            "requirements" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["scope", "acceptanceCriteria", "requirements"],
          "additionalProperties" => false
        }
      },
      "required" => ["plan", "manifest"],
      "additionalProperties" => false
    }

    with {:ok, text} <- execute(context, "task-orchestrator", prompt, policy, schema),
         {:ok, draft} when is_map(draft) <- Jason.decode(text) do
      {:ok, draft}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :governance_draft_result_invalid}
    end
  end

  @spec release(map(), String.t()) :: :ok
  def release(context, role) do
    repository = context.issue.native_ref["repositoryId"]
    run = context.issue.native_ref["runId"]
    workspace = context.workspace

    Process.get()
    |> Enum.each(fn
      {{__MODULE__, ^repository, ^run, ^workspace, ^role, _, _, _} = connection_key, %{client: client}} ->
        Process.delete(connection_key)
        GovernancePrivateMcp.close(client)

      _ ->
        :ok
    end)

    case Process.get({__MODULE__, :active_execution}) do
      %{binding: %{"runId" => ^run}} = execution ->
        case configuration() do
          {:ok, config} -> close_execution(config, execution)
          _ -> SymphonyElixir.GovernanceHostStore.release(execution.ownership.lease)
        end

      _ ->
        :ok
    end

    :ok
  end

  defp original_policies(context, runtime, %{sandbox: %{"type" => "workspaceWrite"}}) do
    if runtime[:policy_fallback_filenames] == [],
      do: PromptBuilder.governed_policy_material(context, runtime),
      else: {:error, :governance_custom_policy_fallback_profile_not_certified}
  end

  defp original_policies(_, _, _), do: {:ok, nil}

  defp original_policy_prompt(nil), do: ""

  defp original_policy_prompt(material) do
    "This worker is an already launched role of the existing governed controller, not interactive task entry. Do not launch a nested controller. Original policies follow in full, applying to their recorded source scopes.\n\n" <>
      material.prompt <> "\n\n"
  end

  defp original_policy_preflight(_, _, _, _, nil, _, _), do: :ok

  defp original_policy_preflight(port, response, context, configuration, material, prompt, launch) do
    actual = Map.take(response, ~w(activePermissionProfile approvalPolicy sandbox runtimeWorkspaceRoots cwd instructionSources))
    profile = get_in(launch.thread_parameters, ["config", "permissions", "bos-implementation"])

    roots =
      profile["filesystem"][":workspace_roots"]
      |> Enum.filter(fn {_, access} -> access == "write" end)
      |> Enum.map(fn {path, _} -> Path.expand(path, context.workspace) end)
      |> Enum.sort()

    with {:ok, ^material} <- PromptBuilder.governed_policy_material(context, configuration.runtime),
         :ok <- original_policy_config(port),
         true <- original_policy_scope?(actual, launch.workspace, roots, material),
         witness when is_map(witness) <- Process.get({__MODULE__, :execution_witness}),
         thread when is_binary(thread) and byte_size(thread) > 0 <- get_in(response, ["thread", "id"]) do
      record = %{
        "kind" => "primary_original_policy_premodel_scope",
        "repositoryId" => context.issue.native_ref["repositoryId"],
        "issueNumber" => context.issue.native_ref["issueNumber"],
        "runId" => context.issue.native_ref["runId"],
        "invocationId" => context.principal.invocation_id,
        "planHash" => context.manifest["planHash"],
        "nativeProcessWitness" => witness,
        "nativeExecutableSha256" => configuration.runtime.executable_sha256,
        "nativeConfigSha256" => configuration.runtime.native_config_sha256,
        "recipeSha256" => SymphonyElixir.GovernanceWorkspaceProfile.recipe_sha256(),
        "candidateCommitSha" => context.sha,
        "nativeThreadId" => thread,
        "actualThreadResponse" => actual,
        "policyManifest" => material.manifest,
        "policyManifestSha256" => material.digest,
        "promptSha256" => Base.encode16(:crypto.hash(:sha256, prompt), case: :lower),
        "observedAt" => DateTime.to_iso8601(DateTime.utc_now()),
        "recordedBeforeModel" => true
      }

      persist_policy_observation(configuration.execution, record)
    else
      _ -> {:error, :governance_original_policy_premodel_scope_rejected}
    end
  end

  defp original_policy_config(port) do
    with {:ok, %{"config" => effective}} <- AppServer.host_request(port, "config/read", %{"includeLayers" => false}),
         true <- effective["project_doc_max_bytes"] == 0 and effective["project_doc_fallback_filenames"] == [],
         do: :ok
  end

  defp original_policy_scope?(actual, workspace, roots, material) do
    expected = %{
      "activePermissionProfile" => %{"id" => "bos-implementation", "extends" => nil},
      "approvalPolicy" => "never",
      "cwd" => workspace,
      "runtimeWorkspaceRoots" => [workspace],
      "instructionSources" => [hd(material.manifest)["path"]]
    }

    sandbox = %{
      "type" => "workspaceWrite",
      "networkAccess" => false,
      "excludeSlashTmp" => true,
      "excludeTmpdirEnvVar" => true,
      "writableRoots" => roots
    }

    observed = actual["sandbox"] |> Map.take(Map.keys(sandbox)) |> Map.update!("writableRoots", &Enum.sort/1)
    Map.take(actual, Map.keys(expected)) == expected and observed == sandbox
  end

  defp persist_policy_observation(execution, record) do
    id = Base.encode16(:crypto.hash(:sha256, CanonicalJson.encode(record)), case: :lower)
    request = %{"kind" => "observation", "command" => "create", "id" => id, "record" => record}

    case GovernanceHostStore.request(execution, request) do
      {:ok, _} -> :ok
      _ -> {:error, :governance_original_policy_premodel_record_failed}
    end
  end

  defp execute(context, role, prompt, policy, schema) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, role, configuration),
         {:ok, source, principal} <- effective(cached, context, role, configuration),
         true <- principal == context.principal,
         {:ok, original_policies} <- original_policies(context, configuration.runtime, policy),
         {:ok, execution} <- execution_admission(cached, context, role, configuration, source, policy),
         {:ok, launch} <- GovernanceRuntime.launch(configuration.runtime, context, role, policy),
         launch = bind_execution_marker(launch, execution),
         {:ok, %{"tools" => tools}} <- GovernancePrivateMcp.request(cached.client, "tools/list", %{}),
         allowed = policy.tools,
         true <- is_list(allowed) and Enum.all?(allowed, fn name -> Enum.any?(tools, &(&1["name"] == name)) end) do
      prompt =
        original_policy_prompt(original_policies) <>
          native_execution_instruction(context, execution) <>
          "Canonical role definition from verified catalog #{GovernanceCatalog.commit()}: #{Jason.encode!(cached.role_definition)}\n" <>
          prompt

      selected =
        Enum.filter(tools, &(&1["name"] in allowed)) |> Enum.map(&Map.take(&1, ~w(name description inputSchema)))

      specs = selected ++ GovernanceSourceTools.specs()
      binding = %{tool_specs: specs, secret_environment_names: []}

      options = [
        managed_launch: launch.managed,
        dynamic_tool_binding: binding,
        thread_parameters: launch.thread_parameters,
        host_preflight: &execution_preflight(&1, cached, context, role, configuration, execution),
        host_thread_preflight: &original_policy_preflight(&1, &2, context, configuration, original_policies, prompt, launch)
      ]

      with {:ok, session} <- AppServer.start_session(launch.workspace, options) do
        monitor = start_execution_monitor(session, cached, context, role, configuration, execution)
        Process.put({__MODULE__, :final_text}, "")
        Process.put({__MODULE__, :native_status}, nil)

        try do
          executor = fn tool, args -> tool_result(cached, context, role, configuration, source, tool, args, allowed) end

          callback = fn message ->
            if is_pid(monitor), do: SymphonyElixir.GovernanceExecutionMonitor.usage(monitor, message[:payload])
            collect_text(message)

            if status = SymphonyElixir.GovernanceHostDiagnostics.terminal_status(message[:payload]),
              do: Process.put({__MODULE__, :native_status}, status)

            if is_pid(context.recipient),
              do:
                send(
                  context.recipient,
                  {:codex_worker_update, context.issue.id, Map.put(message, :delivery_actor, role)}
                )
          end

          case AppServer.run_turn(session, prompt, context.issue,
                 on_message: callback,
                 tool_executor: executor,
                 role: role,
                 output_schema: schema
               ) do
            {:ok, %{result: %{status: :budget_paused}}} ->
              {:error, :governance_turn_budget_paused}

            {:ok, _} ->
              if Process.get({__MODULE__, :native_status}) == "completed",
                do: finish_execution_turn(monitor, cached, context, role, configuration, execution),
                else: {:error, :governance_native_turn_not_completed}

            {:error, _} ->
              {:error, :governance_native_turn_failed}
          end
        after
          AppServer.stop_session(session)

          if is_pid(monitor) and Process.alive?(monitor) do
            case SymphonyElixir.GovernanceExecutionMonitor.finish(monitor) do
              {:ok, measurement} ->
                record_execution_observation(
                  cached,
                  context,
                  role,
                  configuration,
                  execution,
                  Process.get({__MODULE__, :execution_witness}),
                  measurement,
                  "cancelled"
                )

              _ ->
                :ok
            end
          end

          close_execution(configuration, execution)
          Process.delete({__MODULE__, :final_text})
          Process.delete({__MODULE__, :native_status})
        end
      end
    else
      false -> {:error, :governance_principal_or_toolset_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :governance_private_broker_unavailable}
    end
  end

  defp native_execution_instruction(_context, nil), do: ""

  defp native_execution_instruction(context, execution) do
    if context.issue.native_ref["repositoryId"] == "symphony" and context.issue.native_ref["issueNumber"] == 69 do
      marker = native_execution_marker(context, execution)

      "Required authorized reversible local execution proof: use the native workspace editing tools to write elixir/test/fixtures/bos_governance_native_execution.json with exactly this JSON object: #{Jason.encode!(marker)}. This fixture is an execution observation, never an approval or evidence grant. Do not edit policies, AGENTS, .codex, plan, manifest or request snapshots. The host runs fixed sandbox QA and publishes the candidate; do not write Git metadata, commit, push or self-report passing evidence.\n"
    else
      ""
    end
  end

  defp native_execution_marker(context, execution),
    do: %{
      "schemaVersion" => 1,
      "runId" => context.issue.native_ref["runId"],
      "planHash" => context.manifest["planHash"],
      "attemptId" => execution.attempt["attemptId"],
      "executionId" => execution.admission["executionId"]
    }

  defp verify_native_edit(context, execution) do
    path = Path.join(context.workspace, "elixir/test/fixtures/bos_governance_native_execution.json")

    with {:ok, %{type: :regular, links: 1}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, actual} <- Jason.decode(bytes),
         true <- actual == native_execution_marker(context, execution) do
      :ok
    else
      _ -> {:error, :governance_native_edit_not_observed}
    end
  end

  @doc "Publish only the exact tree that the host tested in the native sandbox."
  @spec publish_implementation(String.t(), Issue.t()) :: {:ok, map()} | {:error, atom()}
  def publish_implementation(workspace, issue) do
    with %{context: %{workspace: ^workspace} = previous, tree: tree, qa: qa, marker: marker} <-
           Process.get({__MODULE__, :host_qa}),
         true <- previous.issue.native_ref["runId"] == issue.native_ref["runId"],
         {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(previous, "task-orchestrator", configuration),
         {:ok, source, principal} <- effective(cached, previous, "task-orchestrator", configuration),
         {:ok, _} <-
           SymphonyElixir.GovernanceExecutionAuthority.check(Map.put(previous, :principal, principal), source),
         {:ok, candidate} <-
           SymphonyElixir.GovernanceCandidatePublication.publish(previous, tree, configuration.execution),
         context = %{previous | sha: candidate.head_sha},
         {:ok, current} <- connection(context, "task-orchestrator", configuration),
         {:ok, fresh, verified} <- effective(current, context, "task-orchestrator", configuration),
         context = Map.put(context, :principal, verified),
         {:ok, _} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, fresh),
         artifact = implementation_evidence(context, tree, qa, marker, configuration),
         {:ok, _} <-
           SymphonyElixir.GovernanceHostStore.request(configuration.execution, %{
             "kind" => "observation",
             "command" => "create",
             "id" => host_digest(artifact),
             "record" => artifact
           }),
         sealed = Map.put(context, :host_observed_evidence, %{artifact["evidenceId"] => artifact}),
         {:ok, args} <-
           GovernanceToolBoundary.arguments(
             "bos_record_evidence",
             %{
               "issueNumber" => issue.native_ref["issueNumber"],
               "runId" => issue.native_ref["runId"],
               "operationId" => artifact["evidenceId"],
               "artifact" => artifact
             },
             sealed,
             ["bos_record_evidence"]
           ),
         {:ok, raw} <-
           observed_mcp_call(current, sealed, "task-orchestrator", configuration, "bos_record_evidence", args),
         {:ok, %{"status" => "completed"}} <- GovernanceToolBoundary.decode_result(raw),
         {:ok, evidence_raw} <-
           GovernancePrivateMcp.call(current.client, "bos_get_evidence", %{"runId" => issue.native_ref["runId"]}),
         {:ok, evidence} <- GovernanceToolBoundary.decode_result(evidence_raw),
         true <-
           Enum.any?(
             evidence["artifacts"] || [],
             &(&1["evidenceId"] == artifact["evidenceId"] and &1["commitSha"] == candidate.head_sha and
                 &1["status"] == "passed")
           ) do
      Process.delete({__MODULE__, :host_qa})
      {:ok, candidate}
    else
      _ -> {:error, :governance_tested_candidate_unconfirmed}
    end
  after
    release(%{workspace: workspace, issue: issue}, "task-orchestrator")
  end

  defp implementation_evidence(context, tree, qa, marker, configuration) do
    %{
      "evidenceId" => "host_implementation_" <> host_digest([context.sha, tree, qa["outputSha256"], marker]),
      "runId" => context.issue.native_ref["runId"],
      "commitSha" => context.sha,
      "phase" => "implementation",
      "status" => "passed",
      "acceptanceCriteria" => [
        %{"name" => "Host-observed authorized native edit and complete fixed repository QA", "status" => "passed"}
      ],
      "checks" => [
        Map.drop(qa, ["output", "outputSha256"]),
        %{"kind" => "local_runtime", "status" => "passed", "healthy" => true, "environment" => "local"},
        %{
          "kind" => "local_functional_acceptance",
          "status" => "passed",
          "complete" => true,
          "environment" => "local",
          "functionalFlowStatus" => "passed",
          "commands" => ["host verified unique execution fixture and unchanged tested Git tree"]
        }
      ],
      "artifacts" => [
        %{"kind" => "host_sandbox_qa", "outputSha256" => qa["outputSha256"], "testedGitTree" => tree},
        %{"kind" => "native_execution_fixture", "sha256" => host_digest(marker)},
        %{"kind" => "implementation_profile_proof", "sha256" => configuration.runtime.implementation_proof_sha256}
      ],
      "summary" =>
        "Actual native fixture edit and fixed sandbox QA observed by the host on the exact published Git tree. These are evidence inputs; independent final acceptance and integration remain separate."
    }
  end

  defp execution_admission(_cached, _context, _role, _configuration, _source, %{sandbox: %{"type" => "readOnly"}}),
    do: {:ok, nil}

  defp execution_admission(cached, context, "task-orchestrator", configuration, source, %{
         sandbox: %{"type" => "workspaceWrite"}
       }) do
    started_ms = System.monotonic_time(:millisecond)

    with true <- is_map(configuration[:execution]),
         :ok <- GovernanceRuntime.validate_implementation(configuration.runtime),
         {:ok, authority} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, source),
         number = context[:attempt_number] || 1,
         id = "attempt_" <> host_digest([context.issue.native_ref["runId"], authority["baselineCommitSha"], number]),
         execution_id = "execution_" <> host_digest([id, context.sha]),
         worker_id = "worker_" <> host_digest([id, context.sha]),
         attempt = %{
           "attemptId" => id,
           "runId" => context.issue.native_ref["runId"],
           "number" => number,
           "phase" => "implementation",
           "status" => "running",
           "startedAt" => authority["lastObservedAt"],
           "metrics" => %{
             "developmentExecution" => %{
               "executionId" => execution_id,
               "workerId" => worker_id,
               "authorityGeneration" => authority["authorityGeneration"],
               "sourcePublicationId" => authority["sourcePublicationId"]
             }
           }
         },
         {:ok, args} <-
           GovernanceToolBoundary.arguments(
             "bos_start_attempt",
             %{
               "issueNumber" => context.issue.native_ref["issueNumber"],
               "runId" => context.issue.native_ref["runId"],
               "operationId" => id <> "_start",
               "artifact" => attempt
             },
             context,
             ["bos_start_attempt"]
           ),
         {:ok, raw} <- observed_mcp_call(cached, context, "task-orchestrator", configuration, "bos_start_attempt", args),
         {:ok, %{"status" => "completed", "developmentExecution" => admission}} <-
           GovernanceToolBoundary.decode_result(raw),
         true <-
           admission["attemptId"] == id and admission["executionId"] == execution_id and
             admission["workerId"] == worker_id and admission["launchAuthority"] == "host_journal_only",
         {:ok, fresh, _} <- effective(cached, context, "task-orchestrator", configuration),
         {:ok, _} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, fresh, admission),
         binding = SymphonyElixir.GovernanceExecutionJournal.binding(context, admission),
         {:ok, ownership} <- SymphonyElixir.GovernanceExecutionJournal.spawn_once(configuration.execution, binding) do
      execution = %{
        admission: admission,
        binding: binding,
        ownership: ownership,
        attempt: args["artifact"],
        started_ms: started_ms
      }

      Process.put({__MODULE__, :active_execution}, execution)
      {:ok, execution}
    else
      _ -> {:error, :governance_execution_admission_unconfirmed}
    end
  end

  defp execution_admission(_, _, _, _, _, _), do: {:error, :governance_execution_policy_rejected}

  defp bind_execution_marker(launch, nil), do: launch

  defp bind_execution_marker(launch, execution),
    do: put_in(launch, [:managed, :environment, "BOS_HOST_WORKER_MARKER"], execution.ownership.marker)

  defp execution_preflight(port, _cached, _context, _role, _configuration, nil), do: preflight(port)

  defp execution_preflight(port, cached, context, role, configuration, execution) do
    with :ok <- preflight(port),
         :ok <- execution_guard(cached, context, role, configuration, execution),
         {:ok, witness} <-
           SymphonyElixir.GovernanceExecutionJournal.attach(
             configuration.execution,
             execution.binding,
             port,
             execution.ownership
           ),
         :ok <-
           record_execution_observation(
             cached,
             context,
             role,
             configuration,
             execution,
             witness,
             %{
               sequence: 1,
               uncachedInputTokens: 0,
               wallTimeSeconds: div(max(System.monotonic_time(:millisecond) - execution.started_ms, 0), 1000),
               observedAt: DateTime.to_iso8601(DateTime.utc_now())
             },
             "attached"
           ),
         :ok <- execution_guard(cached, context, role, configuration, execution) do
      Process.put({__MODULE__, :execution_witness}, witness)
      :ok
    end
  end

  defp execution_guard(cached, context, role, configuration, execution) do
    with true <- SymphonyElixir.GovernanceHostStore.held?(execution.ownership.lease),
         {:ok, source, principal} <- effective(cached, context, role, configuration),
         true <- principal == context.principal,
         {:ok, _} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, source, execution.admission) do
      :ok
    else
      _ -> {:error, :governance_execution_authority_lost}
    end
  end

  defp start_execution_monitor(_session, _cached, _context, _role, _configuration, nil), do: nil

  defp start_execution_monitor(session, cached, context, role, configuration, execution) do
    witness = Process.get({__MODULE__, :execution_witness})
    validate = fn -> execution_guard(cached, context, role, configuration, execution) end

    observe = fn measurement ->
      record_execution_observation(cached, context, role, configuration, execution, witness, measurement, "running")
    end

    {:ok, monitor} =
      SymphonyElixir.GovernanceExecutionMonitor.start(
        session.port,
        execution.admission,
        validate,
        observe,
        execution.started_ms,
        session.thread_id
      )

    monitor
  end

  defp finish_execution_turn(_monitor, _cached, _context, _role, _configuration, nil),
    do: {:ok, Process.get({__MODULE__, :final_text}, "")}

  defp finish_execution_turn(monitor, cached, context, role, configuration, execution) do
    with :ok <- SymphonyElixir.GovernanceExecutionMonitor.inference_finished(monitor),
         :ok <- verify_native_edit(context, execution),
         {:ok, tree} <- SymphonyElixir.GovernanceCandidatePublication.stage(context),
         {:ok, qa} <-
           SymphonyElixir.GovernanceNativeCommand.qa(context, configuration, fn ->
             SymphonyElixir.GovernanceExecutionMonitor.healthy?(monitor)
           end),
         :ok <- SymphonyElixir.GovernanceCandidatePublication.unchanged(context, tree),
         {:ok, measurement} <- SymphonyElixir.GovernanceExecutionMonitor.finish(monitor),
         :ok <-
           record_execution_observation(
             cached,
             context,
             role,
             configuration,
             execution,
             Process.get({__MODULE__, :execution_witness}),
             measurement,
             if(measurement.cancelled, do: "cancelled", else: "completed")
           ),
         true <- not measurement.cancelled,
         :ok <- execution_guard(cached, context, role, configuration, execution),
         completed =
           execution.attempt
           |> Map.put("status", "passed")
           |> Map.put("completedAt", DateTime.to_iso8601(DateTime.utc_now()))
           |> Map.put(
             "summary",
             "Host observed completed native turn and fixed sandbox QA. Independent final committee and integration remain separate."
           ),
         {:ok, args} <-
           GovernanceToolBoundary.arguments(
             "bos_complete_attempt",
             %{
               "issueNumber" => context.issue.native_ref["issueNumber"],
               "runId" => context.issue.native_ref["runId"],
               "operationId" => execution.attempt["attemptId"] <> "_complete",
               "artifact" => completed
             },
             context,
             ["bos_complete_attempt"]
           ),
         {:ok, raw} <- observed_mcp_call(cached, context, role, configuration, "bos_complete_attempt", args),
         {:ok, %{"status" => "completed"}} <- GovernanceToolBoundary.decode_result(raw) do
      Process.put({__MODULE__, :host_qa}, %{
        context: context,
        tree: tree,
        qa: qa,
        marker: native_execution_marker(context, execution)
      })

      {:ok, Process.get({__MODULE__, :final_text}, "")}
    else
      _ -> {:error, :governance_execution_or_qa_unconfirmed}
    end
  end

  defp record_execution_observation(cached, context, role, configuration, execution, witness, measurement, state) do
    sequence = measurement.sequence
    id = "execution_observation_" <> host_digest([execution.admission["executionId"], sequence, state])
    public_witness = witness |> Map.drop(["marker"]) |> Map.put("markerDigest", host_digest(witness["marker"]))

    observation = %{
      "kind" => "development_execution_observation",
      "reservationId" => execution.admission["reservationId"],
      "executionId" => execution.admission["executionId"],
      "workerId" => execution.admission["workerId"],
      "ownershipGeneration" => execution.ownership.generation,
      "authorityGeneration" => execution.admission["authorityGeneration"],
      "sequence" => sequence,
      "observedAt" => measurement.observedAt,
      "state" => state,
      "usage" => %{
        "uncachedInputTokens" => measurement.uncachedInputTokens,
        "wallTimeSeconds" => measurement.wallTimeSeconds
      },
      "processWitness" => public_witness
    }

    observation = Map.put(observation, "proofDigest", "sha256:" <> host_digest(observation))

    artifact = %{
      "evidenceId" => id,
      "runId" => context.issue.native_ref["runId"],
      "commitSha" => context.sha,
      "phase" => "implementation",
      "status" => "inconclusive",
      "acceptanceCriteria" => [
        %{
          "id" => "runtime_usage",
          "name" => "Host-observed execution accounting; no implementation acceptance",
          "status" => "inconclusive",
          "verified" => false
        }
      ],
      "checks" => [%{"kind" => "runtime_usage", "status" => "inconclusive", "verified" => false}],
      "artifacts" => [observation],
      "summary" => "Operational accounting from the host process witness and native token telemetry only."
    }

    with {:ok, _} <-
           SymphonyElixir.GovernanceHostStore.request(configuration.execution, %{
             "kind" => "observation",
             "command" => "create",
             "id" => host_digest(artifact),
             "record" => artifact
           }),
         bound = Map.put(context, :host_observed_evidence, %{id => artifact}),
         {:ok, args} <-
           GovernanceToolBoundary.arguments(
             "bos_record_evidence",
             %{
               "issueNumber" => context.issue.native_ref["issueNumber"],
               "runId" => context.issue.native_ref["runId"],
               "operationId" => id,
               "artifact" => artifact
             },
             bound,
             ["bos_record_evidence"]
           ),
         {:ok, raw} <- observed_mcp_call(cached, bound, role, configuration, "bos_record_evidence", args),
         {:ok, %{"status" => "completed"}} <- GovernanceToolBoundary.decode_result(raw) do
      :ok
    else
      _ -> {:error, :governance_execution_observation_unconfirmed}
    end
  end

  defp close_execution(_configuration, nil), do: :ok

  defp close_execution(configuration, execution) do
    _ = SymphonyElixir.GovernanceExecutionJournal.transition(configuration.execution, execution.binding, "finish")
    SymphonyElixir.GovernanceHostStore.release(execution.ownership.lease)
    Process.delete({__MODULE__, :execution_witness})
    Process.delete({__MODULE__, :active_execution})
    :ok
  end

  defp host_digest(value),
    do: Base.encode16(:crypto.hash(:sha256, CanonicalJson.encode(value)), case: :lower)

  defp tool_result(cached, context, role, configuration, _source, tool, arguments, allowed) do
    result =
      with {:ok, source, current} <- effective(cached, context, role, configuration),
           true <- current == context.principal do
        if tool in Enum.map(GovernanceSourceTools.specs(), & &1["name"]) do
          GovernanceSourceTools.execute(tool, arguments, context, source)
        else
          with {:ok, args} <- GovernanceToolBoundary.arguments(tool, arguments, context, allowed),
               {:ok, raw} <- observed_mcp_call(cached, context, role, configuration, tool, args),
               {:ok, value} <- GovernanceToolBoundary.decode_result(raw) do
            {:ok, GovernanceToolBoundary.safe_output(value)}
          end
        end
      else
        _ -> {:error, :governance_live_binding_changed}
      end

    SymphonyElixir.GovernanceHostDiagnostics.record(configuration, context, role, tool, "host-tool-result", result)

    if is_pid(context[:recipient]),
      do:
        send(
          context.recipient,
          {:governance_tool_observed,
           %{
             tool: tool,
             success: match?({:ok, _}, result),
             candidate:
               case result do
                 {:ok, value} when is_map(value) -> value["candidateCommitSha"] || context[:sha]
                 _ -> context[:sha]
               end
           }}
        )

    case result do
      {:ok, value} ->
        %{"success" => true, "output" => Jason.encode!(value)}

      {:error, {:governance_mcp_tool_failed, issues}} ->
        %{
          "success" => false,
          "output" => Jason.encode!(%{"error" => "governance_mcp_tool_failed", "validationIssues" => issues})
        }

      {:error, reason} ->
        %{"success" => false, "output" => Jason.encode!(%{"error" => to_string(reason)})}
    end
  end

  defp observed_mcp_call(cached, context, role, configuration, tool, args) do
    result = GovernancePrivateMcp.call(cached.client, tool, args)

    audit_context =
      Map.merge(context, %{
        diagnostic_operation_id: args["operationId"],
        diagnostic_governance_id: get_in(args, ["artifact", "governanceId"])
      })

    SymphonyElixir.GovernanceHostDiagnostics.record(
      configuration,
      audit_context,
      role,
      tool,
      "private-mcp-call",
      result
    )

    result
  end

  defp effective(cached, context, role, configuration) do
    with {:ok, raw} <-
           GovernancePrivateMcp.call(cached.client, "bos_get_issue", %{
             "issueNumber" => context.issue.native_ref["issueNumber"]
           }),
         {:ok, source} when is_map(source) <- GovernanceToolBoundary.decode_result(raw),
         {:ok, principal} <-
           GovernanceToolBoundary.identity(
             source,
             expected_repository(configuration, context),
             role,
             configuration.allowed_authenticated_by
           ),
         true <- principal.invocation_id == cached.invocation_id,
         true <-
           principal.attestation_scope == %{
             "issueNumber" => context.issue.native_ref["issueNumber"],
             "runId" => context.issue.native_ref["runId"],
             "phase" => context[:phase] || "planning",
             "planHash" => get_in(context, [:manifest, "planHash"]),
             "candidateCommitSha" => context[:sha]
           } do
      {:ok, source, principal}
    else
      _ -> {:error, :governance_live_principal_unverified}
    end
  end

  defp connection(context, role, configuration) do
    case Process.get(key(context, role)) do
      %{client: client} = cached when is_pid(client) ->
        if Process.alive?(client), do: {:ok, cached}, else: {:error, :governance_private_transport_closed}

      _ ->
        open(context, role, configuration)
    end
  end

  defp open(context, role, configuration) do
    invocation = "inv_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    native = context.issue.native_ref

    scope = %{
      "serviceSubject" => configuration.service_subject,
      "role" => role,
      "invocationId" => invocation,
      "isolation" => if(role == "task-orchestrator", do: "executor", else: "read-only-worker"),
      "repository" => expected_repository(configuration, context),
      "issueNumber" => native["issueNumber"],
      "runId" => native["runId"],
      "phase" => context[:phase] || "planning",
      "catalogCommitSha" => GovernanceCatalog.commit(),
      "planHash" => get_in(context, [:manifest, "planHash"]),
      "candidateCommitSha" => context[:sha]
    }

    with {:ok, secret} <-
           SymphonyElixir.GovernanceSecretStore.service_secret(
             configuration.service_secret_file,
             configuration.service_subject
           ),
         {:ok, catalog} <- GovernanceCatalog.load(configuration.catalog_path),
         true <- role in Enum.map(catalog["roles"], & &1["id"]),
         options =
           Map.merge(configuration.mcp, %{
             workspace: context.workspace,
             arguments: [configuration.mcp.entrypoint],
             environment: %{
               "PATH" => "/usr/bin:/bin",
               "HOME" => configuration.private_home,
               "LANG" => "C.UTF-8",
               "BOS_WORKSPACE_ROOT" => context.workspace,
               "BOS_API_BASE_URL" => configuration.api_base_url,
               "BOS_API_TARGET_PROJECT_ID" => configuration.target_project_id,
               "BOS_MCP_CACHE_DIR" => configuration.private_cache_root,
               "BOS_GOVERNANCE_SERVICE_SECRET" => secret,
               "BOS_GOVERNANCE_CONTEXT_JSON" => Jason.encode!(scope)
             }
           }),
         {:ok, client} <- GovernancePrivateMcp.open(options) do
      cached = %{
        client: client,
        invocation_id: invocation,
        source: nil,
        principal: nil,
        reservation_bucket: div(System.system_time(:second), 300) * 300,
        role_definition: Enum.find(catalog["roles"], &(&1["id"] == role))
      }

      Process.put(key(context, role), cached)
      {:ok, cached}
    else
      _ -> {:error, :governance_service_credential_or_build_missing}
    end
  end

  defp expected_repository(configuration, context),
    do: Map.fetch!(configuration.repositories, context.issue.native_ref["repositoryId"])

  defp configuration do
    case Application.get_env(:symphony_elixir, :governance, [])[:broker] do
      config when is_map(config) -> {:ok, config}
      _ -> {:error, :governance_host_configuration_missing}
    end
  end

  defp key(context, role),
    do:
      {__MODULE__, context.issue.native_ref["repositoryId"], context.issue.native_ref["runId"], context.workspace, role, context[:phase] || "planning", get_in(context, [:manifest, "planHash"]),
       context[:sha]}

  defp preflight(port) do
    with {:ok, %{"config" => config}} <- AppServer.host_request(port, "config/read", %{"includeLayers" => false}),
         true <- native_providers_disabled?(config) do
      :ok
    else
      _ -> {:error, :governance_unexpected_native_tool_provider}
    end
  end

  @doc false
  @spec native_providers_disabled?(term()) :: boolean()
  def native_providers_disabled?(config) when is_map(config),
    do:
      disabled_providers?(config["mcp_servers"]) and disabled_providers?(config["plugins"]) and
        empty_hooks?(config["hooks"])

  def native_providers_disabled?(_), do: false

  defp disabled_providers?(nil), do: true

  defp disabled_providers?(entries) when is_map(entries),
    do: Enum.all?(entries, fn {_, value} -> is_map(value) and value["enabled"] == false end)

  defp disabled_providers?(_), do: false
  defp empty_hooks?(nil), do: true
  defp empty_hooks?(entries) when is_map(entries), do: Enum.all?(entries, fn {_, value} -> value == [] end)
  defp empty_hooks?(_), do: false

  defp collect_text(%{
         payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}
       })
       when is_binary(text),
       do: Process.put({__MODULE__, :final_text}, text)

  defp collect_text(_), do: :ok
end
