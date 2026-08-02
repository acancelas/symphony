defmodule SymphonyElixir.GoalExecutionPolicy do
  @moduledoc """
  Evaluates the one durable Goal approval inherited by every planned or strictly
  derived repair Issue. The policy is pure so pause/resume and recovery make the
  same decision from GitHub-backed projections.
  """

  alias SymphonyElixir.Tracker.Issue

  @approved_decisions ~w(approved approved_with_limits approved_scheduled)
  @security_risks ~w(security privacy permissions billing critical destructive production_migration)
  @architecture_risks ~w(high critical architecture multi_repository production_migration)

  @spec locator(Issue.t()) :: {:ok, String.t(), pos_integer(), map()} | :unscoped | {:error, term()}
  def locator(%Issue{native_ref: native_ref}) when is_map(native_ref) do
    case native_ref["inheritedAuthorization"] do
      nil ->
        :unscoped

      %{"authorizationInherited" => true, "parentGoalId" => goal_id} = authorization ->
        parse_goal_id(goal_id, authorization)

      _ ->
        {:error, :inherited_authorization_missing}
    end
  end

  def locator(%Issue{}), do: :unscoped

  defp parse_goal_id(goal_id, authorization) when is_binary(goal_id) do
    with [repository_id, number] <- String.split(goal_id, "#", parts: 2),
         {issue_number, ""} when issue_number > 0 <- Integer.parse(number) do
      {:ok, repository_id, issue_number, authorization}
    else
      _ -> {:error, :invalid_parent_goal_id}
    end
  end

  defp parse_goal_id(_goal_id, _authorization), do: {:error, :invalid_parent_goal_id}

  @spec evaluate(Issue.t(), map(), DateTime.t()) :: {:ok, map()} | {:pause, atom()} | {:error, term()}
  def evaluate(%Issue{} = issue, execution, now \\ DateTime.utc_now()) when is_map(execution) do
    with {:ok, _repository_id, _goal_number, authorization} <- locator(issue),
         %{} = proposal <- execution["proposal"],
         %{} = approval <- execution["approval"],
         true <- approval["decision"] in @approved_decisions,
         true <- approval["approvalId"] == authorization["goalApprovalId"],
         true <- approval["proposalVersion"] == authorization["goalProposalVersion"],
         :ok <- approved_work_item?(authorization, approval),
         :ok <- repository_approved?(issue, proposal),
         :ok <- within_window(approval["executionWindow"] || proposal["executionWindow"] || %{}, now),
         :ok <- budget_available(execution["consumption"] || %{}, approval) do
      {:ok,
       %{
         approval_id: approval["approvalId"],
         proposal_version: approval["proposalVersion"],
         reviewers: reviewer_roles(proposal),
         scope_frozen: budget_ratio(execution["consumption"] || %{}, approval) >= 0.75
       }}
    else
      :unscoped -> {:ok, %{legacy_unscoped: true, reviewers: ~w(functional quality)}}
      {:pause, reason} -> {:pause, reason}
      false -> {:error, :goal_approval_invalid}
      nil -> {:error, :goal_execution_projection_incomplete}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reviewer_roles(map()) :: [String.t()]
  def reviewer_roles(proposal) when is_map(proposal) do
    risks = MapSet.new(proposal["riskTags"] || [], &String.downcase(to_string(&1)))
    required = proposal["requiredReviewers"] || []
    repositories = proposal["repositories"] || []

    ~w(functional quality)
    |> maybe_add("security", intersects?(risks, @security_risks))
    |> maybe_add("architecture", length(repositories) > 1 or intersects?(risks, @architecture_risks))
    |> Kernel.++(Enum.map(required, &String.downcase(to_string(&1))))
    |> Enum.filter(&(&1 in ~w(functional architecture security quality visual)))
    |> Enum.uniq()
  end

  defp approved_work_item?(authorization, approval) do
    id = authorization["workItemId"]
    approved_ids = Enum.map(approval["approvedIssueIds"] || [], &to_string/1)
    derived_repair = authorization["derived"] == true and is_binary(authorization["repairsCriterionId"])

    if id in approved_ids or derived_repair, do: :ok, else: {:error, :work_item_not_approved}
  end

  defp repository_approved?(%Issue{native_ref: native_ref}, proposal) do
    if native_ref["repositoryId"] in (proposal["repositories"] || []),
      do: :ok,
      else: {:error, :repository_not_approved}
  end

  defp within_window(window, now) do
    with {:ok, not_before} <- parse_optional_datetime(window["notBefore"]),
         {:ok, finish_before} <- parse_optional_datetime(window["mustFinishBefore"]) do
      cond do
        not_before && DateTime.compare(now, not_before) == :lt -> {:pause, :execution_window_not_started}
        finish_before && DateTime.compare(now, finish_before) != :lt -> {:pause, :execution_window_closed}
        true -> :ok
      end
    end
  end

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_execution_window}
    end
  end

  defp parse_optional_datetime(_), do: {:error, :invalid_execution_window}

  defp budget_available(consumption, approval) do
    if consumption["budgetState"] == "exhausted" or budget_ratio(consumption, approval) >= 1,
      do: {:pause, :goal_budget_exhausted},
      else: :ok
  end

  defp budget_ratio(consumption, approval) do
    duration_ratio =
      ratio(consumption["durationSeconds"], approval["maximumDurationSeconds"])

    token_ratio =
      ratio(consumption["totalTokens"], approval["maximumTotalTokens"])

    max(duration_ratio, token_ratio)
  end

  defp ratio(value, maximum) when is_number(value) and is_number(maximum) and maximum > 0,
    do: value / maximum

  defp ratio(_, _), do: 0.0

  defp intersects?(set, values), do: Enum.any?(values, &MapSet.member?(set, &1))
  defp maybe_add(values, value, true), do: values ++ [value]
  defp maybe_add(values, _value, false), do: values
end
