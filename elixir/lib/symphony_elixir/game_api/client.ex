defmodule SymphonyElixir.GameApi.Client do
  @moduledoc """
  Normalized tracker client for the BOS `game-api` gateway.

  It has no GitHub token and never calls GitHub directly.
  """

  alias SymphonyElixir.Config

  @spec fetch_ready_issues() :: {:ok, [map()]} | {:error, term()}
  def fetch_ready_issues do
    repositories()
    |> Enum.reduce_while({:ok, []}, fn repository, {:ok, accumulated} ->
      result =
        request(:get, "/v1/internal/bos/delivery/issues/eligible", params: repository_query(repository) ++ [{"runnerId", System.get_env("BOS_RUNNER_ID") || "x1"}])
        |> response_list("issues")

      case result do
        {:ok, issues} -> {:cont, {:ok, accumulated ++ issues}}
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

  @spec fetch_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_run(repository_id, run_id) when is_binary(repository_id) and is_binary(run_id) do
    with {:ok, repository} <- find_repository(repository_id) do
      request(:get, "/v1/internal/bos/delivery/runs/#{URI.encode(run_id)}", params: repository_query(repository))
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

    options =
      Keyword.merge(options,
        headers: [
          {"accept", "application/json"},
          {"x-internal-token", token},
          {"x-bos-actor-id", "runner:#{runner_id}"},
          {"x-bos-runner-id", runner_id}
        ],
        receive_timeout: 15_000,
        retry: false
      )

    case Req.request(Keyword.merge(options, method: method, url: url)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:game_api_http_error, status}}
      {:error, reason} -> {:error, {:game_api_request_failed, reason}}
    end
  end

  defp response_list({:ok, payload}, key) when is_map(payload) do
    case Map.get(payload, key) do
      values when is_list(values) -> {:ok, values}
      _ -> {:error, {:invalid_game_api_response, key}}
    end
  end

  defp response_list({:error, reason}, _key), do: {:error, reason}

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

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
