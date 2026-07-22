defmodule SymphonyElixir.GameApi.Adapter do
  @moduledoc """
  BOS tracker adapter backed exclusively by `game-api`.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings), do: client_module().validate_config(tracker_settings)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- client_module().fetch_issues_by_states(states) do
      {:ok, Enum.map(issues, &normalize_issue/1)}
    end
  end

  @spec reconcile_terminal_runs() :: {:ok, [map()]} | {:error, term()}
  def reconcile_terminal_runs, do: client_module().reconcile_terminal_runs()

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, issues} ->
      with {:ok, {repository_id, issue_number}} <- issue_locator(issue_id),
           {:ok, payload} <- client_module().fetch_issue(repository_id, issue_number) do
        {:cont, {:ok, [normalize_issue(payload) | issues]}}
      else
        {:error, {:game_api_http_error, 404}} -> {:cont, {:ok, issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec claim_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def claim_issue(%Issue{} = issue) do
    issue_number = issue.native_ref["issueNumber"]
    repository_id = issue.native_ref["repositoryId"]
    existing_run_id = issue.native_ref["runId"]

    with {:ok, result} <- client_module().claim_issue(repository_id, issue_number, existing_run_id),
         "completed" <- result["status"] do
      claim = result["claim"] || %{}
      native_ref = Map.put(issue.native_ref || %{}, "runId", claim["runId"])
      labels = result |> Map.get("issue", %{}) |> Map.get("labels", [])
      state = if labels == [], do: "agent:running", else: current_state(labels)
      {:ok, %{issue | native_ref: native_ref, state: state}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:game_api_claim_rejected, other}}
    end
  end

  @spec heartbeat_issue(Issue.t()) :: :ok | {:error, term()}
  def heartbeat_issue(%Issue{native_ref: native_ref}) do
    with run_id when is_binary(run_id) <- native_ref["runId"],
         {:ok, %{"status" => "completed"}} <-
           client_module().heartbeat_issue(native_ref["repositoryId"], native_ref["issueNumber"], run_id) do
      :ok
    else
      nil -> {:error, :missing_run_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:game_api_heartbeat_rejected, other}}
    end
  end

  @spec release_issue(Issue.t(), String.t()) :: :ok | {:error, term()}
  def release_issue(%Issue{native_ref: native_ref}, reason) when is_binary(reason) do
    with run_id when is_binary(run_id) <- native_ref["runId"],
         {:ok, %{"status" => "completed"}} <-
           client_module().release_issue(
             native_ref["repositoryId"],
             native_ref["issueNumber"],
             run_id,
             reason
           ) do
      :ok
    else
      nil -> {:error, :missing_run_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:game_api_release_rejected, other}}
    end
  end

  @spec start_execution(Issue.t(), pos_integer()) :: {:ok, Issue.t()} | {:error, term()}
  def start_execution(%Issue{} = issue, attempt_number)
      when is_integer(attempt_number) and attempt_number > 0 do
    with {:ok, attempt_id} <- client_module().start_execution(issue, attempt_number) do
      {:ok, %{issue | native_ref: Map.put(issue.native_ref || %{}, "attemptId", attempt_id)}}
    end
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: []

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, _arguments, _opts) do
    %{"success" => false, "output" => "Unsupported game-api tracker tool: #{tool}"}
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings),
    do: ["BOS_API_INTERNAL_TOKEN", "BOS_RUNNER_ACTION_TOKEN"]

  defp normalize_issue(payload) do
    labels = payload["labels"] || []
    claim = payload["claim"] || %{}
    issue_number = payload["number"]
    repository_id = payload["_repositoryId"] || repository_id()

    %Issue{
      id: "#{repository_id}##{issue_number}",
      native_ref: %{
        "issueNumber" => issue_number,
        "repositoryId" => repository_id,
        "repositoryOwner" => payload["_repositoryOwner"],
        "repositoryName" => payload["_repositoryName"],
        "repositoryCloneUrl" => payload["_repositoryCloneUrl"],
        "runId" => claim["runId"]
      },
      identifier: "#{repository_id}-#{issue_number}",
      title: payload["title"],
      description: payload["body"],
      priority: 0,
      state: current_state(labels),
      branch_name: "bos/issue-#{issue_number}",
      url: payload["url"],
      labels: labels,
      blocked_by: [],
      dispatchable: "agent:ready" in labels or "agent:running" in labels,
      updated_at: parse_datetime(payload["updatedAt"])
    }
  end

  defp current_state(labels) do
    Enum.find(labels, "agent:ready", &String.starts_with?(&1, "agent:"))
  end

  defp issue_locator(issue_id) do
    case String.split(issue_id, "#", parts: 2) do
      [repository_id, number] when repository_id != "" ->
        case Integer.parse(number) do
          {parsed, ""} when parsed > 0 -> {:ok, {repository_id, parsed}}
          _ -> {:error, {:invalid_game_api_issue_id, issue_id}}
        end

      _ ->
        {:error, {:invalid_game_api_issue_id, issue_id}}
    end
  end

  defp repository_id, do: "unknown"

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp client_module do
    Application.get_env(:symphony_elixir, :game_api_client_module, Client)
  end
end
