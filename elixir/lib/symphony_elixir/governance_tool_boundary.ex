defmodule SymphonyElixir.GovernanceToolBoundary do
  @moduledoc "Scope and least-privilege checks applied by the host before every private MCP tool call."
  alias SymphonyElixir.{GovernanceCatalog, GovernanceRequestSnapshot}
  @production ~w(bos_request_merge bos_create_deployment bos_create_release bos_realize_vercel_deployment bos_record_deployment_verification bos_record_deployment_runtime_probe)

  def identity(source, expected, role, allowed_authenticators \\ []) do
    required = if role == "task-orchestrator", do: ~w(bos:delivery bos:governance:execute), else: ~w(bos:delivery bos:governance:review)

    case source["governanceIdentity"] do
      %{
        "verified" => true,
        "authenticatedBy" => authenticated_by,
        "serviceSubject" => service,
        "actorSubjectId" => subject,
        "logicalRole" => ^role,
        "invocationId" => invocation,
        "repository" => repository,
        "permissions" => permissions,
        "readOnly" => readonly,
        "catalogCommitSha" => catalog,
        "bindingDigest" => binding,
        "isolation" => isolation,
        "attestationScope" => scope
      }
      when is_binary(service) and service != "" and is_binary(subject) and subject != "" and is_binary(binding) ->
        if authenticated_by in allowed_authenticators and repository == expected and Enum.sort(permissions) == Enum.sort(required) and
             readonly == (role != "task-orchestrator") and catalog == GovernanceCatalog.commit() and
             isolation == if(role == "task-orchestrator", do: "executor", else: "read-only-worker") and
             Regex.match?(~r/^sha256:[0-9a-f]{64}$/, binding) do
          {:ok, %{service_id: service, subject_id: subject, role: role, repository_id: repository["repositoryId"], invocation_id: invocation, binding_digest: binding, attestation_scope: scope}}
        else
          {:error, :governance_effective_principal_mismatch}
        end

      _ ->
        {:error, :governance_effective_principal_unverified}
    end
  rescue
    _ -> {:error, :governance_effective_principal_unverified}
  end

  def arguments(tool, args, context, allowed) when is_map(args) do
    native = context.issue.native_ref

    with true <- tool in allowed,
         false <- tool in @production,
         true <- same_or_absent?(args, "issueNumber", native["issueNumber"]),
         true <- same_or_absent?(args, "runId", native["runId"]),
         true <- Enum.all?(~w(repository repositoryId owner repo), &(not Map.has_key?(args, &1))),
         {:ok, artifact} <- artifact(tool, args["artifact"], context) do
      bound = if artifact, do: Map.put(args, "artifact", artifact), else: args
      invocation = context.principal[:invocation_id]
      {:ok, bind_operation(tool, bound, invocation)}
    else
      _ -> {:error, :governance_tool_scope_rejected}
    end
  end

  def arguments(_, _, _, _), do: {:error, :governance_tool_scope_rejected}

  @doc false
  def bind_operation(tool, args, invocation) when tool in ~w(bos_record_governance bos_record_review bos_record_evidence) and is_binary(invocation) do
    case args["operationId"] do
      logical when is_binary(logical) ->
        bytes = :erlang.term_to_binary({logical, invocation, Map.delete(args, "operationId")}, [:deterministic])
        Map.put(args, "operationId", "govop_" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))

      _ ->
        args
    end
  end

  def bind_operation(_, args, _), do: args

  def decode_result(%{"isError" => true} = raw) do
    details = SymphonyElixir.GovernanceHostDiagnostics.outcome({:ok, raw})

    case details[:validationIssues] do
      [_ | _] = issues -> {:error, {:governance_mcp_tool_failed, issues}}
      _ -> {:error, :governance_mcp_tool_failed}
    end
  end

  def decode_result(%{"content" => content}) when is_list(content) do
    case Enum.find(content, &(&1["type"] == "text")) do
      %{"text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, value} -> {:ok, value}
          _ -> {:ok, text}
        end

      _ ->
        {:error, :governance_mcp_result_invalid}
    end
  end

  def decode_result(_), do: {:error, :governance_mcp_result_invalid}

  def safe_output(value) when is_binary(value), do: GovernanceRequestSnapshot.sanitize(value)
  def safe_output(value) when is_list(value), do: Enum.map(value, &safe_output/1)

  def safe_output(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if Regex.match?(~r/^(?:access[_-]?token|refresh[_-]?token|token|authorization|cookie|password|api[_-]?key|machine[_-]?secret[_-]?key|client[_-]?secret)$/i, to_string(key)),
        do: {key, "[REDACTED]"},
        else: {key, safe_output(nested)}
    end)
  end

  def safe_output(value), do: value
  defp same_or_absent?(map, key, expected), do: not Map.has_key?(map, key) or map[key] == expected

  defp artifact(_tool, nil, _context), do: {:ok, nil}

  defp artifact(tool, artifact, context) when is_map(artifact) do
    with true <- same_or_absent?(artifact, "runId", context.issue.native_ref["runId"]),
         true <- exact_candidate?(artifact, context),
         true <- observed_evidence?(tool, artifact, context),
         true <- tool != "bos_record_governance" or Enum.all?(~w(actor role payload), &(not Map.has_key?(artifact, &1))) do
      actor = %{"type" => "agent", "subjectId" => context.principal.subject_id}
      {:ok, if(tool in ~w(bos_record_review bos_start_attempt bos_complete_attempt), do: Map.put(artifact, "actor", actor), else: artifact)}
    else
      _ -> {:error, :governance_tool_scope_rejected}
    end
  end

  defp artifact(_, _, _), do: {:error, :governance_tool_scope_rejected}

  defp observed_evidence?("bos_record_evidence", artifact, context) do
    checks = artifact["checks"] || []
    host_only = artifact["phase"] == "readiness" or Enum.any?(artifact["artifacts"] || [], &(is_map(&1) and &1["kind"] in ~w(host_environment_observation development_execution_observation)))
    asserted = host_only or artifact["status"] == "passed" or (is_list(checks) and Enum.any?(checks, &(is_map(&1) and &1["verified"] == true)))
    not asserted or get_in(context, [:host_observed_evidence, artifact["evidenceId"]]) == artifact
  end

  defp observed_evidence?(_, _, _), do: true

  defp exact_candidate?(artifact, %{sha: sha}) do
    Enum.all?(~w(commitSha candidateCommitSha), &same_or_absent?(artifact, &1, sha))
  end

  defp exact_candidate?(_, _), do: true
end
