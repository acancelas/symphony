defmodule SymphonyElixir.Audit.OutboxTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Audit.Outbox
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeClient do
    def fetch_run(_repository_id, _run_id), do: {:error, :not_found}

    def append_audit_batch(request) do
      if pid = Application.get_env(:symphony_elixir, :outbox_test_pid),
        do: send(pid, {:audit_batch_attempted, request})

      {:error, :offline}
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :game_api_client_module)
    Application.put_env(:symphony_elixir, :game_api_client_module, FakeClient)
    Application.put_env(:symphony_elixir, :outbox_test_pid, self())

    on_exit(fn ->
      if previous_client do
        Application.put_env(:symphony_elixir, :game_api_client_module, previous_client)
      else
        Application.delete_env(:symphony_elixir, :game_api_client_module)
      end

      Application.delete_env(:symphony_elixir, :outbox_test_pid)
    end)
  end

  test "startup recovery attempts one run at a time instead of recursively draining every batch" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-paced-test-#{System.unique_integer([:positive])}")
    write_pending_run(root, "run_a", 1)
    write_pending_run(root, "run_b", 2)

    {:ok, pid} = Outbox.start_link(root: root, name: nil)

    assert_receive {:audit_batch_attempted, first_request}, 1_000
    assert first_request["batchId"] =~ ~r/batch_run_[ab]_1_1/
    refute_receive {:audit_batch_attempted, _second_request}, 500

    GenServer.stop(pid)
    File.rm_rf!(root)
  end

  test "aggregates high-frequency deltas while preserving a durable bounded summary" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-telemetry-test-#{System.unique_integer([:positive])}")
    {:ok, pid} = Outbox.start_link(root: root, name: nil)

    issue = %Issue{
      id: "symphony:14",
      identifier: "symphony-14",
      branch_name: "bos/issue-14",
      native_ref: %{
        "repositoryId" => "symphony",
        "repositoryOwner" => "acancelas",
        "repositoryName" => "symphony",
        "issueNumber" => 14,
        "runId" => "run_14",
        "attemptId" => "attempt_14_1"
      }
    }

    Enum.each(1..100, fn sequence ->
      GenServer.cast(pid, {
        :record,
        issue,
        %{
          event: :notification,
          timestamp: "2026-07-21T03:00:00.000Z",
          payload: %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => "fragment #{sequence}"}
          }
        }
      })
    end)

    :sys.get_state(pid)
    event_files = Path.wildcard(Path.join([root, "run_14", "events", "*.json"]))
    assert length(event_files) == 1
    event = event_files |> hd() |> File.read!() |> Jason.decode!() |> Map.fetch!("event")
    assert event["eventType"] == "agent.telemetry_aggregated"
    assert event["payload"]["params"]["eventCount"] == 100
    assert event["payload"]["params"]["methods"] == %{"item/agentMessage/delta" => 100}
    refute File.read!(hd(event_files)) =~ "fragment 100"

    GenServer.stop(pid)
    File.rm_rf!(root)
  end

  test "classifies only streaming delta methods as aggregatable telemetry" do
    assert Outbox.telemetry_delta?("item/agentMessage/delta")
    assert Outbox.telemetry_delta?("item/commandExecution/outputDelta/delta")
    refute Outbox.telemetry_delta?("item/completed")
    refute Outbox.telemetry_delta?("turn/failed")
  end

  test "compacts recovered delta runs without reordering durable boundaries" do
    events = [
      pending_event(41, "item/agentMessage/delta", "a", "sha256:confirmed"),
      pending_event(42, "item/agentMessage/delta", "b", "sha256:stale-41"),
      pending_event(43, "item/completed", "final", "sha256:stale-42"),
      pending_event(44, "item/reasoning/delta", "c", "sha256:stale-43")
    ]

    [first, boundary, last] = Outbox.compact_pending_telemetry(events)

    assert Enum.map([first, boundary, last], & &1["sequence"]) == [41, 42, 43]
    assert first["previousEventHash"] == "sha256:confirmed"
    assert first["eventType"] == "agent.telemetry_aggregated"
    assert first["payload"]["params"]["eventCount"] == 2
    assert boundary["payload"]["method"] == "item/completed"
    assert last["payload"]["params"]["eventCount"] == 1
    assert boundary["previousEventHash"] == first["eventHash"]
    assert last["previousEventHash"] == boundary["eventHash"]
  end

  defp pending_event(sequence, method, delta, previous_hash) do
    %{
      "schemaVersion" => "1.0",
      "eventId" => "event_#{sequence}",
      "operationId" => "op_event_#{sequence}",
      "occurredAt" => "2026-07-21T03:00:#{sequence}.000Z",
      "runId" => "run_14",
      "sequence" => sequence,
      "previousEventHash" => previous_hash,
      "eventHash" => "sha256:stale-#{sequence}",
      "eventType" => "agent.progress_recorded",
      "payload" => %{"method" => method, "params" => %{"delta" => delta}}
    }
  end

  defp write_pending_run(root, run_id, issue_number) do
    events_path = Path.join([root, run_id, "events"])
    File.mkdir_p!(events_path)

    issue = %{
      "repositoryId" => "symphony",
      "repositoryOwner" => "acancelas",
      "repositoryName" => "symphony",
      "issueNumber" => issue_number,
      "runId" => run_id,
      "branchName" => "bos/issue-#{issue_number}"
    }

    event = pending_event(1, "item/completed", "final", nil) |> Map.put("runId", run_id)
    File.write!(Path.join(events_path, "00000001.json"), Jason.encode!(%{"issue" => issue, "event" => event}))
  end

  test "recovers ordered unconfirmed events and their last hash after restart" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-test-#{System.unique_integer([:positive])}")
    path = Path.join([root, "run_001", "events"])
    File.mkdir_p!(path)

    issue = %{
      "repositoryId" => "bos-front",
      "repositoryOwner" => "acancelas",
      "repositoryName" => "bos-front",
      "issueNumber" => 42,
      "runId" => "run_001",
      "branchName" => "bos/issue-42"
    }

    File.write!(
      Path.join(path, "00000002.json"),
      Jason.encode!(%{"issue" => issue, "event" => %{"eventId" => "event_2", "runId" => "run_001", "sequence" => 2, "eventHash" => "sha256:second"}})
    )

    File.write!(
      Path.join(path, "00000001.json"),
      Jason.encode!(%{"issue" => issue, "event" => %{"eventId" => "event_1", "runId" => "run_001", "sequence" => 1, "eventHash" => "sha256:first"}})
    )

    recovered = Outbox.recover_pending(root)["run_001"]

    assert Enum.map(recovered.pending, & &1["sequence"]) == [1, 2]
    assert recovered.sequence == 2
    assert recovered.previous_hash == "sha256:second"
    assert recovered.issue.branch_name == "bos/issue-42"

    File.rm_rf!(root)
  end

  test "does not replay event files already covered by a durable receipt" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-receipt-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_001", "events"])
    receipts_path = Path.join([root, "run_001", "receipts"])
    File.mkdir_p!(events_path)
    File.mkdir_p!(receipts_path)
    issue = %{"repositoryId" => "bos-front", "issueNumber" => 42, "runId" => "run_001"}
    event = %{"eventId" => "event_confirmed", "runId" => "run_001", "sequence" => 1, "eventHash" => "sha256:confirmed"}
    File.write!(Path.join(events_path, "00000001.json"), Jason.encode!(%{"issue" => issue, "event" => event}))
    File.write!(Path.join(receipts_path, "batch.json"), Jason.encode!(%{"eventIds" => ["event_confirmed"]}))

    assert Outbox.recover_pending(root) == %{}

    File.rm_rf!(root)
  end

  test "normalizes command completion into durable portable metadata" do
    payload = %{
      "method" => "item/completed",
      "params" => %{
        "item" => %{
          "id" => "cmd_001",
          "type" => "commandExecution",
          "command" => "mix test",
          "cwd" => File.cwd!(),
          "status" => "completed",
          "exitCode" => 0,
          "durationMs" => 245,
          "aggregatedOutput" => "260 tests, 0 failures"
        }
      }
    }

    normalized = Outbox.normalize_codex_payload("item/completed", payload, "2026-07-20T10:00:00.000Z")

    assert normalized["commandId"] == "cmd_001"
    assert normalized["command"] == "mix test"
    assert normalized["workingDirectory"] == "$WORKSPACE"
    assert normalized["exitCode"] == 0
    assert normalized["durationMs"] == 245
    assert normalized["outputSummary"] == "260 tests, 0 failures"
    assert normalized["redacted"] == true
  end

  test "attributes Codex lifecycle actions to the agent while retaining runner observation separately" do
    assert Outbox.actor_for_codex_method("item/completed") == %{
             "type" => "agent",
             "subjectId" => "implementation-agent"
           }

    assert Outbox.actor_for_codex_method("runner/recovered") == %{
             "type" => "runner",
             "subjectId" => "x1"
           }

    assert Outbox.actor_for_update(%{delivery_actor: "security-reviewer"}, "item/completed") == %{
             "type" => "agent",
             "subjectId" => "security-reviewer"
           }
  end

  test "rebases only unconfirmed events onto the confirmed remote chain" do
    events = [
      %{
        "eventId" => "event_1",
        "operationId" => "op_event_1",
        "runId" => "run_001",
        "sequence" => 8,
        "previousEventHash" => "sha256:stale",
        "eventHash" => "sha256:stale_event"
      },
      %{
        "eventId" => "event_2",
        "operationId" => "op_event_2",
        "runId" => "run_001",
        "sequence" => 9,
        "previousEventHash" => "sha256:stale_event",
        "eventHash" => "sha256:stale_event_2"
      }
    ]

    [first, second] =
      Outbox.rebase_pending_events(events, 21, "sha256:confirmed_remote")

    assert first["sequence"] == 22
    assert first["previousEventHash"] == "sha256:confirmed_remote"
    assert first["eventId"] == "event_1"
    assert first["operationId"] == "op_event_1"
    assert first["eventHash"] != "sha256:stale_event"
    assert second["sequence"] == 23
    assert second["previousEventHash"] == first["eventHash"]
    assert second["eventId"] == "event_2"
  end

  test "recovers a crash during an atomic pending-event directory swap" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-rebase-test-#{System.unique_integer([:positive])}")
    run_dir = Path.join(root, "run_001")
    rebase_path = Path.join(run_dir, ".events.rebase.2")
    backup_path = Path.join(run_dir, ".events.backup.2")
    File.mkdir_p!(rebase_path)
    File.mkdir_p!(backup_path)

    issue = %{"repositoryId" => "bos-front", "issueNumber" => 42, "runId" => "run_001"}
    rebased = %{"eventId" => "event_pending", "runId" => "run_001", "sequence" => 42, "eventHash" => "sha256:rebased"}
    stale = %{"eventId" => "event_pending", "runId" => "run_001", "sequence" => 8, "eventHash" => "sha256:stale"}
    File.write!(Path.join(rebase_path, "00000042.json"), Jason.encode!(%{"issue" => issue, "event" => rebased}))
    File.write!(Path.join(backup_path, "00000008.json"), Jason.encode!(%{"issue" => issue, "event" => stale}))

    recovered = Outbox.recover_pending(root)["run_001"]

    assert Enum.map(recovered.pending, & &1["sequence"]) == [42]
    assert recovered.previous_hash == "sha256:rebased"
    refute File.exists?(backup_path)

    File.rm_rf!(root)
  end
end
