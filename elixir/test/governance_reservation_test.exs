defmodule SymphonyElixir.GovernanceReservationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceReservation
  @now ~U[2026-10-15 10:00:00Z]
  defp context, do: %{issue: %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => 69, "runId" => "run69"}}}

  defp run,
    do: %{
      "repositoryId" => "symphony",
      "issueNumber" => 69,
      "runId" => "run69",
      "status" => "running",
      "runner" => %{"id" => "original-runner"}
    }

  defp source,
    do: %{
      "number" => 69,
      "state" => "open",
      "labels" => ["agent:running"],
      "claim" => %{"runId" => "run69", "runnerId" => "original-runner", "leaseExpiresAt" => "2026-10-15T11:00:00Z"}
    }

  test "ready intake with existing Run accepts new_run and resumed lease only after authentic matching readback" do
    for disposition <- ["new_run", "resume_run"] do
      response = %{"status" => "completed", "disposition" => disposition}
      assert :ok = GovernanceReservation.verify_response(response, context(), run(), source(), @now)

      assert {:error, _} =
               GovernanceReservation.verify_response(response, context(), run(), Map.put(source(), "claim", nil), @now)
    end

    assert {:error, _} =
             GovernanceReservation.verify_response(
               %{"status" => "blocked", "disposition" => "new_run"},
               context(),
               run(),
               source(),
               @now
             )
  end

  test "foreign Run, runner, Issue and invalid or expired leases cannot authorize preparation" do
    for changed <- [
          put_in(source(), ["claim", "runId"], "other-run"),
          put_in(source(), ["claim", "runnerId"], "other-runner"),
          put_in(source(), ["claim", "leaseExpiresAt"], "2026-10-15T09:59:59Z"),
          put_in(source(), ["claim", "leaseExpiresAt"], "not-a-time"),
          Map.put(source(), "number", 70),
          Map.put(source(), "state", "closed"),
          Map.put(source(), "labels", ["agent:ready"])
        ] do
      assert {:error, _} = GovernanceReservation.verify(context(), run(), changed, @now)
    end

    assert {:error, _} = GovernanceReservation.verify(context(), Map.put(run(), "runId", "other-run"), source(), @now)
  end
end
