defmodule SymphonyElixir.GovernanceHostDiagnostics do
  @moduledoc "Bounded host-only tool outcome metadata; never records arguments, response bodies or credentials."

  def record(configuration, context, role, tool, stage, result) do
    entry = %{
      tool: tool,
      stage: stage,
      role: role,
      issueNumber: context.issue.native_ref["issueNumber"],
      runId: context.issue.native_ref["runId"],
      candidateCommitSha: context[:sha],
      at: DateTime.to_iso8601(DateTime.utc_now())
    }

    entry =
      Map.merge(
        entry,
        if(stage == "private-mcp-call",
          do: outcome(result),
          else: %{
            success: match?({:ok, _}, result),
            errorCode:
              case result do
                {:error, reason} when is_atom(reason) -> Atom.to_string(reason)
                _ -> nil
              end
          }
        )
      )

    entry = Map.merge(entry, %{operationId: context[:diagnostic_operation_id], governanceId: context[:diagnostic_governance_id], invocationId: get_in(context, [:principal, :invocation_id])})
    root = configuration.private_cache_root
    {:ok, ^root} = SymphonyElixir.PathSafety.canonicalize(root)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {:ok, ^root} = SymphonyElixir.PathSafety.canonicalize(root)
    path = Path.join(root, "governance-host-tools.jsonl")
    {:ok, ^path} = SymphonyElixir.PathSafety.canonicalize(path)
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
    File.chmod!(path, 0o600)
    :ok
  rescue
    _ -> {:error, :governance_host_diagnostic_unavailable}
  end

  def terminal_status(%{"method" => "turn/completed", "params" => %{"turn" => %{"status" => status}}}) when status in ~w(completed failed interrupted cancelled), do: status
  def terminal_status(%{"method" => "turn/failed"}), do: "failed"
  def terminal_status(%{"method" => "turn/cancelled"}), do: "cancelled"
  def terminal_status(_), do: nil

  def outcome({:ok, raw}) when is_map(raw) do
    case raw["content"] do
      entries when is_list(entries) ->
        value = entries |> Enum.find_value(fn entry -> if entry["type"] == "text", do: entry["text"] end)

        case Jason.decode(value || "") do
          {:ok, %{"error" => error}} when is_map(error) ->
            code = error["code"]
            details = error["details"] || %{}
            status = details["status"]

            %{
              privateMcpInvoked: true,
              success: false,
              errorCode: safe_code(code),
              httpStatus: if(is_integer(status) and status in 100..599, do: status, else: nil),
              validationIssues: safe_validation_issues(details["issues"])
            }

          _ ->
            %{privateMcpInvoked: true, success: raw["isError"] != true}
        end

      _ ->
        %{privateMcpInvoked: true, success: false, errorCode: "invalid_mcp_result"}
    end
  end

  def outcome({:error, reason}) when is_atom(reason), do: %{success: false, errorCode: Atom.to_string(reason)}
  def outcome(_), do: %{success: false, errorCode: "unclassified_host_failure"}

  @validation_fields ~w(request body artifact repository repositoryId owner repo issueNumber runId operationId kind governanceId phase event planHash catalogCommitSha candidateCommitSha round summary applicable status verdict reviewIds evidenceIds recoveryKind pullRequestNumber targetProjectId)
  @validation_types ~w(missing extra_forbidden value_error literal_error enum string_pattern_mismatch string_type int_type bool_type greater_than_equal less_than_equal)
  @constraints ~w(verdict_status_required verdict_phase_mismatch verdict_event_only applicable_required applicable_event_only recovery_kind_event_only pull_request_event_only)
  def safe_validation_issues(issues) when is_list(issues) do
    issues
    |> Enum.take(20)
    |> Enum.flat_map(fn
      %{"field" => field, "type" => type} = item when is_binary(field) ->
        if byte_size(field) <= 150 and type in @validation_types and Enum.all?(String.split(field, "."), &(&1 in @validation_fields)) do
          issue = Map.take(item, ~w(field type))
          [if(item["constraint"] in @constraints, do: Map.put(issue, "constraint", item["constraint"]), else: issue)]
        else
          []
        end

      _ ->
        []
    end)
  end

  def safe_validation_issues(_), do: []
  defp safe_code(code) when is_binary(code), do: if(Regex.match?(~r/^[a-z][a-z0-9_]{0,79}$/, code), do: code, else: "unclassified_backend_code")
  defp safe_code(_), do: "unclassified_backend_code"
end
