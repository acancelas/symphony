defmodule SymphonyElixir.GameApi.Client do
  @moduledoc """
  Normalized tracker client for the BOS `game-api` gateway.

  It has no GitHub token and never calls GitHub directly.
  """

  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.Config
  alias SymphonyElixir.GameApi.ProviderCircuit
  alias SymphonyElixir.Tracker.Issue

  @recoverable_audit_error_codes ~w(
    audit_canonicalization_failed
    audit_chain_conflict
    audit_chain_start_invalid
    audit_event_hash_invalid
    audit_hash_chain_mismatch
    audit_sequence_gap
  )

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(state_names) when is_list(state_names) do
    repositories()
    |> Enum.reduce_while({:ok, []}, fn repository, {:ok, accumulated} ->
      params =
        repository_query(repository) ++
          Enum.map(state_names, &{"states", &1})

      case request(:get, "/v1/internal/bos/delivery/issues/by-states", params: params)
           |> response_list("issues") do
        {:ok, issues} -> {:cont, {:ok, accumulated ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec reconcile_terminal_runs() :: {:ok, [map()]} | {:error, term()}
  def reconcile_terminal_runs do
    reconciliation_cycle_id = reconciliation_cycle_id()

    repositories()
    |> Enum.reduce_while({:ok, []}, fn repository, {:ok, accumulated} ->
      with {:ok, runs} <- list_runs(repository),
           {:ok, reconciled} <- reconcile_repository_runs(repository, runs, reconciliation_cycle_id) do
        {:cont, {:ok, accumulated ++ reconciled}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec fetch_issue(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_issue(repository_id, issue_number)
      when is_binary(repository_id) and is_integer(issue_number) and issue_number > 0 do
    with {:ok, repository} <- find_repository(repository_id) do
      request(:get, "/v1/internal/bos/delivery/issues/#{issue_number}", params: repository_query(repository))
    end
  end

  @spec claim_issue(String.t(), pos_integer(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def claim_issue(repository_id, issue_number, existing_run_id)
      when is_binary(repository_id) and is_integer(issue_number) do
    run_id = existing_run_id || new_run_id(issue_number)
    runner_id = System.get_env("BOS_RUNNER_ID") || "x1"
    lease_expires_at = DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.to_iso8601()

    with {:ok, repository} <- find_repository(repository_id) do
      request(:post, "/v1/internal/bos/delivery/issues/claim",
        json: %{
          "repository" => repository_body(repository),
          "issueNumber" => issue_number,
          "operationId" => "claim_#{run_id}",
          "runId" => run_id,
          "runnerId" => runner_id,
          "leaseExpiresAt" => lease_expires_at
        }
      )
    end
  end

  @spec heartbeat_issue(String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def heartbeat_issue(repository_id, issue_number, run_id)
      when is_binary(repository_id) and is_integer(issue_number) and is_binary(run_id) do
    runner_id = System.get_env("BOS_RUNNER_ID") || "x1"
    lease_expires_at = DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.to_iso8601()

    with {:ok, repository} <- find_repository(repository_id) do
      request(:post, "/v1/internal/bos/delivery/issues/heartbeat",
        json: %{
          "repository" => repository_body(repository),
          "issueNumber" => issue_number,
          "operationId" => "heartbeat_#{run_id}_#{System.system_time(:second)}",
          "runId" => run_id,
          "runnerId" => runner_id,
          "leaseExpiresAt" => lease_expires_at
        }
      )
    end
  end

  @spec append_audit_batch(map()) :: {:ok, map()} | {:error, term()}
  def append_audit_batch(batch) when is_map(batch) do
    request(:post, "/v1/internal/bos/delivery/audit/events", json: batch)
  end

  @spec record_runtime_probe(map()) :: {:ok, map()} | {:error, term()}
  def record_runtime_probe(probe) when is_map(probe) do
    request(:post, "/v1/internal/bos/delivery/deployment-verifications/runtime-probes", json: probe)
  end

  @spec fetch_goal_planning(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_goal_planning(repository_id, issue_number)
      when is_binary(repository_id) and is_integer(issue_number) and issue_number > 0 do
    with {:ok, repository} <- find_repository(repository_id) do
      request(:get, "/v1/internal/bos/delivery/goals/planning", params: repository_query(repository) ++ [{"issueNumber", issue_number}])
    end
  end

  @spec request_goal_breakdown_approval(Issue.t()) :: {:ok, map()} | {:error, term()}
  def request_goal_breakdown_approval(%Issue{native_ref: native_ref}) do
    with {:ok, repository} <- find_repository(native_ref["repositoryId"]) do
      request(:post, "/v1/internal/bos/delivery/goals/breakdown-approval-requests",
        json: %{
          "repository" => repository_body(repository),
          "issueNumber" => native_ref["issueNumber"],
          "operationId" => "goal_approval_request_#{native_ref["runId"]}",
          "runId" => native_ref["runId"]
        }
      )
    end
  end

  @spec fetch_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_run(repository_id, run_id) when is_binary(repository_id) and is_binary(run_id) do
    with {:ok, repository} <- find_repository(repository_id) do
      request(:get, "/v1/internal/bos/delivery/runs/#{URI.encode(run_id)}", params: repository_query(repository))
    end
  end

  @spec mark_pull_request_ready(map()) :: {:ok, map()} | {:error, term()}
  def mark_pull_request_ready(readiness) when is_map(readiness) do
    with {:ok, repository} <- find_repository(readiness["repositoryId"]) do
      request(:post, "/v1/internal/bos/github/pull-requests/ready",
        json: %{
          "repository" => repository_body(repository),
          "issueNumber" => readiness["issueNumber"],
          "operationId" => readiness["operationId"],
          "runId" => readiness["runId"],
          "pullRequestNumber" => readiness["pullRequestNumber"],
          "expectedHeadSha" => readiness["expectedHeadSha"]
        }
      )
    end
  end

  @spec fetch_pull_request(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_pull_request(repository_id, pull_request_number)
      when is_binary(repository_id) and is_integer(pull_request_number) and pull_request_number > 0 do
    with {:ok, repository} <- find_repository(repository_id) do
      request(:get, "/v1/internal/bos/github/pull-requests/#{pull_request_number}", params: repository_query(repository))
    end
  end

  @spec fetch_run_artifacts(String.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_run_artifacts(repository_id, run_id, directory)
      when is_binary(repository_id) and is_binary(run_id) and is_binary(directory) do
    with {:ok, repository} <- find_repository(repository_id) do
      list_artifacts(repository, run_id, directory)
    end
  end

  @spec start_execution(Issue.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def start_execution(%Issue{native_ref: native_ref} = issue, attempt_number)
      when is_integer(attempt_number) and attempt_number > 0 do
    repository_id = native_ref["repositoryId"]
    run_id = native_ref["runId"]
    issue_number = native_ref["issueNumber"]
    attempt_id = "attempt_#{run_id}_#{attempt_number}"

    with true <- (is_binary(run_id) and run_id != "") || {:error, :missing_run_id},
         {:ok, repository} <- find_repository(repository_id),
         {:ok, run, run_disposition} <-
           ensure_run_record(repository, issue, run_id, issue_number, attempt_id),
         {:ok, attempt_disposition} <-
           ensure_attempt_record(repository, issue, run, run_id, attempt_id, attempt_number),
         :ok <-
           record_recovery_decision(
             repository,
             issue,
             run,
             run_id,
             attempt_id,
             run_disposition,
             attempt_disposition
           ) do
      {:ok, attempt_id}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing_run_id}
    end
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    configured_repositories = repositories(tracker_settings)

    cond do
      blank?(endpoint(tracker_settings)) -> {:error, :missing_game_api_endpoint}
      blank?(System.get_env("BOS_API_INTERNAL_TOKEN")) -> {:error, :missing_game_api_token}
      configured_repositories == [] -> {:error, :missing_game_api_repositories}
      Enum.any?(configured_repositories, &invalid_repository?/1) -> {:error, :invalid_game_api_repository}
      true -> :ok
    end
  end

  defp request(method, path, options) do
    tracker = Config.settings!().tracker
    url = String.trim_trailing(endpoint(tracker), "/") <> path
    token = System.get_env("BOS_API_INTERNAL_TOKEN")
    runner_id = System.get_env("BOS_RUNNER_ID") || "x1"

    headers =
      [
        {"accept", "application/json"},
        {"x-internal-token", token},
        {"x-bos-actor-type", "runner"},
        {"x-bos-actor-id", "runner:#{runner_id}"},
        {"x-bos-runner-id", runner_id},
        {"x-bos-authenticated-by", "symphony_internal_token"},
        {"x-bos-origin", "symphony"}
      ]
      |> maybe_add_header("x-bos-runner-action-token", System.get_env("BOS_RUNNER_ACTION_TOKEN"))

    options =
      Keyword.merge(options,
        headers: headers,
        receive_timeout: 15_000,
        retry: false
      )

    with :ok <- ProviderCircuit.before_request() do
      case Req.request(Keyword.merge(options, method: method, url: url)) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          ProviderCircuit.succeeded()
          {:ok, body}

        {:ok, %Req.Response{status: status} = response} when status in [403, 429] ->
          {:error, {:game_api_rate_limited, ProviderCircuit.rate_limited(retry_after_ms(response))}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, reason} ->
          {:error, {:game_api_request_failed, reason}}
      end
    end
  end

  @doc false
  @spec http_error(non_neg_integer(), term()) :: tuple()
  def http_error(status, body) do
    case response_error_code(body) do
      code when status in [409, 422] and code in @recoverable_audit_error_codes ->
        {:game_api_http_error, status, code}

      _ ->
        {:game_api_http_error, status}
    end
  end

  defp response_error_code(%{"detail" => %{"error" => code}}) when is_binary(code), do: code
  defp response_error_code(%{"detail" => %{"code" => code}}) when is_binary(code), do: code
  defp response_error_code(%{"detail" => detail}) when is_binary(detail), do: response_error_code(detail)
  defp response_error_code(%{"error" => code}) when is_binary(code), do: code
  defp response_error_code(%{"code" => code}) when is_binary(code), do: code

  defp response_error_code(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> response_error_code(decoded)
      {:error, _reason} -> nil
    end
  end

  defp response_error_code(_body), do: nil

  defp retry_after_ms(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _rest] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds * 1_000
          _invalid -> nil
        end

      [] ->
        nil
    end
  end

  defp response_list({:ok, payload}, key) when is_map(payload) do
    case Map.get(payload, key) do
      values when is_list(values) -> {:ok, values}
      _ -> {:error, {:invalid_game_api_response, key}}
    end
  end

  defp response_list({:error, reason}, _key), do: {:error, reason}

  defp list_runs(repository) do
    request(:get, "/v1/internal/bos/delivery/runs", params: repository_query(repository))
    |> response_list("runs")
  end

  defp reconcile_repository_runs(repository, runs, reconciliation_cycle_id) do
    reconcile_run_projections(runs, &reconcile_run(repository, &1, reconciliation_cycle_id))
  end

  defp reconcile_run_projections(runs, reconcile_fun) do
    runs
    |> Enum.reject(&(&1["status"] in ["completed", "cancelled"]))
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, accumulated} ->
      result =
        if valid_run_projection?(run) do
          reconcile_fun.(run)
        else
          {:ok,
           %{
             "action" => "skipped",
             "reason" => "invalid_run_projection",
             "runId" => run["runId"]
           }}
        end

      case result do
        {:ok, payload} -> {:cont, {:ok, [payload | accumulated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp valid_run_projection?(%{"runId" => run_id, "issueNumber" => issue_number})
       when is_binary(run_id) and run_id != "" and is_integer(issue_number) and issue_number > 0,
       do: true

  defp valid_run_projection?(_run), do: false

  @doc false
  @spec reconcile_run_projections_for_test([map()], (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def reconcile_run_projections_for_test(runs, reconcile_fun)
      when is_list(runs) and is_function(reconcile_fun, 1) do
    reconcile_run_projections(runs, reconcile_fun)
  end

  defp reconcile_run(repository, %{"runId" => run_id, "issueNumber" => issue_number}, reconciliation_cycle_id)
       when is_binary(run_id) and run_id != "" and is_integer(issue_number) and issue_number > 0 do
    request(:post, "/v1/internal/bos/delivery/runs/reconcile",
      json: %{
        "repository" => repository_body(repository),
        "issueNumber" => issue_number,
        "operationId" => reconciliation_operation_id_for_test(run_id, reconciliation_cycle_id),
        "runId" => run_id
      }
    )
  end

  @doc false
  @spec reconciliation_operation_id_for_test(String.t(), String.t()) :: String.t()
  def reconciliation_operation_id_for_test(run_id, reconciliation_cycle_id)
      when is_binary(run_id) and is_binary(reconciliation_cycle_id) do
    "reconcile_terminal_#{run_id}_#{reconciliation_cycle_id}"
  end

  defp reconciliation_cycle_id do
    timestamp = System.system_time(:millisecond)
    entropy = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{timestamp}_#{entropy}"
  end

  defp ensure_run_record(repository, issue, run_id, issue_number, attempt_id) do
    case fetch_run(repository["repository_id"], run_id) do
      {:ok, %{"currentAttemptId" => ^attempt_id} = run} ->
        {:ok, run, :existing}

      {:ok, run} ->
        with {:ok, updated} <- record_run(repository, issue, run_id, issue_number, attempt_id, run) do
          {:ok, updated, :updated}
        end

      {:error, {:game_api_http_error, 404}} ->
        with {:ok, created} <- record_run(repository, issue, run_id, issue_number, attempt_id, nil) do
          {:ok, created, :created}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_run(repository, issue, run_id, issue_number, attempt_id, existing_run) do
    with {:ok, event} <- lifecycle_event(repository, issue, run_id, attempt_id, existing_run, "run.started", "AgentRun started durably."),
         {:ok, _result} <-
           record_artifact(
             repository,
             issue_number,
             run_id,
             "run",
             %{
               "runId" => run_id,
               "issueNumber" => issue_number,
               "repositoryId" => repository["repository_id"],
               "status" => "running",
               "initiatedBy" => %{"type" => "runner", "runnerId" => runner_id()},
               "runner" => runner_identity(),
               "startedAt" => (existing_run && existing_run["startedAt"]) || event["occurredAt"],
               "branch" => issue.branch_name,
               "baseCommit" => existing_run && existing_run["baseCommit"],
               "headCommit" => existing_run && existing_run["headCommit"],
               "pullRequestNumber" => existing_run && existing_run["pullRequestNumber"],
               "currentAttemptId" => attempt_id
             },
             event
           ) do
      fetch_run(repository["repository_id"], run_id)
    end
  end

  defp ensure_attempt_record(repository, issue, run, run_id, attempt_id, attempt_number) do
    case list_artifacts(repository, run_id, "attempts") do
      {:ok, artifacts} when is_list(artifacts) ->
        if Enum.any?(artifacts, &(&1["attemptId"] == attempt_id)) do
          {:ok, :existing}
        else
          create_attempt(repository, issue, run, run_id, attempt_id, attempt_number)
        end

      {:error, {:game_api_http_error, 404}} ->
        create_attempt(repository, issue, run, run_id, attempt_id, attempt_number)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_attempt(repository, issue, run, run_id, attempt_id, attempt_number) do
    with :ok <- record_attempt(repository, issue, run, run_id, attempt_id, attempt_number) do
      {:ok, :created}
    end
  end

  defp record_attempt(repository, issue, run, run_id, attempt_id, attempt_number) do
    issue_number = issue.native_ref["issueNumber"]

    with {:ok, event} <- lifecycle_event(repository, issue, run_id, attempt_id, run, "attempt.started", "Attempt started durably."),
         {:ok, _result} <-
           record_artifact(
             repository,
             issue_number,
             run_id,
             "attempt_started",
             %{
               "attemptId" => attempt_id,
               "runId" => run_id,
               "number" => attempt_number,
               "status" => "running",
               "actor" => %{"type" => "runner", "subjectId" => runner_id()},
               "startedAt" => event["occurredAt"],
               "metrics" => %{}
             },
             event
           ) do
      :ok
    end
  end

  defp record_recovery_decision(
         repository,
         issue,
         run,
         run_id,
         attempt_id,
         :existing,
         :existing
       ) do
    with {:ok, event} <-
           lifecycle_event(
             repository,
             issue,
             run_id,
             attempt_id,
             run,
             "recovery.resumed",
             "Existing AgentRun and Attempt selected for idempotent restart recovery."
           ),
         {:ok, _receipt} <- append_recovery_event(repository, event) do
      :ok
    end
  end

  defp record_recovery_decision(
         _repository,
         _issue,
         _run,
         _run_id,
         _attempt_id,
         _run_disposition,
         _attempt_disposition
       ),
       do: :ok

  defp append_recovery_event(repository, event) do
    operation_id = event["operationId"]

    append_audit_batch(%{
      "operationId" => "append_#{operation_id}",
      "batchId" => "batch_#{operation_id}",
      "repository" => repository_body(repository),
      "events" => [event]
    })
  end

  defp record_artifact(repository, issue_number, run_id, kind, artifact, event) do
    operation_id = event["operationId"]

    request(:post, "/v1/internal/bos/delivery/artifacts",
      json: %{
        "repository" => repository_body(repository),
        "issueNumber" => issue_number,
        "operationId" => operation_id,
        "runId" => run_id,
        "kind" => kind,
        "artifact" => artifact,
        "auditBatch" => %{
          "operationId" => "append_#{operation_id}",
          "batchId" => "batch_#{operation_id}",
          "repository" => repository_body(repository),
          "events" => [event]
        }
      }
    )
  end

  defp list_artifacts(repository, run_id, directory) do
    request(:get, "/v1/internal/bos/delivery/runs/#{URI.encode(run_id)}/artifacts/#{directory}", params: repository_query(repository))
    |> response_list("artifacts")
  end

  defp lifecycle_event(repository, issue, run_id, attempt_id, run, event_type, summary) do
    chain = (run && run["auditChain"]) || %{}
    sequence = (chain["lastSequence"] || 0) + 1
    previous_hash = chain["lastEventHash"]
    suffix = event_type |> String.replace(".", "_") |> String.replace("-", "_")
    operation_id = "#{suffix}_#{attempt_id}"
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    event = %{
      "schemaVersion" => "1.0",
      "eventId" => "event_#{operation_id}",
      "occurredAt" => occurred_at,
      "scopeType" => "run",
      "scopeId" => run_id,
      "sequence" => sequence,
      "previousEventHash" => previous_hash,
      "correlationId" => run_id,
      "operationId" => operation_id,
      "repositoryId" => repository["repository_id"],
      "issueNumber" => issue.native_ref["issueNumber"],
      "runId" => run_id,
      "attemptId" => attempt_id,
      "actor" => %{"type" => "runner", "subjectId" => runner_id()},
      "runner" => runner_identity(),
      "eventType" => event_type,
      "status" => "running",
      "summary" => summary,
      "references" => %{"branch" => issue.branch_name},
      "evidence" => [],
      "redaction" => %{"applied" => true, "policyVersion" => "1.0"},
      "retention" => %{"category" => "permanent"},
      "payload" => %{}
    }

    hash = event |> CanonicalJson.encode() |> IO.iodata_to_binary() |> sha256()
    {:ok, Map.put(event, "eventHash", hash)}
  rescue
    error -> {:error, {:audit_event_build_failed, error}}
  end

  defp runner_identity do
    %{
      "id" => runner_id(),
      "type" => "local",
      "orchestratorVersion" => to_string(Application.spec(:symphony_elixir, :vsn) || "unknown")
    }
  end

  defp runner_id, do: System.get_env("BOS_RUNNER_ID") || "x1"

  defp sha256(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp repository_query(repository) do
    repository_body(repository)
    |> Enum.map(fn {key, value} ->
      query_key = if key == "repositoryId", do: "repositoryId", else: key
      {query_key, value}
    end)
  end

  defp repository_body(repository) do
    %{
      "repositoryId" => repository["repository_id"],
      "owner" => repository["owner"],
      "repo" => repository["repo"]
    }
  end

  defp repositories, do: repositories(Config.settings!().tracker)

  defp repositories(tracker_settings) do
    provider = tracker_settings.provider || %{}
    provider["repositories"] || []
  end

  defp find_repository(repository_id) do
    case Enum.find(repositories(), &(&1["repository_id"] == repository_id)) do
      nil -> {:error, {:unknown_game_api_repository, repository_id}}
      repository -> {:ok, repository}
    end
  end

  defp invalid_repository?(repository) do
    not is_map(repository) or
      blank?(repository["repository_id"]) or
      blank?(repository["owner"]) or
      blank?(repository["repo"])
  end

  defp endpoint(tracker_settings) do
    tracker_settings.endpoint || System.get_env("BOS_API_BASE_URL") || ""
  end

  defp new_run_id(issue_number) do
    timestamp = System.system_time(:millisecond)
    "run_#{issue_number}_#{timestamp}"
  end

  defp maybe_add_header(headers, _name, value) when not is_binary(value) or value == "", do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
