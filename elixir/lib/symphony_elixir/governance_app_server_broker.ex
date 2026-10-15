defmodule SymphonyElixir.GovernanceAppServerBroker do
  @moduledoc "Concrete host broker: private BOS MCP transport, server-bound invocation, pinned native AppServer and scoped source tools."
  @behaviour SymphonyElixir.GovernanceSession
  alias SymphonyElixir.{GovernanceCatalog, GovernancePrivateMcp, GovernanceRuntime, GovernanceSourceTools, GovernanceToolBoundary}
  alias SymphonyElixir.Codex.AppServer

  @doc false
  def host_read(context, tool, arguments) when tool in ~w(bos_get_issue bos_get_goal_planning bos_get_goal_execution bos_get_delivery_run) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, "task-orchestrator", configuration),
         {:ok, _, principal} <- effective(cached, context, "task-orchestrator", configuration),
         {:ok, arguments} <- GovernanceToolBoundary.arguments(tool, arguments, Map.put(context, :principal, principal), [tool]),
         {:ok, raw} <- GovernancePrivateMcp.call(cached.client, tool, arguments),
         {:ok, value} <- GovernanceToolBoundary.decode_result(raw) do
      {:ok, GovernanceToolBoundary.safe_output(value)}
    end
  end

  @doc false
  def reserve_existing_run(context, run) do
    with true <- SymphonyElixir.GovernanceReservation.run_matches?(context, run),
         {:ok, source} <- host_read(context, "bos_get_issue", %{"issueNumber" => context.issue.native_ref["issueNumber"]}) do
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
           "governance-intake-" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!([native["repositoryId"], native["runId"], cached.invocation_id, cached.reservation_bucket])), case: :lower),
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

  def identity(context, role) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, role, configuration),
         {:ok, source, principal} <- effective(cached, context, role, configuration) do
      Process.put(key(context, role), %{cached | source: source, principal: principal})
      {:ok, principal}
    end
  end

  def capabilities(_context, _role) do
    with {:ok, configuration} <- configuration(),
         :ok <- GovernanceRuntime.validate(configuration.runtime) do
      {:ok, %{read_only: :enforced, tool_allowlist: :enforced, minimal_environment: :enforced, read_roots: :enforced, private_mcp_credentials: :enforced}}
    end
  end

  def run(context, role, prompt, policy) do
    with {:ok, _} <- execute(context, role, prompt, policy, nil), do: :ok
  end

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

    :ok
  end

  defp execute(context, role, prompt, policy, schema) do
    with {:ok, configuration} <- configuration(),
         {:ok, cached} <- connection(context, role, configuration),
         {:ok, source, principal} <- effective(cached, context, role, configuration),
         true <- principal == context.principal,
         {:ok, launch} <- GovernanceRuntime.launch(configuration.runtime, context, role, policy),
         {:ok, %{"tools" => tools}} <- GovernancePrivateMcp.request(cached.client, "tools/list", %{}),
         allowed = policy.tools,
         true <- is_list(allowed) and Enum.all?(allowed, fn name -> Enum.any?(tools, &(&1["name"] == name)) end) do
      prompt = "Canonical role definition from verified catalog #{GovernanceCatalog.commit()}: #{Jason.encode!(cached.role_definition)}\n" <> prompt
      selected = Enum.filter(tools, &(&1["name"] in allowed)) |> Enum.map(&Map.take(&1, ~w(name description inputSchema)))
      specs = selected ++ GovernanceSourceTools.specs()
      binding = %{tool_specs: specs, secret_environment_names: []}
      options = [managed_launch: launch.managed, dynamic_tool_binding: binding, thread_parameters: launch.thread_parameters, host_preflight: &preflight/1]

      with {:ok, session} <- AppServer.start_session(launch.workspace, options) do
        Process.put({__MODULE__, :final_text}, "")
        Process.put({__MODULE__, :native_status}, nil)

        try do
          executor = fn tool, args -> tool_result(cached, context, role, configuration, source, tool, args, allowed) end

          callback = fn message ->
            collect_text(message)
            if status = SymphonyElixir.GovernanceHostDiagnostics.terminal_status(message[:payload]), do: Process.put({__MODULE__, :native_status}, status)
            if is_pid(context.recipient), do: send(context.recipient, {:codex_worker_update, context.issue.id, Map.put(message, :delivery_actor, role)})
          end

          case AppServer.run_turn(session, prompt, context.issue, on_message: callback, tool_executor: executor, role: role, output_schema: schema) do
            {:ok, %{result: %{status: :budget_paused}}} -> {:error, :governance_turn_budget_paused}
            {:ok, _} -> if Process.get({__MODULE__, :native_status}) == "completed", do: {:ok, Process.get({__MODULE__, :final_text}, "")}, else: {:error, :governance_native_turn_not_completed}
            {:error, _} -> {:error, :governance_native_turn_failed}
          end
        after
          AppServer.stop_session(session)
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
      {:ok, value} -> %{"success" => true, "output" => Jason.encode!(value)}
      {:error, {:governance_mcp_tool_failed, issues}} -> %{"success" => false, "output" => Jason.encode!(%{"error" => "governance_mcp_tool_failed", "validationIssues" => issues})}
      {:error, reason} -> %{"success" => false, "output" => Jason.encode!(%{"error" => to_string(reason)})}
    end
  end

  defp observed_mcp_call(cached, context, role, configuration, tool, args) do
    result = GovernancePrivateMcp.call(cached.client, tool, args)
    audit_context = Map.merge(context, %{diagnostic_operation_id: args["operationId"], diagnostic_governance_id: get_in(args, ["artifact", "governanceId"])})
    SymphonyElixir.GovernanceHostDiagnostics.record(configuration, audit_context, role, tool, "private-mcp-call", result)
    result
  end

  defp effective(cached, context, role, configuration) do
    with {:ok, raw} <- GovernancePrivateMcp.call(cached.client, "bos_get_issue", %{"issueNumber" => context.issue.native_ref["issueNumber"]}),
         {:ok, source} when is_map(source) <- GovernanceToolBoundary.decode_result(raw),
         {:ok, principal} <- GovernanceToolBoundary.identity(source, expected_repository(configuration, context), role, configuration.allowed_authenticated_by),
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

    with {:ok, secret} <- SymphonyElixir.GovernanceSecretStore.service_secret(configuration.service_secret_file, configuration.service_subject),
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

  defp expected_repository(configuration, context), do: Map.fetch!(configuration.repositories, context.issue.native_ref["repositoryId"])

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
  def native_providers_disabled?(config) when is_map(config), do: disabled_providers?(config["mcp_servers"]) and disabled_providers?(config["plugins"]) and empty_hooks?(config["hooks"])
  def native_providers_disabled?(_), do: false

  defp disabled_providers?(nil), do: true
  defp disabled_providers?(entries) when is_map(entries), do: Enum.all?(entries, fn {_, value} -> is_map(value) and value["enabled"] == false end)
  defp disabled_providers?(_), do: false
  defp empty_hooks?(nil), do: true
  defp empty_hooks?(entries) when is_map(entries), do: Enum.all?(entries, fn {_, value} -> value == [] end)
  defp empty_hooks?(_), do: false

  defp collect_text(%{payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}}) when is_binary(text),
    do: Process.put({__MODULE__, :final_text}, text)

  defp collect_text(_), do: :ok
end
