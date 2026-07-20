defmodule SymphonyElixir.Audit.OutboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Audit.Outbox

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

  test "persists semantic lifecycle but drops high-frequency telemetry deltas" do
    command_item = %{"method" => "item/started", "params" => %{"item" => %{"type" => "commandExecution"}}}
    reasoning_item = %{"method" => "item/completed", "params" => %{"item" => %{"type" => "reasoning"}}}

    assert Outbox.auditable_update?(%{event: :item_started, payload: command_item})
    assert Outbox.auditable_update?(%{event: :turn_completed, payload: %{"method" => "turn/completed"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: reasoning_item})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "item/agentMessage/delta"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "item/commandExecution/outputDelta"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "thread/tokenUsage/updated"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "account/rateLimits/updated"}})
  end

  test "command metadata is redacted and excludes the raw App Server payload" do
    payload = %{
      "method" => "item/completed",
      "params" => %{
        "item" => %{
          "id" => "cmd_secret",
          "type" => "commandExecution",
          "command" => "BOS_API_INTERNAL_TOKEN=top-secret curl --api-key another-secret",
          "status" => "completed",
          "exitCode" => 0,
          "aggregatedOutput" => ~s({"token":"output-secret","result":"ok"})
        }
      }
    }

    normalized = Outbox.normalize_codex_payload("item/completed", payload, "2026-07-20T10:00:00.000Z")
    serialized = inspect(normalized)

    refute Map.has_key?(normalized, "source")
    refute serialized =~ "top-secret"
    refute serialized =~ "another-secret"
    refute serialized =~ "output-secret"
    assert normalized["command"] =~ "[REDACTED]"
    assert normalized["outputSummary"] =~ "[REDACTED]"
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
