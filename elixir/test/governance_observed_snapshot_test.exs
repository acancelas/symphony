defmodule SymphonyElixir.GovernanceObservedSnapshotTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceObservedSnapshot, as: Snapshot
  @sha String.duplicate("a", 40)
  @run "symphony-governance-69"
  @now ~U[2026-10-16 06:00:00.000Z]

  defp context, do: %{sha: @sha, issue: %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => 69, "runId" => @run}}}

  defp provenance,
    do: %{
      "origin" => "http://127.0.0.1:8110",
      "providerKind" => "synthetic",
      "backendCommitSha" => @sha,
      "epoch" => "dev-epoch",
      "receiptId" => nil,
      "rawHistoryUnknown" => true,
      "counterFloor" => %{"planning" => 2, "implementation" => 0, "technical" => 0, "transport" => 0}
    }

  defp reads do
    %{
      "issue" => %{
        "number" => 69,
        "title" => "secret=DO_NOT_EXPORT",
        "body" => "NEVER_EXPORT_RAW_BODY",
        "state" => "open",
        "labels" => ["agent:running"],
        "definitionDigest" => "sha256:" <> String.duplicate("b", 64),
        "claim" => %{"runId" => @run, "runnerId" => "x1", "leaseExpiresAt" => "2026-10-16T06:00:40.000Z"},
        "governanceIdentity" => %{"verified" => true, "authenticatedBy" => "bos-host-hmac-v2"},
        "governance" => %{"developmentExecution" => %{"epoch" => "dev-epoch"}, "counters" => %{"planning" => 2, "implementation" => 0, "technical" => 0, "transport" => 0}}
      },
      "run" => %{"repositoryId" => "symphony", "runId" => @run, "issueNumber" => 69, "status" => "running", "headCommit" => @sha, "runner" => %{"id" => "x1"}},
      "timeline" => %{"runId" => @run, "events" => [], "verification" => %{"valid" => true, "eventCount" => nil}}
    }
  end

  defp texts(reads), do: Map.new(reads, fn {key, value} -> {key, Jason.encode!(value)} end)
  # Small adversarial contract fixture; the separate integration check uses the
  # exact Front-generated schema pin, rather than treating this fixture as wire authority.
  defp schema do
    s = %{"type" => ["string", "null"]}
    n = %{"type" => ["number", "null"]}
    b = %{"type" => ["boolean", "null"]}
    object = fn properties -> %{"type" => ["object", "null"], "additionalProperties" => false, "properties" => properties} end

    object.(%{
      "issue" => object.(%{"number" => n, "title" => s, "labels" => %{"items" => s}, "definitionDigest" => s, "governance" => object.(%{"readiness" => object.(%{"runId" => s})})}),
      "run" => object.(%{"runId" => s, "issueNumber" => n, "headCommit" => s, "auditChain" => object.(%{"scopeId" => s})}),
      "timeline" => object.(%{"runId" => s, "events" => %{"items" => object.(%{})}, "verification" => object.(%{"valid" => b, "eventCount" => n})})
    })
  end

  defp build(values \\ reads(), meta \\ provenance(), at \\ @now), do: Snapshot.build(context(), texts(values), meta, schema(), @now, at)

  defp refresh_fixture do
    root = Path.join(System.tmp_dir!(), "bos-snapshot-refresh-test-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    directory = Path.join(root, "export")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    lock = Path.join(directory, ".snapshot.lock")
    File.write!(lock, "")
    File.chmod!(lock, 0o600)

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-snapshot-refresh-test-")
      true = File.lstat!(root).type == :directory
      File.rm_rf!(root)
    end)

    contract = Path.join(root, "projection-contract.json")
    File.write!(contract, Jason.encode!(%{"$defs" => %{"payload" => schema()}}))
    dir_stat = File.stat!(directory)
    lock_stat = File.stat!(lock)
    custody = %{"directory" => directory, "directoryDevice" => dir_stat.major_device, "directoryInode" => dir_stat.inode, "lockDevice" => lock_stat.major_device, "lockInode" => lock_stat.inode}
    python = "/usr/bin/python3"
    execution = %{journal_root: Path.join(root, "journal"), python_executable: python, python_sha256: SymphonyElixir.GovernanceBuildReceipt.file_digest(python)}
    settings = %{enabled: true, contract_path: contract, contract_sha256: SymphonyElixir.GovernanceBuildReceipt.file_digest(contract), provenance: provenance(), custody: custody}
    expiry = DateTime.utc_now() |> DateTime.add(40, :second) |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    values = put_in(reads(), ["issue", "claim", "leaseExpiresAt"], expiry)
    %{execution: execution, settings: settings, values: values, file: Path.join(directory, "symphony-69.snapshot.json")}
  end

  defp refresh_fetch(values) do
    original = Map.new(texts(values), fn {key, text} -> {key, " \n" <> text <> " "} end)

    fn tool, args ->
      {key, expected} =
        case tool do
          "bos_get_issue" -> {"issue", %{"issueNumber" => 69}}
          "bos_get_delivery_run" -> {"run", %{"runId" => @run}}
          "bos_get_run_history" -> {"timeline", %{"runId" => @run}}
        end

      assert args == expected
      Process.put(:refresh_calls, Process.get(:refresh_calls, []) ++ [tool])
      {:ok, %{"content" => [%{"type" => "text", "text" => original[key]}]}}
    end
  end

  test "disabled refresh has no callbacks, dependency reads or export side effects" do
    absent = Path.join(System.tmp_dir!(), "bos-snapshot-disabled-#{System.unique_integer([:positive])}")
    fetch = fn _, _ -> flunk("disabled producer must not call MCP") end
    refute File.exists?(absent)

    for settings <- [nil, %{}, %{enabled: false, contract_path: absent, custody: %{}}] do
      assert {:ok, :disabled} = Snapshot.refresh(%{}, settings, nil, fetch)
    end

    refute File.exists?(absent)
  end

  test "invalid opt-in scope, settings, Python pin and schema pin fail before any MCP read" do
    fixture = refresh_fixture()
    Process.put(:unexpected_refresh_calls, 0)

    fetch = fn _, _ ->
      Process.put(:unexpected_refresh_calls, Process.get(:unexpected_refresh_calls) + 1)
      {:error, :unexpected_mcp_read}
    end

    invalid_settings = [
      %{fixture.settings | enabled: "true"},
      %{"enabled" => true},
      Map.put(fixture.settings, :unknown, true),
      %{fixture.settings | contract_sha256: String.duplicate("0", 64)},
      %{fixture.settings | custody: %{}}
    ]

    for settings <- invalid_settings do
      assert {:error, _} = Snapshot.refresh(context(), settings, fixture.execution, fetch)
    end

    assert {:error, _} = Snapshot.refresh(put_in(context(), [:issue, :native_ref, "issueNumber"], 70), fixture.settings, fixture.execution, fetch)
    assert {:error, _} = Snapshot.refresh(context(), fixture.settings, %{fixture.execution | python_sha256: String.duplicate("0", 64)}, fetch)
    assert Process.get(:unexpected_refresh_calls) == 0
    refute File.exists?(fixture.file)
    refute File.exists?(fixture.execution.journal_root)
  end

  test "refresh connects original MCP bytes to immutable observation and real private export; rereading is not refresh" do
    fixture = refresh_fixture()
    fetch = refresh_fetch(fixture.values)
    assert {:ok, metadata} = Snapshot.refresh(context(), fixture.settings, fixture.execution, fetch)
    assert Process.get(:refresh_calls) == ~w(bos_get_issue bos_get_delivery_run bos_get_run_history)
    bytes = File.read!(fixture.file)
    exported = Jason.decode!(bytes)
    assert metadata["exportSha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert metadata["hostObservationId"] == exported["source"]["hostObservationId"]
    assert metadata["readAt"] == exported["readAt"]
    assert Map.keys(metadata) |> Enum.sort() == Enum.sort(~w(candidateCommitSha epoch readAt issuedAt expiresAt payloadDigest hostObservationId exportSha256 file))
    original_issue = " \n" <> Jason.encode!(fixture.values["issue"]) <> " "
    assert exported["source"]["originalResponseDigests"]["issue"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, original_issue), case: :lower)
    assert exported["expiresAt"] == fixture.values["issue"]["claim"]["leaseExpiresAt"]
    refute bytes =~ "DO_NOT_EXPORT"
    refute bytes =~ "NEVER_EXPORT_RAW_BODY"
    assert get_in(Jason.decode!(exported["payloadJson"]), ["timeline", "verification", "eventCount"]) == nil
    basis = Map.update!(exported, "source", &Map.delete(&1, "hostObservationId"))

    assert {:ok, %{"record" => ^basis}} =
             SymphonyElixir.GovernanceHostStore.request(
               fixture.execution,
               %{"kind" => "observation", "command" => "read", "id" => metadata["hostObservationId"]}
             )

    assert File.read!(fixture.file) == bytes
    assert length(Process.get(:refresh_calls)) == 3
    assert {:ok, next} = Snapshot.refresh(context(), fixture.settings, fixture.execution, fetch)
    assert length(Process.get(:refresh_calls)) == 6
    assert next["readAt"] >= metadata["readAt"]
  end

  test "failed fixed read and invalid authenticated observation cannot produce an export or host observation" do
    fixture = refresh_fixture()

    for rejected <- ~w(bos_get_issue bos_get_delivery_run bos_get_run_history) do
      Process.put(:refresh_calls, [])
      good = refresh_fetch(fixture.values)

      fetch = fn tool, args ->
        if tool == rejected do
          Process.put(:refresh_calls, Process.get(:refresh_calls) ++ [tool])
          {:error, :synthetic_transport_failure}
        else
          good.(tool, args)
        end
      end

      assert {:error, :snapshot_read_unavailable} = Snapshot.refresh(context(), fixture.settings, fixture.execution, fetch)
      assert List.last(Process.get(:refresh_calls)) == rejected
      refute File.exists?(fixture.file)
      refute File.exists?(fixture.execution.journal_root)
    end

    unauthenticated = put_in(fixture.values, ["issue", "governanceIdentity", "verified"], false)
    assert {:error, _} = Snapshot.refresh(context(), fixture.settings, fixture.execution, refresh_fetch(unauthenticated))
    refute File.exists?(fixture.file)
    refute File.exists?(fixture.execution.journal_root)
  end

  test "refresh does not report success when the existing private publisher rejects custody" do
    fixture = refresh_fixture()
    settings = put_in(fixture.settings, [:custody, "lockInode"], fixture.settings.custody["lockInode"] + 1)
    assert {:error, _} = Snapshot.refresh(context(), settings, fixture.execution, refresh_fetch(fixture.values))
    refute File.exists?(fixture.file)
  end

  test "original text byte digests precede minimization; TTL never exceeds actual lease and unknown count stays null" do
    original = texts(reads())
    assert {:ok, snapshot} = build()
    assert snapshot["expiresAt"] == "2026-10-16T06:00:40.000Z"
    assert snapshot["source"]["reservationKind"] == "governed_run_lease"
    assert snapshot["source"]["canonicalFulfillment"] == false
    assert Regex.match?(~r/^[a-f0-9]{64}$/, snapshot["source"]["hostObservationId"])
    assert {:error, _} = build(reads(), Map.put(provenance(), "hostObservationId", "fake-reference"))
    assert snapshot["source"]["rawHistoryUnknown"] == true
    assert snapshot["source"]["originalResponseDigests"]["issue"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, original["issue"]), case: :lower)
    assert snapshot["payloadDigest"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, snapshot["payloadJson"]), case: :lower)
    refute snapshot["payloadJson"] =~ "DO_NOT_EXPORT"
    refute snapshot["payloadJson"] =~ "NEVER_EXPORT_RAW_BODY"
    assert get_in(Jason.decode!(snapshot["payloadJson"]), ["timeline", "verification", "eventCount"]) == nil
  end

  test "lease, actor, epoch, candidate, scope and counter rollback fail closed independently" do
    mutations = [
      fn x -> put_in(x, ["issue", "claim", "leaseExpiresAt"], "2026-10-16T05:59:59Z") end,
      fn x -> put_in(x, ["issue", "claim", "runnerId"], "foreign") end,
      fn x -> put_in(x, ["issue", "governanceIdentity", "verified"], false) end,
      fn x -> put_in(x, ["issue", "governance", "developmentExecution", "epoch"], "old") end,
      fn x -> put_in(x, ["run", "headCommit"], String.duplicate("b", 40)) end,
      fn x -> put_in(x, ["timeline", "runId"], "foreign") end,
      fn x -> put_in(x, ["run", "auditChain"], %{"scopeId" => "foreign"}) end,
      fn x -> put_in(x, ["issue", "governance", "readiness"], %{"runId" => "foreign"}) end,
      fn x -> put_in(x, ["issue", "governance", "counters", "planning"], 1) end
    ]

    for mutate <- mutations do
      assert {:ok, _} = build()
      assert {:error, _} = build(mutate.(reads()))
    end
  end

  test "stale collection, production origin and malformed allowed fields cannot publish evidence" do
    assert {:error, _} = build(reads(), provenance(), DateTime.add(@now, 61, :second))
    assert {:error, _} = build(reads(), Map.put(provenance(), "origin", "https://api2.gamificationapi.com"))
    assert {:error, _} = build(put_in(reads(), ["run", "issueNumber"], "69"))
    assert {:error, _} = build(put_in(reads(), ["issue", "labels"], ["Bearer PRIVATE"]))
  end

  test "fixed existing tools preserve raw MCP strings and reject ambiguous or error content" do
    Process.put(:snapshot_calls, [])

    fetch = fn tool, args ->
      Process.put(:snapshot_calls, Process.get(:snapshot_calls) ++ [{tool, args}])
      {:ok, %{"content" => [%{"type" => "text", "text" => " {\"original\":true} "}]}}
    end

    assert {:ok, collected, _} = Snapshot.collect(fetch)
    assert collected["issue"] == " {\"original\":true} "
    assert Enum.map(Process.get(:snapshot_calls), &elem(&1, 0)) == ~w(bos_get_issue bos_get_delivery_run bos_get_run_history)
    assert {:error, _} = Snapshot.collect(fn _, _ -> {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "{}"}]}} end)
    assert {:error, _} = Snapshot.collect(fn _, _ -> {:ok, %{"content" => [%{"type" => "text", "text" => "{}"}, %{"type" => "text", "text" => "{}"}]}} end)
  end

  test "real private export is atomic, pinned and replayable; symlink and substituted lock are rejected" do
    root = Path.join(System.tmp_dir!(), "bos-snapshot-test-#{System.unique_integer([:positive])}")
    directory = Path.join(root, "export")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    lock = Path.join(directory, ".snapshot.lock")
    File.write!(lock, "")
    File.chmod!(lock, 0o600)

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-snapshot-test-")
      File.rm_rf!(root)
    end)

    dir_stat = File.stat!(directory)
    lock_stat = File.stat!(lock)
    custody = %{"directory" => directory, "directoryDevice" => dir_stat.major_device, "directoryInode" => dir_stat.inode, "lockDevice" => lock_stat.major_device, "lockInode" => lock_stat.inode}
    python = "/usr/bin/python3"
    execution = %{journal_root: Path.join(root, "journal"), python_executable: python, python_sha256: SymphonyElixir.GovernanceBuildReceipt.file_digest(python)}
    assert {:ok, envelope} = build()
    assert {:error, _} = Snapshot.publish(execution, custody, put_in(envelope, ["source", "hostObservationId"], "fake-reference"))
    assert {:ok, %{"ok" => true}} = Snapshot.publish(execution, custody, envelope)
    observation_id = envelope["source"]["hostObservationId"]
    basis = Map.update!(envelope, "source", &Map.delete(&1, "hostObservationId"))
    assert {:ok, %{"record" => ^basis}} = SymphonyElixir.GovernanceHostStore.request(execution, %{"kind" => "observation", "command" => "read", "id" => observation_id})
    file = Path.join(directory, "symphony-69.snapshot.json")
    assert Jason.decode!(File.read!(file)) == envelope
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert {:ok, _} = Snapshot.publish(execution, custody, envelope)
    File.rm!(file)
    outside = Path.join(root, "outside")
    File.write!(outside, "UNCHANGED")
    File.ln_s!(outside, file)
    assert {:error, _} = Snapshot.publish(execution, custody, envelope)
    assert File.read!(outside) == "UNCHANGED"
    File.rm!(file)
    File.rename!(lock, lock <> ".old")
    File.write!(lock, "")
    File.chmod!(lock, 0o600)
    assert {:error, _} = Snapshot.publish(execution, custody, envelope)
    refute File.exists?(file)
  end
end
