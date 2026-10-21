defmodule SymphonyElixir.GovernanceExecutionAuthority do
  @moduledoc "Uncached server authority plus real Git ancestry; no caller READY or approval flags."
  alias SymphonyElixir.GovernanceTrustedGit

  @budget_axes [
    {"maxAttempts", "attempts"},
    {"maxUncachedInputTokens", "uncachedInputTokens"},
    {"maximumDurationSeconds", "wallTimeSeconds"}
  ]

  @spec check(map(), map(), map() | nil, DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def check(context, source, admission \\ nil, now \\ DateTime.utc_now()) do
    authority = get_in(source, ["governance", "developmentExecution"])
    readiness = get_in(source, ["governance", "readiness"])
    planning = get_in(source, ["governance", "phases", "planning"])
    claim = source["claim"] || %{}

    with true <- active_authority?(authority, now),
         true <- approved_plan?(planning, context.manifest),
         true <- ready_baseline?(readiness, planning, authority, context.manifest),
         true <- claim["runId"] == context.issue.native_ref["runId"],
         true <- future?(claim["leaseExpiresAt"], now),
         true <- within_budget?(authority),
         {head, 0} <- git(context.workspace, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == context.sha,
         {_, 0} <- git(context.workspace, ["merge-base", "--is-ancestor", authority["baselineCommitSha"], context.sha]),
         true <- admission == nil or admission_matches?(admission, authority, context, now) do
      {:ok, authority}
    else
      _ -> {:error, :governance_execution_authority_unverified}
    end
  rescue
    _ -> {:error, :governance_execution_authority_unverified}
  end

  @spec admission_matches?(map(), map(), map(), DateTime.t()) :: boolean()
  def admission_matches?(admission, authority, context, now) do
    admission_scope_matches?(admission, authority, context) and
      future?(admission["deadline"], now) and
      Enum.all?(~w(reservationId attemptId executionId workerId), &nonempty?(admission[&1])) and
      Enum.all?(~w(reservedUncachedInputTokens reservedDurationSeconds), &positive?(admission[&1]))
  end

  defp active_authority?(authority, now) when is_map(authority) do
    authority["protocolVersion"] == 1 and authority["active"] == true and
      nonempty?(authority["epoch"]) and positive?(authority["authorityGeneration"]) and
      Enum.all?(~w(sourcePublicationId budgetScopeId approvalId), &is_binary(authority[&1])) and
      fresh?(authority["lastObservedAt"], now, 30)
  end

  defp active_authority?(_, _), do: false

  defp approved_plan?(planning, manifest) when is_map(planning) do
    planning["status"] != "failed" and get_in(planning, ["verdict", "status"]) == "passed" and
      get_in(planning, ["verdict", "verdict"]) in ["APPROVED", "APPROVED_WITH_NOTES"] and
      definition_matches?(planning, manifest)
  end

  defp approved_plan?(_, _), do: false

  defp ready_baseline?(readiness, planning, authority, manifest) when is_map(readiness) do
    readiness["state"] == "READY" and readiness["status"] == "passed" and
      definition_matches?(readiness, manifest) and
      readiness["candidateCommitSha"] == authority["baselineCommitSha"] and
      authority["baselineCommitSha"] == planning["candidateCommitSha"]
  end

  defp ready_baseline?(_, _, _, _), do: false

  defp definition_matches?(value, manifest) do
    Enum.all?(~w(planHash catalogCommitSha), &(value[&1] == manifest[&1]))
  end

  defp admission_scope_matches?(admission, authority, context) do
    admission["ownerInvocationId"] == context.principal.invocation_id and
      Enum.all?(~w(authorityGeneration sourcePublicationId budgetScopeId), &(admission[&1] == authority[&1]))
  end

  defp within_budget?(authority) do
    limits = authority["limits"] || %{}
    consumed = authority["consumed"] || %{}
    reserved = authority["reserved"] || %{}

    Enum.all?(@budget_axes, &axis_within_budget?(&1, limits, consumed, reserved)) and
      limits["additionalPurchasesAllowed"] == false and limits["costUsd"] == nil and
      limits["costMeasurement"] == "unknown"
  end

  defp axis_within_budget?({ceiling, count}, limits, consumed, reserved) do
    maximum = limits[ceiling]
    used = consumed[count]
    pending = reserved[count]
    positive?(maximum) and nonnegative?(used) and nonnegative?(pending) and used + pending <= maximum
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp fresh?(text, now, age) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, observed, _} ->
        delta = DateTime.diff(now, observed, :millisecond)
        delta >= -1000 and delta <= age * 1000

      _ ->
        false
    end
  end

  defp fresh?(_, _, _), do: false

  defp future?(text, now) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> DateTime.compare(time, now) == :gt
      _ -> false
    end
  end

  defp future?(_, _), do: false

  defp git(root, arguments), do: GovernanceTrustedGit.run(root, arguments)
end
