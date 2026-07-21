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
    batches_path = Path.join([root, "run_001", "batches"])
    File.mkdir_p!(batches_path)
    File.write!(Path.join(batches_path, "batch.json"), Jason.encode!(%{"events" => [event]}))

    assert Outbox.recover_pending(root) == %{}
    refute File.dir?(receipts_path)
    refute File.exists?(Path.join(events_path, "00000001.json"))
    refute File.exists?(Path.join(batches_path, "batch.json"))
    assert File.exists?(Path.join([root, "run_001", "confirmed.json"]))

    File.rm_rf!(root)
  end

  test "compacts canonical receipts into a bounded per-run sequence watermark" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-watermark-test-#{System.unique_integer([:positive])}")
    run_dir = Path.join(root, "run_with_underscores")
    events_path = Path.join(run_dir, "events")
    receipts_path = Path.join(run_dir, "receipts")
    File.mkdir_p!(events_path)
    File.mkdir_p!(receipts_path)
    issue = %{"repositoryId" => "symphony", "issueNumber" => 18, "runId" => "run_with_underscores"}

    Enum.each(1..3, fn sequence ->
      event = %{
        "eventId" => "event_#{sequence}",
        "runId" => "run_with_underscores",
        "sequence" => sequence,
        "eventHash" => "sha256:#{sequence}"
      }

      File.write!(
        Path.join(events_path, String.pad_leading(to_string(sequence), 8, "0") <> ".json"),
        Jason.encode!(%{"issue" => issue, "event" => event})
      )
    end)

    File.write!(
      Path.join(receipts_path, "batch_run_with_underscores_1_2.json"),
      Jason.encode!(%{
        "batchId" => "batch_run_with_underscores_1_2",
        "eventIds" => ["event_1", "event_2"],
        "auditCommitSha" => "abc123"
      })
    )

    assert Outbox.compact_confirmed_receipts(root) == 1
    assert Outbox.compact_confirmed_receipts(root) == 0
    assert Outbox.compact_confirmed_outbox_files(root) == 2
    assert Outbox.compact_confirmed_outbox_files(root) == 0
    refute File.dir?(receipts_path)

    marker = run_dir |> Path.join("confirmed.json") |> File.read!() |> Jason.decode!()
    assert marker["confirmedThroughSequence"] == 2
    assert marker["lastReceipt"]["auditCommitSha"] == "abc123"

    recovered = Outbox.recover_pending(root)["run_with_underscores"]
    assert Enum.map(recovered.pending, & &1["sequence"]) == [3]

    File.rm_rf!(root)
  end

  test "preserves every receipt when one file cannot be validated" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-invalid-receipt-test-#{System.unique_integer([:positive])}")
    receipts_path = Path.join([root, "run_001", "receipts"])
    File.mkdir_p!(receipts_path)
    valid_path = Path.join(receipts_path, "batch_run_001_1_1.json")
    invalid_path = Path.join(receipts_path, "batch_run_001_2_2.json")

    File.write!(valid_path, Jason.encode!(%{"batchId" => "batch_run_001_1_1", "eventIds" => ["event_1"]}))
    File.write!(invalid_path, "{not-json")

    assert Outbox.compact_confirmed_receipts(root) == 0
    assert File.exists?(valid_path)
    assert File.exists?(invalid_path)
    refute File.exists?(Path.join([root, "run_001", "confirmed.json"]))

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
    assert Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "turn/diff/updated", "params" => %{"diff" => "diff --git a/a b/a"}}})
    refute Outbox.auditable_update?(%{event: :notification, payload: reasoning_item})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "item/agentMessage/delta"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "item/commandExecution/outputDelta"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "thread/tokenUsage/updated"}})
    refute Outbox.auditable_update?(%{event: :notification, payload: %{"method" => "account/rateLimits/updated"}})
  end

  test "batches reconstructible checkpoints while immediately flushing terminal boundaries" do
    refute Outbox.immediate_flush_for_test?(%{
             event: :notification,
             payload: %{"method" => "turn/diff/updated"}
           })

    refute Outbox.immediate_flush_for_test?(%{
             event: :item_completed,
             payload: %{"method" => "item/completed"}
           })

    assert Outbox.immediate_flush_for_test?(%{event: :turn_completed, payload: %{}})
    assert Outbox.immediate_flush_for_test?(%{event: :turn_failed, payload: %{}})
    assert Outbox.immediate_flush_for_test?(%{event: :turn_cancelled, payload: %{}})
  end

  test "retains a complete redacted workspace checkpoint instead of a summary-only diff" do
    secret = "BOS_API_INTERNAL_TOKEN=do-not-persist"
    diff = "diff --git a/lib/example.ex b/lib/example.ex\n" <> String.duplicate("+safe change\n", 2_000) <> "+#{secret}\n"

    normalized =
      Outbox.normalize_codex_payload(
        "turn/diff/updated",
        %{"method" => "turn/diff/updated", "params" => %{"diff" => diff}},
        "2026-07-21T09:00:00.000Z"
      )

    checkpoint = get_in(normalized, ["params", "diff"])

    assert checkpoint["format"] == "unified_diff"
    assert checkpoint["encoding"] == "utf-8"
    assert checkpoint["retention"] == "permanent"
    assert checkpoint["truncated"] == false
    assert byte_size(checkpoint["content"]) > 8_000
    assert checkpoint["content"] =~ "+safe change"
    assert checkpoint["content"] =~ "[REDACTED]"
    refute checkpoint["content"] =~ "do-not-persist"
    assert checkpoint["contentHash"] =~ "sha256:"
  end

  test "audit retry backoff grows per run and remains bounded" do
    assert Outbox.backoff_delay_bounds_for_test(1) == {2_000, 2_499}
    assert Outbox.backoff_delay_bounds_for_test(2) == {4_000, 4_999}
    assert Outbox.backoff_delay_bounds_for_test(8) == {256_000, 300_000}
    assert Outbox.backoff_delay_bounds_for_test(30) == {300_000, 300_000}
  end

  test "provider rate limits open one global circuit with a longer bounded delay" do
    assert Outbox.provider_rate_limited_for_test?({:game_api_http_error, 429})
    assert Outbox.provider_rate_limited_for_test?({:game_api_http_error, 403, "provider_rate_limited"})
    refute Outbox.provider_rate_limited_for_test?({:game_api_http_error, 422})

    assert Outbox.provider_backoff_delay_bounds_for_test(1) == {60_000, 74_999}
    assert Outbox.provider_backoff_delay_bounds_for_test(2) == {120_000, 149_999}
    assert Outbox.provider_backoff_delay_bounds_for_test(5) == {900_000, 900_000}
    assert Outbox.provider_backoff_delay_bounds_for_test(30) == {900_000, 900_000}
  end

  test "compacts only confirmed legacy telemetry while preserving the unconfirmed chain" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-compaction-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_legacy", "events"])
    File.mkdir_p!(events_path)

    issue = %{"repositoryId" => "bos-front", "issueNumber" => 42, "runId" => "run_legacy"}

    events = [
      %{
        "eventId" => "event_turn",
        "runId" => "run_legacy",
        "sequence" => 10,
        "eventHash" => "sha256:turn",
        "eventType" => "agent.progress_recorded",
        "payload" => %{"method" => "turn/started"}
      },
      %{
        "eventId" => "event_delta",
        "runId" => "run_legacy",
        "sequence" => 11,
        "eventHash" => "sha256:delta",
        "eventType" => "agent.progress_recorded",
        "occurredAt" => "2026-07-20T10:00:00.000Z",
        "payload" => %{"method" => "item/agentMessage/delta"}
      },
      %{
        "eventId" => "event_command",
        "runId" => "run_legacy",
        "sequence" => 12,
        "eventHash" => "sha256:command",
        "eventType" => "command.completed",
        "payload" => %{"command" => "mix test", "exitCode" => 0}
      }
    ]

    Enum.each(events, fn event ->
      filename = String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"
      File.write!(Path.join(events_path, filename), Jason.encode!(%{"issue" => issue, "event" => event}))
    end)

    File.write!(
      Path.join([root, "run_legacy", "confirmed.json"]),
      Jason.encode!(%{"confirmedThroughSequence" => 11, "exceptionEventIds" => []})
    )

    assert Outbox.compact_legacy_telemetry(root) == %{kept: 2, quarantined: 1}
    assert File.exists?(Path.join([root, "run_legacy", "legacy-telemetry", "00000011.json"]))
    refute File.exists?(Path.join(events_path, "00000011.json"))

    assert Outbox.compact_legacy_quarantine(root) == 1
    assert Outbox.compact_legacy_quarantine(root) == 0
    refute File.dir?(Path.join([root, "run_legacy", "legacy-telemetry"]))

    summary =
      root
      |> Path.join("run_legacy/legacy-telemetry-summary.json")
      |> File.read!()
      |> Jason.decode!()

    assert summary["totalEvents"] == 1
    assert summary["eventTypes"] == %{"agent.progress_recorded" => 1}
    assert summary["firstOccurredAt"] == "2026-07-20T10:00:00.000Z"
    assert summary["retention"] == "aggregated"

    recovered = Outbox.recover_pending(root)["run_legacy"]
    assert Enum.map(recovered.pending, & &1["eventType"]) == ["command.completed"]

    File.rm_rf!(root)
  end

  test "preserves unconfirmed legacy telemetry instead of creating sequence gaps" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-unconfirmed-telemetry-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_pending", "events"])
    File.mkdir_p!(events_path)
    issue = %{"repositoryId" => "bos-front", "issueNumber" => 42, "runId" => "run_pending"}

    event = %{
      "eventId" => "event_delta",
      "runId" => "run_pending",
      "sequence" => 1,
      "previousEventHash" => nil,
      "eventHash" => "sha256:delta",
      "eventType" => "agent.progress_recorded",
      "payload" => %{"method" => "item/agentMessage/delta"}
    }

    File.write!(Path.join(events_path, "00000001.json"), Jason.encode!(%{"issue" => issue, "event" => event}))

    assert Outbox.compact_legacy_telemetry(root) == %{kept: 1, quarantined: 0}
    assert File.exists?(Path.join(events_path, "00000001.json"))
    refute File.dir?(Path.join([root, "run_pending", "legacy-telemetry"]))

    File.rm_rf!(root)
  end

  test "restores previously quarantined unconfirmed telemetry to the pending chain" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-restore-quarantine-test-#{System.unique_integer([:positive])}")
    quarantine_path = Path.join([root, "run_pending", "legacy-telemetry"])
    File.mkdir_p!(quarantine_path)
    issue = %{"repositoryId" => "bos-front", "issueNumber" => 42, "runId" => "run_pending"}
    event = %{"eventId" => "event_1", "runId" => "run_pending", "sequence" => 1, "eventHash" => "sha256:one"}

    File.write!(
      Path.join(quarantine_path, "00000001.json"),
      Jason.encode!(%{"issue" => issue, "event" => event})
    )

    assert Outbox.compact_legacy_quarantine(root) == 0
    assert File.exists?(Path.join([root, "run_pending", "events", "00000001.json"]))
    refute File.dir?(quarantine_path)

    File.rm_rf!(root)
  end

  test "rebases a damaged unconfirmed legacy chain and carries its aggregate summary" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-repair-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_repair", "events"])
    File.mkdir_p!(events_path)

    issue = %{
      "repositoryId" => "bos-front",
      "repositoryOwner" => "acancelas",
      "repositoryName" => "bos-front",
      "issueNumber" => 42,
      "runId" => "run_repair",
      "branchName" => "bos/issue-42"
    }

    events = [
      %{"eventId" => "event_10", "runId" => "run_repair", "sequence" => 10, "previousEventHash" => "sha256:old", "eventHash" => "sha256:ten", "payload" => %{}},
      %{"eventId" => "event_12", "runId" => "run_repair", "sequence" => 12, "previousEventHash" => "sha256:missing", "eventHash" => "sha256:twelve", "payload" => %{}}
    ]

    Enum.each(events, fn event ->
      filename = String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"
      File.write!(Path.join(events_path, filename), Jason.encode!(%{"issue" => issue, "event" => event}))
    end)

    File.write!(
      Path.join([root, "run_repair", "legacy-telemetry-summary.json"]),
      Jason.encode!(%{"schemaVersion" => "1.0", "totalEvents" => 7, "retention" => "aggregated"})
    )

    runs = Outbox.recover_pending(root)

    repaired =
      Outbox.repair_recovered_chains(runs, root, fn _issue ->
        %{remote_confirmed?: true, sequence: 5, previous_hash: "sha256:remote", current_attempt_id: "attempt_1"}
      end)["run_repair"]

    assert Enum.map(repaired.pending, & &1["sequence"]) == [6, 7]
    assert hd(repaired.pending)["previousEventHash"] == "sha256:remote"
    assert get_in(hd(repaired.pending), ["payload", "legacyTelemetryCompaction", "totalEvents"]) == 7
    assert Enum.at(repaired.pending, 1)["previousEventHash"] == hd(repaired.pending)["eventHash"]
    assert File.exists?(Path.join(events_path, "00000006.json"))
    assert File.exists?(Path.join(events_path, "00000007.json"))
    refute File.exists?(Path.join(events_path, "00000010.json"))

    File.rm_rf!(root)
  end

  test "rebases a contiguous recovered chain when an event payload no longer matches its hash" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-hash-repair-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_hash_repair", "events"])
    File.mkdir_p!(events_path)

    issue = %{
      "repositoryId" => "bos-front",
      "repositoryOwner" => "acancelas",
      "repositoryName" => "bos-front",
      "issueNumber" => 2,
      "runId" => "run_hash_repair",
      "branchName" => "bos/issue-2"
    }

    events = [
      %{"eventId" => "event_10", "runId" => "run_hash_repair", "sequence" => 10, "previousEventHash" => "sha256:remote", "eventHash" => "sha256:invalid-one", "payload" => %{}},
      %{"eventId" => "event_11", "runId" => "run_hash_repair", "sequence" => 11, "previousEventHash" => "sha256:invalid-one", "eventHash" => "sha256:invalid-two", "payload" => %{}}
    ]

    Enum.each(events, fn event ->
      filename = String.pad_leading(to_string(event["sequence"]), 8, "0") <> ".json"
      File.write!(Path.join(events_path, filename), Jason.encode!(%{"issue" => issue, "event" => event}))
    end)

    repaired =
      root
      |> Outbox.recover_pending()
      |> Outbox.repair_recovered_chains(root, fn _issue ->
        %{remote_confirmed?: true, sequence: 5, previous_hash: "sha256:confirmed", current_attempt_id: "attempt_1"}
      end)
      |> Map.fetch!("run_hash_repair")

    assert Enum.map(repaired.pending, & &1["sequence"]) == [6, 7]
    assert hd(repaired.pending)["previousEventHash"] == "sha256:confirmed"
    refute hd(repaired.pending)["eventHash"] == "sha256:invalid-one"
    assert Enum.at(repaired.pending, 1)["previousEventHash"] == hd(repaired.pending)["eventHash"]

    File.rm_rf!(root)
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

  test "bounds long command summaries without discarding command metadata" do
    command = "mix run " <> String.duplicate("á", 3_000)
    payload = %{"command" => command, "exitCode" => 0}

    summary = Outbox.event_summary_for_test("item/completed", payload)

    assert String.length(summary) == 2_000
    assert String.ends_with?(summary, "… [truncated]")
    assert payload["command"] == command
  end

  test "atomically normalizes and rehashes oversized summaries recovered from the local outbox" do
    root = Path.join(System.tmp_dir!(), "bos-outbox-summary-repair-test-#{System.unique_integer([:positive])}")
    events_path = Path.join([root, "run_summary_repair", "events"])
    File.mkdir_p!(events_path)

    issue = %{
      "repositoryId" => "bos-front",
      "repositoryOwner" => "acancelas",
      "repositoryName" => "bos-front",
      "issueNumber" => 2,
      "runId" => "run_summary_repair",
      "branchName" => "bos/issue-2"
    }

    oversized_summary = "Codex command completed: " <> String.duplicate("á", 3_000)

    unhashed = %{
      "eventId" => "event_legacy_summary",
      "runId" => "run_summary_repair",
      "sequence" => 10,
      "previousEventHash" => "sha256:remote",
      "summary" => oversized_summary,
      "payload" => %{"command" => String.duplicate("á", 3_000)}
    }

    event = Map.put(unhashed, "eventHash", Outbox.hash_event_for_test(unhashed))

    File.write!(
      Path.join(events_path, "00000010.json"),
      Jason.encode!(%{"issue" => issue, "event" => event})
    )

    repaired =
      root
      |> Outbox.recover_pending()
      |> Outbox.repair_recovered_chains(root, fn _issue ->
        %{remote_confirmed?: true, sequence: 5, previous_hash: "sha256:confirmed", current_attempt_id: "attempt_1"}
      end)
      |> Map.fetch!("run_summary_repair")

    [normalized] = repaired.pending
    assert normalized["sequence"] == 6
    assert normalized["previousEventHash"] == "sha256:confirmed"
    assert String.length(normalized["summary"]) == 2_000
    assert String.ends_with?(normalized["summary"], "… [truncated]")
    assert String.length(get_in(normalized, ["payload", "command"])) == 3_000
    assert normalized["eventHash"] == Outbox.hash_event_for_test(Map.delete(normalized, "eventHash"))
    assert File.exists?(Path.join(events_path, "00000006.json"))
    refute File.exists?(Path.join(events_path, "00000010.json"))

    File.rm_rf!(root)
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
