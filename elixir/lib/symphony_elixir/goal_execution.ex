defmodule SymphonyElixir.GoalExecution do
  @moduledoc """
  Evaluates the immutable authorization granted by a single Goal approval.

  The gateway remains authoritative for persistence and aggregate consumption.
  This module deliberately makes no local budget reservation: every new turn is
  checked against the latest confirmed projection, so process restarts and
  pause/resume cannot replenish an execution window or token ceiling.
  """

  @freeze_ratio 0.75

  @type task_kind :: :included_issue | :derived_repair
  @type decision :: :unmanaged | {:ok, map()} | {:pause, atom(), map()}

  @spec check(module(), map(), task_kind(), map()) :: decision() | {:error, term()}
  def check(client, issue, task_kind, requested \\ %{})

  def check(client, %{native_ref: native_ref}, task_kind, requested) when is_map(native_ref) do
    if function_exported?(client, :fetch_goal_execution, 2) do
      with repository_id when is_binary(repository_id) <- native_ref["repositoryId"],
           issue_number when is_integer(issue_number) <- native_ref["issueNumber"],
           {:ok, projection} <- client.fetch_goal_execution(repository_id, issue_number) do
        evaluate(projection, issue_number, task_kind, requested)
      else
        nil -> :unmanaged
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_goal_execution_identity}
      end
    else
      :unmanaged
    end
  end

  def check(_client, _issue, _task_kind, _requested), do: :unmanaged

  @spec evaluate(map(), pos_integer(), task_kind(), map(), DateTime.t()) :: decision()
  def evaluate(projection, issue_number, task_kind, requested \\ %{}, now \\ DateTime.utc_now())
      when is_map(projection) and is_integer(issue_number) and
             task_kind in [:included_issue, :derived_repair] and is_map(requested) do
    proposal = value(projection, "proposal")
    approval = value(projection, "approval")

    cond do
      not is_map(proposal) ->
        :unmanaged

      not approved?(approval, proposal) ->
        {:pause, :goal_approval_required, snapshot(projection)}

      pending_change?(projection) ->
        {:pause, :goal_change_decision_required, snapshot(projection)}

      not authorized_task?(proposal, issue_number, task_kind) ->
        {:pause, :goal_scope_change_required, snapshot(projection)}

      outside_window?(proposal, now) ->
        {:pause, :goal_execution_window_closed, snapshot(projection)}

      exceeds?(proposal, projection, requested) ->
        {:pause, :goal_budget_exhausted, snapshot(projection)}

      true ->
        {:ok,
         snapshot(projection)
         |> Map.put(:authorization_id, authorization_id(projection, approval))
         |> Map.put(:scope_frozen, at_freeze_threshold?(proposal, projection))}
    end
  end

  defp approved?(approval, proposal) when is_map(approval) do
    status = value(approval, "status")
    approved_version = value(approval, "proposalVersion") || value(approval, "proposal_version")
    proposal_version = value(proposal, "version")
    status == "approved" and (is_nil(proposal_version) or approved_version == proposal_version)
  end

  defp approved?(_, _), do: false

  defp pending_change?(projection) do
    request = value(projection, "scopeChangeRequest") || value(projection, "scope_change_request")
    decision = value(projection, "scopeChangeDecision") || value(projection, "scope_change_decision")
    is_map(request) and not (is_map(decision) and value(decision, "status") in ["approved", "rejected"])
  end

  defp authorized_task?(proposal, issue_number, :included_issue) do
    issue_number in (value(proposal, "includedIssueNumbers") || value(proposal, "included_issue_numbers") || [])
  end

  defp authorized_task?(proposal, _issue_number, :derived_repair) do
    (value(proposal, "repairPolicy") || value(proposal, "repair_policy")) == "strictly_derived"
  end

  defp outside_window?(proposal, now) do
    window = value(proposal, "executionWindow") || value(proposal, "execution_window") || %{}
    starts_at = parse_datetime(value(window, "startsAt") || value(window, "starts_at"))
    ends_at = parse_datetime(value(window, "endsAt") || value(window, "ends_at"))
    (starts_at && DateTime.before?(now, starts_at)) || (ends_at && not DateTime.before?(now, ends_at))
  end

  defp exceeds?(proposal, projection, requested) do
    limits = value(proposal, "budget") || %{}
    used = value(projection, "consumption") || %{}

    Enum.any?(
      [{"maxAttempts", "attempts"}, {"maxTokens", "tokens"}, {"maxCostUsd", "costUsd"}],
      fn {limit_key, used_key} ->
        limit = number(value(limits, limit_key))
        consumed = number(value(used, used_key))
        increment = number(value(requested, used_key))
        limit != nil and ((consumed || 0) >= limit or (consumed || 0) + (increment || 0) > limit)
      end
    )
  end

  defp at_freeze_threshold?(proposal, projection) do
    limits = value(proposal, "budget") || %{}
    used = value(projection, "consumption") || %{}

    Enum.any?([{"maxAttempts", "attempts"}, {"maxTokens", "tokens"}, {"maxCostUsd", "costUsd"}], fn {limit_key, used_key} ->
      limit = number(value(limits, limit_key))
      consumed = number(value(used, used_key))
      limit != nil and limit > 0 and (consumed || 0) / limit >= @freeze_ratio
    end)
  end

  defp authorization_id(projection, approval) do
    authorization = value(projection, "authorization") || %{}

    value(authorization, "authorizationId") || value(authorization, "authorization_id") ||
      value(approval, "approvalId") || value(approval, "approval_id")
  end

  defp snapshot(projection) do
    %{
      proposal: value(projection, "proposal"),
      approval: value(projection, "approval"),
      consumption: value(projection, "consumption") || %{}
    }
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
  defp number(value) when is_integer(value) or is_float(value), do: value
  defp number(_), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
        _ -> nil
      end)
  end

  defp value(_, _), do: nil
end
