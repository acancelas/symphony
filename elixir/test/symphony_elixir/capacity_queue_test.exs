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
    assert MapSet.member?(queued.claimed, issue.id)
    assert queued.capacity_waiting[issue.id].attempt == 3
    assert queued.capacity_waiting[issue.id].reason == "waiting for execution capacity"

    queued_again =
      Orchestrator.queue_capacity_wait_for_test(queued, issue, 3, %{
        workspace_path: "/tmp/recovered"
      })

    assert queued_again.capacity_waiting[issue.id].queued_at ==
             queued.capacity_waiting[issue.id].queued_at
  end

  test "missing capacity waiter releases its remote and local repository claim" do
    waiting = claimed_issue("opaque-waiter", "In Progress", "run-waiter")
    state = waiting_state(waiting)
    parent = self()

    reconciled =
      Orchestrator.reconcile_capacity_waiting_for_test(
        state,
        [],
        fn _ -> flunk("missing waiter must not heartbeat") end,
        fn issue, reason ->
          send(parent, {:released, issue.id, reason})
          :ok
        end
      )

    assert_received {:released, "opaque-waiter", "capacity-waiting issue is no longer visible"}
    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.repository_claims, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)

    candidate =
      issue("repo#52", "Todo", ~U[2026-07-21 08:00:00Z], 1)
      |> Map.put(:native_ref, %{"repositoryId" => "repo"})

    assert Orchestrator.should_dispatch_issue_for_test(candidate, reconciled)
  end

  test "terminal and unroutable capacity waiters release their claims" do
    waiting = claimed_issue("repo#51", "In Progress", "run-waiter")

    for refreshed <- [
          %{waiting | state: "Done"},
          %{waiting | dispatchable: false}
        ] do
      reconciled =
        Orchestrator.reconcile_capacity_waiting_for_test(
          waiting_state(waiting),
          [refreshed],
          fn _ -> flunk("stale waiter must not heartbeat") end,
          fn _, _ -> :ok end
        )

      refute MapSet.member?(reconciled.claimed, waiting.id)
      refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
    end
  end

  test "valid capacity waiter is refreshed and heartbeated without retry or Attempt consumption" do
    waiting = claimed_issue("repo#51", "In Progress", "run-waiter")
    refreshed = %{waiting | title: "Latest tracker snapshot"}
    parent = self()

    reconciled =
      Orchestrator.reconcile_capacity_waiting_for_test(
        waiting_state(waiting),
        [refreshed],
        fn issue ->
          send(parent, {:heartbeat, issue.id})
          :ok
        end
      )

    assert_received {:heartbeat, "repo#51"}
    assert reconciled.capacity_waiting[waiting.id].issue.title == "Latest tracker snapshot"
    assert reconciled.capacity_waiting[waiting.id].attempt == 3
    assert reconciled.retry_attempts == %{}
    assert MapSet.member?(reconciled.claimed, waiting.id)
  end

  test "capacity waiter owned by another run releases only its local reservation" do
    waiting = claimed_issue("repo#51", "In Progress", "run-old")
    refreshed = claimed_issue("repo#51", "In Progress", "run-new")

    reconciled =
      Orchestrator.reconcile_capacity_waiting_for_test(
        waiting_state(waiting),
        [refreshed],
        fn _ -> flunk("foreign claim must not heartbeat") end,
        fn _, _ -> flunk("foreign claim must not be released remotely") end
      )

    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
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

  test "an active run reserves repository capacity without consuming global capacity" do
    running = issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
    same_repository = issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)
    other_repository = issue("game-api#84", "Todo", ~U[2026-07-21 08:00:00Z], 1)

    state = %State{
      max_concurrent_agents: 2,
      running: %{
        running.id => %{issue: running}
      }
    }

    refute Orchestrator.should_dispatch_issue_for_test(same_repository, state)
    assert Orchestrator.should_dispatch_issue_for_test(other_repository, state)
  end

  test "repository capacity is released when the active run leaves running state" do
    candidate = issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)

    assert Orchestrator.should_dispatch_issue_for_test(candidate, %State{max_concurrent_agents: 2})
  end

  test "a retrying or blocked claim keeps repository capacity reserved" do
    candidate = issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)

    state = %State{
      max_concurrent_agents: 2,
      claimed: MapSet.new(["bos-mcp#19"])
    }

    refute Orchestrator.should_dispatch_issue_for_test(candidate, state)
  end

  test "an opaque claimed issue keeps its explicit repository reservation while queued" do
    claimed =
      issue("opaque-run-id", "Todo", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{"repositoryId" => "bos-mcp"})

    candidate = issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)

    state = %State{
      max_concurrent_agents: 2,
      claimed: MapSet.new([claimed.id]),
      repository_claims: %{claimed.id => "bos-mcp"}
    }

    queued =
      Orchestrator.queue_capacity_wait_for_test(state, claimed, 2, %{
        reason: "waiting for execution capacity"
      })

    assert MapSet.member?(queued.claimed, claimed.id)
    assert queued.repository_claims[claimed.id] == "bos-mcp"
    assert Orchestrator.should_dispatch_issue_for_test(claimed, queued)
    refute Orchestrator.should_dispatch_issue_for_test(candidate, queued)
  end

  test "game_api fails closed when canonical repository identity is missing" do
    previous_token = System.get_env("BOS_API_INTERNAL_TOKEN")
    System.put_env("BOS_API_INTERNAL_TOKEN", "test-token")
    on_exit(fn -> restore_env("BOS_API_INTERNAL_TOKEN", previous_token) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "game_api",
      tracker_provider: %{
        "repositories" => [
          %{"repository_id" => "bos-mcp", "owner" => "acancelas", "repo" => "bos-mcp"}
        ]
      }
    )

    assert Config.settings!().tracker.kind == "game_api"

    missing_repository =
      issue("opaque-run-id", "agent:ready", ~U[2026-07-21 08:00:00Z], 1)

    refute Orchestrator.should_dispatch_issue_for_test(
             missing_repository,
             %State{max_concurrent_agents: 2}
           )

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{max_concurrent_agents: 2},
        missing_repository,
        nil,
        %{}
      )

    assert queued.capacity_waiting[missing_repository.id].reason ==
             "missing canonical repository identity"
  end

  test "repository identity survives older recovered projections" do
    explicit =
      issue("opaque", "agent:running", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{"repositoryId" => "tengo-suerte"})

    recovered = issue("tengo-suerte#1", "agent:running", ~U[2026-07-20 08:00:00Z], 1)

    assert Issue.repository_id(explicit) == "tengo-suerte"
    assert Issue.repository_id(recovered) == "tengo-suerte"
    assert Issue.repository_id(%Issue{id: nil}) == nil
    assert Issue.repository_id(%Issue{id: ""}) == nil
    assert Issue.repository_id(%Issue{id: "#1"}) == nil
    assert Issue.repository_id(%Issue{id: "bos-mcp#"}) == nil

    assert Issue.repository_id(%Issue{
             id: "fallback#1",
             native_ref: %{"repositoryId" => "  "}
           }) == "fallback"

    assert Issue.repository_id(%Issue{
             id: "ignored#1",
             native_ref: %{repository_id: " explicit "}
           }) == "explicit"
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

  defp claimed_issue(id, state, run_id) do
    issue(id, state, ~U[2026-07-20 08:00:00Z], 1)
    |> Map.put(:native_ref, %{"repositoryId" => "repo", "issueNumber" => 51, "runId" => run_id})
  end

  defp waiting_state(issue) do
    %State{
      max_concurrent_agents: 2,
      claimed: MapSet.new([issue.id]),
      repository_claims: %{issue.id => "repo"},
      capacity_waiting: %{
        issue.id => %{
          issue: issue,
          identifier: issue.identifier,
          issue_url: issue.url,
          attempt: 3,
          worker_host: nil,
          workspace_path: nil,
          queued_at: ~U[2026-07-20 08:00:00Z],
          reason: "waiting for execution capacity"
        }
      }
    }
  end
end
