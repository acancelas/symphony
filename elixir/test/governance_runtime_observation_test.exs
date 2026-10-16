defmodule SymphonyElixir.GovernanceRuntimeObservationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceHostEvidence, as: Evidence
  alias SymphonyElixir.GovernanceProcess

  setup do
    port = Port.open({:spawn_executable, ~c"/usr/bin/cat"}, [:binary, :exit_status])
    on_exit(fn -> GovernanceProcess.stop(port) end)
    {:os_pid, pid} = Port.info(port, :os_pid)
    marker = String.duplicate("a", 64)
    {:ok, witness} = GovernanceProcess.witness(pid, marker)
    context = %{sha: String.duplicate("b", 40), issue: %{native_ref: %{"runId" => "fixture-run"}}, principal: %{invocation_id: "owner-a"}}

    execution = %{
      admission: %{
        "reservationId" => "reservation-a",
        "executionId" => "execution-a",
        "workerId" => "worker-a",
        "authorityGeneration" => 1
      },
      ownership: %{generation: 1}
    }

    measurement = %{
      sequence: 2,
      uncachedInputTokens: 17,
      wallTimeSeconds: 3,
      observedAt: DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, context: context, execution: execution, witness: witness, measurement: measurement, port: port}
  end

  test "emits exactly the backend accounting envelope with no acceptance claim or raw marker", f do
    assert {:ok, artifact} = Evidence.runtime_observation(f.context, f.execution, f.witness, f.measurement, "running")
    assert artifact["acceptanceCriteria"] == [%{"id" => "runtime_usage", "name" => "Host runtime observation", "status" => "inconclusive", "verified" => false}]
    assert artifact["checks"] == [] and artifact["status"] == "inconclusive"
    assert [observation] = artifact["artifacts"]
    assert observation["usage"] == %{"uncachedInputTokens" => 17, "wallTimeSeconds" => 3}
    refute observation["processWitness"]["processReaped"]
    refute Jason.encode!(artifact) =~ f.witness["marker"]
  end

  test "terminal observations require real process absence; running cannot resurrect a retired child", f do
    assert {:error, _} = Evidence.runtime_observation(f.context, f.execution, f.witness, f.measurement, "worker_stopped")
    GovernanceProcess.stop(f.port)
    assert {:ok, artifact} = Evidence.runtime_observation(f.context, f.execution, f.witness, f.measurement, "worker_stopped")
    assert hd(artifact["artifacts"])["processWitness"]["processReaped"]
    assert {:error, _} = Evidence.runtime_observation(f.context, f.execution, f.witness, f.measurement, "running")
  end

  test "unknown late usage remains unknown and does not require or fabricate a reaping witness", f do
    measurement = %{f.measurement | uncachedInputTokens: nil, wallTimeSeconds: nil}
    assert {:ok, artifact} = Evidence.runtime_observation(f.context, f.execution, nil, measurement, "charge_only")
    observation = hd(artifact["artifacts"])
    assert observation["usage"] == %{"uncachedInputTokens" => nil, "wallTimeSeconds" => nil}
    assert observation["processWitness"] == nil
    assert {:error, _} = Evidence.runtime_observation(f.context, f.execution, f.witness, measurement, "running")
    assert {:error, _} = Evidence.runtime_observation(f.context, f.execution, f.witness, f.measurement, "completed")
  end
end
