defmodule SymphonyElixir.CapacityQueueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Tracker.Issue

  test "capacity waiting consumes neither an Attempt nor retry budget" do
    issue = issue("recovered", "agent:running", ~U[2026-07-20 08:00:00Z], 4)
    timer = Process.send_after(self(), :unused_retry, 60_000)

    state = %State{
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{
        issue.id => %{attempt: 3, timer_ref: timer, due_at_ms: 1, retry_token: make_ref()}
      }
    }

    queued =
      Orchestrator.queue_capacity_wait_for_test(state, issue, 3, %{
        workspace_path: "/tmp/recovered"
      })

    refute Map.has_key?(queued.retry_attempts, issue.id)
    refute MapSet.member?(queued.claimed, issue.id)
    assert queued.capacity_waiting[issue.id].attempt == 3
    assert queued.capacity_waiting[issue.id].reason == "waiting for execution capacity"

    queued_again =
      Orchestrator.queue_capacity_wait_for_test(queued, issue, 3, %{
        workspace_path: "/tmp/recovered"
      })

    assert queued_again.capacity_waiting[issue.id].queued_at ==
             queued.capacity_waiting[issue.id].queued_at
  end

  test "merging and recovered work precede newly ready work" do
    ready = issue("new-ready", "agent:ready", ~U[2026-07-21 10:00:00Z], 1)
    recovered = issue("old-running", "agent:running", ~U[2026-07-20 08:00:00Z], 4)
    merging = issue("merging", "agent:merging", ~U[2026-07-21 11:00:00Z], 4)

    state = %State{
      capacity_waiting: %{
        recovered.id => %{issue: recovered}
      }
    }

    assert ["merging", "old-running", "new-ready"] ==
             [ready, recovered, merging]
             |> Orchestrator.sort_issues_for_dispatch_for_test(state)
             |> Enum.map(& &1.id)
  end

  test "canonical state and creation time reconstruct order after restart" do
    older_ready = issue("older-ready", "agent:ready", ~U[2026-07-20 08:00:00Z], 4)
    newer_ready = issue("newer-ready", "agent:ready", ~U[2026-07-21 08:00:00Z], 1)
    recovered = issue("recovered", "agent:running", ~U[2026-07-21 09:00:00Z], 4)

    assert ["recovered", "newer-ready", "older-ready"] ==
             [newer_ready, older_ready, recovered]
             |> Orchestrator.sort_issues_for_dispatch_for_test(%State{})
             |> Enum.map(& &1.id)
  end

  defp issue(id, state, created_at, priority) do
    %Issue{
      id: id,
      identifier: id,
      title: id,
      state: state,
      created_at: created_at,
      priority: priority,
      labels: ["bos:issue"],
      dispatchable: true
    }
  end
end
