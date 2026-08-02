defmodule SymphonyElixir.GoalExecution do
  @moduledoc """
  Evaluates the immutable authorization granted by a single Goal approval.

  The gateway remains authoritative for authorization and aggregate consumption.
  Every new turn inherits the exact approved proposal and asks the gateway to
  check the shared execution window and ceilings. The local evaluation is a
  fail-fast guard; it never replenishes or reserves budget on process restart.
  """

  @freeze_ratio 0.75

  @type task_kind :: :included_issue | :derived_repair
  @type decision :: :unmanaged | {:ok, map()} | {:pause, atom() | String.t(), map()}

  @spec check(module(), map(), task_kind(), map(), String.t()) :: decision() | {:error, term()}
  def check(client, issue, task_kind, requested \\ %{}, check_key \\ "default")

  def check(client, %{native_ref: native_ref}, task_kind, requested, check_key)
      when is_map(native_ref) and is_binary(check_key) do
    if function_exported?(client, :fetch_goal_execution, 2) do
      with repository_id when is_binary(repository_id) <- native_ref["repositoryId"],
           issue_number when is_integer(issue_number) <- native_ref["issueNumber"],
           {:ok, projection} <- client.fetch_goal_execution(repository_id, issue_number),
           decision <- evaluate(projection, issue_number, task_kind, requested),
           {:ok, decision} <-
             authorize(client, native_ref, projection, issue_number, task_kind, requested, check_key, decision) do
        decision
      else
        nil -> :unmanaged
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_goal_execution_identity}
      end
    else
      :unmanaged
    end
  end

  def check(_client, _issue, _task_kind, _requested, _check_key), do: :unmanaged

  defp authorize(_client, _native_ref, _projection, _issue_number, _task_kind, _requested, _check_key, decision)
       when decision != :unmanaged and elem(decision, 0) != :ok,
       do: {:ok, decision}

  defp authorize(_client, _native_ref, _projection, _issue_number, _task_kind, _requested, _check_key, :unmanaged),
    do: {:ok, :unmanaged}

  defp authorize(client, native_ref, projection, issue_number, task_kind, requested, check_key, {:ok, snapshot}) do
    if function_exported?(client, :inherit_goal_authorization, 1) and
         function_exported?(client, :check_goal_execution, 1) do
      with {:ok, identity} <- authorization_identity(projection, native_ref, issue_number, task_kind),
           {:ok, inherited} <- client.inherit_goal_authorization(identity),
           authorization_id <- inherited_authorization_id(inherited, identity),
           {:ok, checked} <-
             client.check_goal_execution(%{
               "repositoryId" => identity["repositoryId"],
               "authorizationId" => authorization_id,
               "checkedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
               "goalIssueNumber" => identity["goalIssueNumber"],
               "issueNumber" => issue_number,
               "operationId" => operation_id(native_ref, task_kind, "check_#{check_key}"),
               "requestedConsumption" => requested
             }) do
        gateway_decision(checked, Map.put(snapshot, :authorization_id, authorization_id))
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_goal_execution_check}
      end
    else
      {:error, :goal_execution_gateway_contract_unavailable}
    end
  end

  defp inherited_authorization_id(inherited, identity) do
    value(inherited, "authorizationId") || value(inherited, "authorization_id") || identity["authorizationId"]
  end

  defp authorization_identity(projection, native_ref, issue_number, task_kind) do
    proposal = value(projection, "proposal") || %{}
    approval = value(projection, "approval") || %{}

    identity = %{
      "repositoryId" => native_ref["repositoryId"],
      "authorizationId" => authorization_id(projection, approval),
      "approvalId" => first_value([{approval, "approvalId"}, {approval, "approval_id"}]),
      "goalIssueNumber" => goal_issue_number(projection, proposal),
      "issueNumber" => issue_number,
      "operationId" => operation_id(native_ref, task_kind, "inherit"),
      "proposalId" => first_value([{proposal, "proposalId"}, {proposal, "proposal_id"}]),
      "proposalVersion" => value(proposal, "version"),
      "taskKind" => Atom.to_string(task_kind)
    }

    identity =
      if task_kind == :derived_repair,
        do: Map.put(identity, "derivedFromIssueNumber", issue_number),
        else: identity

    required = ~w(repositoryId approvalId goalIssueNumber proposalId proposalVersion)

    if Enum.all?(required, &(not is_nil(identity[&1]))) do
      {:ok, identity}
    else
      {:error, :invalid_goal_authorization_identity}
    end
  end

  defp gateway_decision(checked, snapshot) do
    status = value(checked, "status") || value(checked, "decision")

    cond do
      status in ["authorized", "approved", "allowed", "ok"] ->
        {:ok, {:ok, snapshot}}

      value(checked, "authorized") == true ->
        {:ok, {:ok, snapshot}}

      status in ["paused", "blocked", "denied", "exhausted"] ->
        reason = value(checked, "reason") || value(checked, "code") || "goal_execution_paused"
        {:ok, {:pause, reason, snapshot}}

      true ->
        {:error, :invalid_goal_execution_check}
    end
  end

  defp operation_id(native_ref, task_kind, action) do
    run_id = native_ref["runId"] || "unknown_run"
    "goal_execution_#{action}_#{run_id}_#{task_kind}"
  end

  defp goal_issue_number(projection, proposal) do
    first_value([
      {projection, "goalIssueNumber"},
      {projection, "goal_issue_number"},
      {proposal, "issueNumber"},
      {proposal, "issue_number"}
    ])
  end

  defp first_value(candidates) do
    Enum.find_value(candidates, fn {map, key} -> value(map, key) end)
  end

  @spec evaluate(map(), pos_integer(), task_kind(), map(), DateTime.t()) :: decision()
  def evaluate(projection, issue_number, task_kind, requested \\ %{}, now \\ DateTime.utc_now())
      when is_map(projection) and is_integer(issue_number) and
             task_kind in [:included_issue, :derived_repair] and is_map(requested) do
    proposal = value(projection, "proposal")
    approval = value(projection, "approval")

    pause_reason =
      if is_map(proposal) do
        authorization_pause_reason(projection, proposal, approval, issue_number, task_kind) ||
          resource_pause_reason(projection, proposal, requested, now)
      else
        :invalid_goal_execution_projection
      end

    case pause_reason do
      nil ->
        {:ok,
         snapshot(projection)
         |> Map.put(:authorization_id, authorization_id(projection, approval))
         |> Map.put(:scope_frozen, at_freeze_threshold?(proposal, projection))}

      reason ->
        {:pause, reason, snapshot(projection)}
    end
  end

  defp authorization_pause_reason(projection, proposal, approval, issue_number, task_kind) do
    cond do
      not approved?(approval, proposal) ->
        :goal_approval_required

      pending_change?(projection) ->
        :goal_change_decision_required

      not authorized_task?(proposal, issue_number, task_kind) ->
        :goal_scope_change_required

      true ->
        nil
    end
  end

  defp resource_pause_reason(projection, proposal, requested, now) do
    cond do
      not valid_resource_projection?(proposal, projection, requested) -> :invalid_goal_execution_projection
      outside_window?(proposal, now) -> :goal_execution_window_closed
      exceeds?(proposal, projection, requested) -> :goal_budget_exhausted
      true -> nil
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
    window = value(proposal, "executionWindow") || value(proposal, "execution_window")
    starts_at = parse_datetime(value(window, "startsAt") || value(window, "starts_at"))
    ends_at = parse_datetime(value(window, "endsAt") || value(window, "ends_at"))
    DateTime.before?(now, starts_at) || not DateTime.before?(now, ends_at)
  end

  defp valid_resource_projection?(proposal, projection, requested) do
    window = value(proposal, "executionWindow") || value(proposal, "execution_window")
    starts_at = parse_datetime(value(window, "startsAt") || value(window, "starts_at"))
    ends_at = parse_datetime(value(window, "endsAt") || value(window, "ends_at"))
    limits = value(proposal, "budget")
    used = value(projection, "consumption")

    is_map(window) and is_struct(starts_at, DateTime) and is_struct(ends_at, DateTime) and
      DateTime.before?(starts_at, ends_at) and is_map(limits) and is_map(used) and
      valid_positive_number?(value(limits, "maxAttempts")) and
      valid_optional_positive_number?(value(limits, "maxTokens")) and
      valid_optional_positive_number?(value(limits, "maxCostUsd")) and
      valid_consumption?(limits, used) and valid_requested_consumption?(requested)
  end

  defp valid_consumption?(limits, used) do
    Enum.all?([{"maxAttempts", "attempts"}, {"maxTokens", "tokens"}, {"maxCostUsd", "costUsd"}], fn
      {limit_key, used_key} ->
        is_nil(value(limits, limit_key)) or valid_nonnegative_number?(value(used, used_key))
    end)
  end

  defp valid_requested_consumption?(requested) do
    Enum.all?(~w(attempts tokens costUsd), fn key ->
      is_nil(value(requested, key)) or valid_nonnegative_number?(value(requested, key))
    end)
  end

  defp valid_positive_number?(value), do: is_number(value) and value > 0
  defp valid_optional_positive_number?(nil), do: true
  defp valid_optional_positive_number?(value), do: valid_positive_number?(value)
  defp valid_nonnegative_number?(value), do: is_number(value) and value >= 0

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
