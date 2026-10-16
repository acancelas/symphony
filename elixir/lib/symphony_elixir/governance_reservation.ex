defmodule SymphonyElixir.GovernanceReservation do
  @moduledoc "Validate authentic preparation leases independently of new_run/resume_run disposition names."
  @spec verify_response(map(), map(), map(), map(), DateTime.t()) :: :ok | {:error, atom()}
  def verify_response(result, context, run, source, now \\ DateTime.utc_now()) do
    if result["status"] == "completed",
      do: verify(context, run, source, now),
      else: {:error, :governance_existing_run_reservation_denied}
  end

  @spec run_matches?(map(), map()) :: boolean()
  def run_matches?(context, run) do
    native = context.issue.native_ref

    run["runId"] == native["runId"] and run["issueNumber"] == native["issueNumber"] and
      run["repositoryId"] == native["repositoryId"] and
      is_binary(get_in(run, ["runner", "id"])) and get_in(run, ["runner", "id"]) != "" and run["status"] == "running"
  end

  @spec verify(map(), map(), map(), DateTime.t()) :: :ok | {:error, atom()}
  def verify(context, run, source, now \\ DateTime.utc_now()) do
    claim = source["claim"]

    with true <- run_matches?(context, run),
         true <- source["number"] == context.issue.native_ref["issueNumber"] and source["state"] == "open",
         true <- is_map(claim) and claim["runId"] == run["runId"] and claim["runnerId"] == get_in(run, ["runner", "id"]),
         true <- Enum.any?(["agent:running", "agent:merging"], &(&1 in (source["labels"] || []))),
         {:ok, expiry, _} <- DateTime.from_iso8601(claim["leaseExpiresAt"]),
         true <- DateTime.compare(expiry, now) == :gt do
      :ok
    else
      _ -> {:error, :governance_existing_run_lease_unverified}
    end
  rescue
    _ -> {:error, :governance_existing_run_lease_unverified}
  end
end
