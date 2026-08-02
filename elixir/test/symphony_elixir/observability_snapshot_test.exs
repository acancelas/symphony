defmodule SymphonyElixir.ObservabilitySnapshotTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ObservabilitySnapshot, Orchestrator}

  test "serves the latest projection without waiting for the orchestrator mailbox" do
    server = :observability_snapshot_blocked_orchestrator
    snapshot = %{running: [], retrying: [], codex_totals: %{total_tokens: 42}}
    parent = self()

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
end
