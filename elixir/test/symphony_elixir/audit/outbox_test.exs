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
end
