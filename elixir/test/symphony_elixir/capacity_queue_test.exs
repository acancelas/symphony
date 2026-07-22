defmodule SymphonyElixir.CapacityQueueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunnerIdentity
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

  test "runner identity defaults when the environment variable is absent" do
    previous_runner_id = System.get_env("BOS_RUNNER_ID")
    System.put_env("BOS_RUNNER_ID", " x1 ")
    assert RunnerIdentity.id() == "x1"

    System.delete_env("BOS_RUNNER_ID")
    on_exit(fn -> restore_env("BOS_RUNNER_ID", previous_runner_id) end)

    assert RunnerIdentity.id() == "x1"
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

  test "a terminal capacity waiter releases its repository reservation" do
    waiting =
      issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      })

    terminal = %{waiting | state: "Done", dispatchable: false}

    candidate =
      issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)
      |> Map.put(:native_ref, %{"repositoryId" => "bos-mcp"})

    state = %State{
      max_concurrent_agents: 2,
      claimed: MapSet.new([waiting.id]),
      repository_claims: %{waiting.id => "bos-mcp"}
    }

    queued =
      Orchestrator.queue_capacity_wait_for_test(state, waiting, 2, %{
        reason: "waiting for execution capacity"
      })

    reconciled =
      Orchestrator.reconcile_capacity_waiting_issue_states_for_test([terminal], queued)

    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.repository_claims, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
    assert Orchestrator.should_dispatch_issue_for_test(candidate, reconciled)
  end

  test "a missing capacity waiter releases its repository reservation" do
    waiting =
      issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      })

    candidate =
      issue("bos-mcp#28", "Todo", ~U[2026-07-21 08:00:00Z], 1)
      |> Map.put(:native_ref, %{"repositoryId" => "bos-mcp"})

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{
          max_concurrent_agents: 2,
          claimed: MapSet.new([waiting.id]),
          repository_claims: %{waiting.id => "bos-mcp"}
        },
        waiting,
        2,
        %{reason: "waiting for execution capacity"}
      )

    reconciled =
      Orchestrator.reconcile_capacity_waiting_issue_states_for_test([], queued)

    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
    assert Orchestrator.should_dispatch_issue_for_test(candidate, reconciled)
  end

  test "an active capacity waiter is refreshed without consuming an Attempt" do
    waiting =
      issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      })

    refreshed = %{waiting | title: "refreshed title"}

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{
          max_concurrent_agents: 2,
          claimed: MapSet.new([waiting.id]),
          repository_claims: %{waiting.id => "bos-mcp"}
        },
        waiting,
        2,
        %{reason: "waiting for execution capacity"}
      )

    reconciled =
      Orchestrator.reconcile_capacity_waiting_issue_states_for_test([refreshed], queued)

    assert reconciled.capacity_waiting[waiting.id].issue.title == "refreshed title"
    assert reconciled.capacity_waiting[waiting.id].attempt == 2
    assert MapSet.member?(reconciled.claimed, waiting.id)
  end

  test "a replacement claim is never adopted or heartbeated by the old capacity waiter" do
    waiting =
      issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-old",
        "runnerId" => "x1"
      })

    replacement = %{waiting | native_ref: Map.put(waiting.native_ref, "runId", "run-new")}

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{
          max_concurrent_agents: 2,
          claimed: MapSet.new([waiting.id]),
          repository_claims: %{waiting.id => "bos-mcp"}
        },
        waiting,
        2,
        %{reason: "waiting for execution capacity"}
      )

    reconciled =
      Orchestrator.reconcile_capacity_waiting_issue_states_for_test([replacement], queued)

    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
    refute Map.has_key?(reconciled.repository_claims, waiting.id)
    assert Orchestrator.heartbeat_issue_ids_for_test(reconciled) == []
  end

  test "a transferred runner is never adopted when the AgentRun id is unchanged" do
    waiting =
      issue("bos-mcp#19", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      })

    transferred = %{waiting | native_ref: Map.put(waiting.native_ref, "runnerId", "x2")}

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{
          max_concurrent_agents: 2,
          claimed: MapSet.new([waiting.id]),
          repository_claims: %{waiting.id => "bos-mcp"}
        },
        waiting,
        2,
        %{reason: "waiting for execution capacity"}
      )

    reconciled =
      Orchestrator.reconcile_capacity_waiting_issue_states_for_test([transferred], queued)

    refute MapSet.member?(reconciled.claimed, waiting.id)
    refute Map.has_key?(reconciled.capacity_waiting, waiting.id)
    refute Map.has_key?(reconciled.repository_claims, waiting.id)
    assert Orchestrator.heartbeat_issue_ids_for_test(reconciled) == []
  end

  test "heartbeat covers claimed capacity waiters but not unclaimed candidates" do
    running = issue("game-api#80", "In Progress", ~U[2026-07-20 08:00:00Z], 1)
    claimed_waiter = issue("bos-mcp#19", "In Progress", ~U[2026-07-20 09:00:00Z], 1)
    unclaimed_waiter = issue("tengo-suerte#1", "Todo", ~U[2026-07-20 10:00:00Z], 1)

    state = %State{
      running: %{running.id => %{issue: running}},
      claimed: MapSet.new([running.id, claimed_waiter.id]),
      capacity_waiting: %{
        claimed_waiter.id => %{issue: claimed_waiter},
        unclaimed_waiter.id => %{issue: unclaimed_waiter}
      }
    }

    assert Orchestrator.heartbeat_issue_ids_for_test(state) == [
             "bos-mcp#19",
             "game-api#80"
           ]
  end

  test "restart recovery reserves and heartbeats a capacity waiter owned by this runner" do
    recovered =
      issue("bos-mcp#19", "agent:running", ~U[2026-07-20 09:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      })

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{max_concurrent_agents: 0},
        recovered,
        nil,
        %{reason: "waiting after restart"}
      )

    assert MapSet.member?(queued.claimed, recovered.id)
    assert queued.repository_claims[recovered.id] == "bos-mcp"
    assert Orchestrator.heartbeat_issue_ids_for_test(queued) == [recovered.id]
  end

  test "restart recovery never reserves a capacity waiter owned by another runner" do
    transferred =
      issue("bos-mcp#19", "agent:running", ~U[2026-07-20 09:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x2"
      })

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{max_concurrent_agents: 0},
        transferred,
        nil,
        %{reason: "waiting after restart"}
      )

    refute MapSet.member?(queued.claimed, transferred.id)
    refute Map.has_key?(queued.repository_claims, transferred.id)
    assert Orchestrator.heartbeat_issue_ids_for_test(queued) == []
  end

  test "restart recovery rejects blank canonical claim identities" do
    for {run_id, runner_id} <- [{"", "x1"}, {"run-19", ""}, {"   ", "x1"}, {"run-19", "   "}] do
      malformed =
        issue("bos-mcp#19", "agent:running", ~U[2026-07-20 09:00:00Z], 1)
        |> Map.put(:native_ref, %{
          "repositoryId" => "bos-mcp",
          "issueNumber" => 19,
          "runId" => run_id,
          "runnerId" => runner_id
        })

      queued =
        Orchestrator.queue_capacity_wait_for_test(
          %State{max_concurrent_agents: 0},
          malformed,
          nil,
          %{reason: "waiting after restart"}
        )

      refute MapSet.member?(queued.claimed, malformed.id)
      refute Map.has_key?(queued.repository_claims, malformed.id)
      assert Orchestrator.heartbeat_issue_ids_for_test(queued) == []
    end
  end

  test "restart recovery rejects malformed repository and Issue claim identity" do
    malformed_fields = [
      {"repositoryId", nil},
      {"repositoryId", ""},
      {"repositoryId", "   "},
      {"repositoryId", "other-repository"},
      {"issueNumber", nil},
      {"issueNumber", 0},
      {"issueNumber", -1},
      {"issueNumber", "19"},
      {"issueNumber", 20},
      {"runId", " run-19 "},
      {"runnerId", " x1 "}
    ]

    for {field, value} <- malformed_fields do
      native_ref = %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => "x1"
      }

      malformed =
        issue("bos-mcp#19", "agent:running", ~U[2026-07-20 09:00:00Z], 1)
        |> Map.put(:native_ref, Map.put(native_ref, field, value))

      queued =
        Orchestrator.queue_capacity_wait_for_test(
          %State{max_concurrent_agents: 0},
          malformed,
          nil,
          %{reason: "waiting after restart"}
        )

      refute MapSet.member?(queued.claimed, malformed.id)
      refute Map.has_key?(queued.repository_claims, malformed.id)
      assert Orchestrator.heartbeat_issue_ids_for_test(queued) == []
    end
  end

  test "a blank local runner configuration falls back without adopting a blank claim" do
    previous_runner_id = System.get_env("BOS_RUNNER_ID")
    System.put_env("BOS_RUNNER_ID", "")

    on_exit(fn ->
      if previous_runner_id do
        System.put_env("BOS_RUNNER_ID", previous_runner_id)
      else
        System.delete_env("BOS_RUNNER_ID")
      end
    end)

    malformed =
      issue("bos-mcp#19", "agent:running", ~U[2026-07-20 09:00:00Z], 1)
      |> Map.put(:native_ref, %{
        "repositoryId" => "bos-mcp",
        "issueNumber" => 19,
        "runId" => "run-19",
        "runnerId" => ""
      })

    queued =
      Orchestrator.queue_capacity_wait_for_test(
        %State{max_concurrent_agents: 0},
        malformed,
        nil,
        %{reason: "waiting after restart"}
      )

    refute MapSet.member?(queued.claimed, malformed.id)
    assert Orchestrator.heartbeat_issue_ids_for_test(queued) == []
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
end
