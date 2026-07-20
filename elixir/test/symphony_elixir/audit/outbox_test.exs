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
end
