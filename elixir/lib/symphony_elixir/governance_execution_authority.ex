defmodule SymphonyElixir.GovernanceExecutionAuthority do
  @moduledoc "Uncached server authority plus real Git ancestry; no caller READY or approval flags."
  def check(context, source, admission \\ nil, now \\ DateTime.utc_now()) do
    authority = get_in(source, ["governance", "developmentExecution"])
    readiness = get_in(source, ["governance", "readiness"])
    planning = get_in(source, ["governance", "phases", "planning"])
    claim = source["claim"] || %{}

    with true <- is_map(authority) and authority["protocolVersion"] == 1 and authority["active"] == true,
         true <- is_binary(authority["epoch"]) and byte_size(authority["epoch"]) > 0,
         true <- is_integer(authority["authorityGeneration"]) and authority["authorityGeneration"] > 0,
         true <- is_binary(authority["sourcePublicationId"]) and is_binary(authority["budgetScopeId"]) and is_binary(authority["approvalId"]),
         true <- fresh?(authority["lastObservedAt"], now, 30),
         true <- is_map(planning) and planning["status"] != "failed" and get_in(planning, ["verdict", "status"]) == "passed",
         true <- get_in(planning, ["verdict", "verdict"]) in ["APPROVED", "APPROVED_WITH_NOTES"],
         true <- planning["planHash"] == context.manifest["planHash"] and planning["catalogCommitSha"] == context.manifest["catalogCommitSha"],
         true <- is_map(readiness) and readiness["state"] == "READY" and readiness["status"] == "passed",
         true <- readiness["planHash"] == context.manifest["planHash"] and readiness["catalogCommitSha"] == context.manifest["catalogCommitSha"],
         true <- readiness["candidateCommitSha"] == authority["baselineCommitSha"] and authority["baselineCommitSha"] == planning["candidateCommitSha"],
         true <- claim["runId"] == context.issue.native_ref["runId"] and future?(claim["leaseExpiresAt"], now),
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

  def admission_matches?(admission, authority, context, now) do
    admission["ownerInvocationId"] == context.principal.invocation_id and
      admission["authorityGeneration"] == authority["authorityGeneration"] and admission["sourcePublicationId"] == authority["sourcePublicationId"] and
      admission["budgetScopeId"] == authority["budgetScopeId"] and future?(admission["deadline"], now) and
      Enum.all?(~w(reservationId attemptId executionId workerId), &(is_binary(admission[&1]) and byte_size(admission[&1]) > 0)) and
      is_integer(admission["reservedUncachedInputTokens"]) and admission["reservedUncachedInputTokens"] > 0 and
      is_integer(admission["reservedDurationSeconds"]) and admission["reservedDurationSeconds"] > 0
  end

  defp within_budget?(authority) do
    limits = authority["limits"] || %{}
    consumed = authority["consumed"] || %{}
    reserved = authority["reserved"] || %{}

    Enum.all?([{"maxAttempts", "attempts"}, {"maxUncachedInputTokens", "uncachedInputTokens"}, {"maximumDurationSeconds", "wallTimeSeconds"}], fn {ceiling, count} ->
      maximum = limits[ceiling]
      used = consumed[count]
      pending = reserved[count]
      is_integer(maximum) and maximum > 0 and is_integer(used) and used >= 0 and is_integer(pending) and pending >= 0 and used + pending <= maximum
    end) and limits["additionalPurchasesAllowed"] == false and limits["costUsd"] == nil and limits["costMeasurement"] == "unknown"
  end

  defp fresh?(text, now, age) do
    with {:ok, observed, _} <- DateTime.from_iso8601(text), delta = DateTime.diff(now, observed, :millisecond) do
      delta >= -1000 and delta <= age * 1000
    else
      _ -> false
    end
  end

  defp future?(text, now) do
    with {:ok, time, _} <- DateTime.from_iso8601(text), do: DateTime.compare(time, now) == :gt, else: (_ -> false)
  end

  defp git(root, arguments), do: SymphonyElixir.GovernanceTrustedGit.run(root, arguments)
end
