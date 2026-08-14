defmodule SymphonyElixir.ObservabilitySnapshotTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ObservabilitySnapshot, Orchestrator}

  test "serves the latest projection without waiting for the orchestrator mailbox" do
    server = :observability_snapshot_blocked_orchestrator
    snapshot = %{running: [], retrying: [], codex_totals: %{total_tokens: 42}}
    parent = self()

    assert :error = ObservabilitySnapshot.fetch(:unknown_orchestrator)

    pid =
      spawn(fn ->
        Process.register(self(), server)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert_receive :registered
    assert :ok = ObservabilitySnapshot.put(server, snapshot)

    started_at = System.monotonic_time(:millisecond)
    assert Orchestrator.snapshot(server, 1) == snapshot
    assert System.monotonic_time(:millisecond) - started_at < 100
  end

  test "does not expose a cached projection after its orchestrator stops" do
    server = :observability_snapshot_stopped_orchestrator
    snapshot = %{running: [], retrying: [], codex_totals: %{total_tokens: 0}}

    assert :ok = ObservabilitySnapshot.put(server, snapshot)
    assert Orchestrator.snapshot(server, 1) == :unavailable
  end

  test "fails open while the snapshot table is temporarily unavailable" do
    owner = Process.whereis(ObservabilitySnapshot)
    assert is_pid(owner)
    assert {:error, {:already_started, ^owner}} = ObservabilitySnapshot.start_link()
    assert true = :ets.delete(ObservabilitySnapshot)

    assert :ok = ObservabilitySnapshot.put(:missing_table, %{running: []})
    assert :error = ObservabilitySnapshot.fetch(:missing_table)

    Process.exit(owner, :kill)

    assert Enum.any?(1..100, fn _attempt ->
             if :ets.whereis(ObservabilitySnapshot) == :undefined do
               Process.sleep(10)
               false
             else
               true
             end
           end)
  end
end
