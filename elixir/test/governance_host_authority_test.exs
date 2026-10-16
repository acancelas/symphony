defmodule SymphonyElixir.GovernanceHostAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GovernanceCandidatePublication
  alias SymphonyElixir.GovernanceExecutionAuthority
  alias SymphonyElixir.GovernanceExecutionMonitor
  alias SymphonyElixir.GovernanceProcess
  alias SymphonyElixir.GovernanceTrustedGit

  setup do
    root = Path.join(System.tmp_dir!(), "bos-authority-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-authority-")
      File.rm_rf!(root)
    end)

    {_, 0} = System.cmd("/usr/bin/git", ["init", "-q", root])
    File.mkdir_p!(root <> "/elixir/lib")
    File.write!(root <> "/elixir/lib/value.txt", "baseline")
    {_, 0} = fixture_git(root, ["add", "."])

    {_, 0} =
      fixture_git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline"])

    {head, 0} = fixture_git(root, ["rev-parse", "HEAD"])
    manifest = %{"planHash" => "sha256: " <> String.duplicate("a", 64), "catalogCommitSha" => String.duplicate("b", 40)}

    context = %{
      workspace: root,
      sha: String.trim(head),
      manifest: manifest,
      issue: %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => 69, "runId" => "run69"}},
      principal: %{invocation_id: "inv-one"}
    }

    now = DateTime.utc_now()

    source = %{
      "claim" => %{"runId" => "run69", "leaseExpiresAt" => DateTime.to_iso8601(DateTime.add(now, 60))},
      "governance" => %{
        "phases" => %{
          "planning" =>
            Map.merge(manifest, %{
              "candidateCommitSha" => context.sha,
              "verdict" => %{"status" => "passed", "verdict" => "APPROVED_WITH_NOTES"}
            })
        },
        "readiness" => Map.merge(manifest, %{"candidateCommitSha" => context.sha, "state" => "READY", "status" => "passed"}),
        "developmentExecution" => %{
          "protocolVersion" => 1,
          "epoch" => "epoch-one",
          "active" => true,
          "authorityGeneration" => 1,
          "sourcePublicationId" => "pub-one",
          "budgetScopeId" => "scope-one",
          "approvalId" => "approval-one",
          "lastObservedAt" => DateTime.to_iso8601(now),
          "baselineCommitSha" => context.sha,
          "limits" => %{
            "maxAttempts" => 2,
            "maxUncachedInputTokens" => 600_000,
            "maximumDurationSeconds" => 2400,
            "additionalPurchasesAllowed" => false,
            "costUsd" => nil,
            "costMeasurement" => "unknown"
          },
          "consumed" => %{"attempts" => 2, "uncachedInputTokens" => 100, "wallTimeSeconds" => 3},
          "reserved" => %{"attempts" => 0, "uncachedInputTokens" => 100, "wallTimeSeconds" => 10}
        }
      }
    }

    {:ok, root: root, context: context, source: source, now: now}
  end

  defp fixture_git(root, args),
    do: System.cmd("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", root | args], stderr_to_stdout: true)

  test "proposal targets come only from the server-approved exact baseline plan", ctx do
    json = SymphonyElixir.Audit.CanonicalJson.encode(%{"version" => 1, "files" => ["elixir/lib/value.txt"]}) |> IO.iodata_to_binary()
    plan = "Approved work\n\n```bos-implementation-files\n" <> json <> "\n```\n"
    {context, source} = proposal_plan(ctx, plan)
    assert {:ok, ["elixir/lib/value.txt"]} = GovernanceCandidatePublication.proposal_paths(context, source)
    File.write!(ctx.root <> "/docs/issues/69/plan.md", "unapproved working-tree replacement")
    assert {:ok, ["elixir/lib/value.txt"]} = GovernanceCandidatePublication.proposal_paths(context, source)
    revoked = put_in(source, ["governance", "developmentExecution", "active"], false)
    assert {:error, _} = GovernanceCandidatePublication.proposal_paths(context, revoked)
    altered = put_in(context, [:manifest, "planHash"], "sha256:" <> String.duplicate("f", 64))
    assert {:error, _} = GovernanceCandidatePublication.proposal_paths(altered, source)
  end

  test "ambiguous, absent, unapproved and policy target inventories fail closed", ctx do
    for inventory <- [
          nil,
          %{"version" => 1, "files" => []},
          %{"version" => 1, "files" => ["elixir/lib/value.txt", "elixir/lib/value.txt"]},
          %{"version" => 1, "files" => ["elixir/lib/new/AGENTS.override.md"]},
          %{"version" => 1, "files" => ["elixir/lib/../test/value.txt"]},
          %{"version" => 1, "files" => ["docs/issues/69/plan.md"]},
          %{"version" => 1, "files" => ["elixir/lib/value.txt"], "extra" => true}
        ] do
      plan =
        if inventory,
          do:
            "```bos-implementation-files\n" <>
              IO.iodata_to_binary(SymphonyElixir.Audit.CanonicalJson.encode(inventory)) <> "\n```\n",
          else: "Plan without file inventory\n"

      {context, source} = proposal_plan(ctx, plan)
      assert {:error, _} = GovernanceCandidatePublication.proposal_paths(context, source)
    end

    valid = "```bos-implementation-files\n{\"files\":[\"elixir/lib/value.txt\"],\"version\":1}\n```\n"
    {context, source} = proposal_plan(ctx, valid <> valid)
    assert {:error, _} = GovernanceCandidatePublication.proposal_paths(context, source)
  end

  test "structured proposal validates every approved CAS target without any filesystem mutation", ctx do
    plan = "```bos-implementation-files\n{\"files\":[\"elixir/lib/value.txt\"],\"version\":1}\n```\n"
    {context, source} = proposal_plan(ctx, plan)
    {blob, 0} = fixture_git(ctx.root, ["rev-parse", context.sha <> ":elixir/lib/value.txt"])
    change = %{"path" => "elixir/lib/value.txt", "expectedBlobSha" => String.trim(blob), "content" => "proposed"}
    proposal = %{"candidateCommitSha" => context.sha, "planHash" => context.manifest["planHash"], "changes" => [change]}
    assert {:ok, [^change]} = GovernanceCandidatePublication.validate_proposal(context, source, proposal)

    for invalid <- [
          Map.put(proposal, "candidateCommitSha", String.duplicate("f", 40)),
          Map.put(proposal, "changes", [change, Map.put(change, "path", "elixir/lib/unapproved.txt")]),
          Map.put(proposal, "changes", [change, change]),
          put_in(proposal, ["changes"], [Map.put(change, "expectedBlobSha", String.duplicate("f", 40))]),
          put_in(proposal, ["changes"], [Map.put(change, "content", <<0>>)]),
          Map.put(proposal, "command", "forbidden")
        ] do
      assert {:error, _} = GovernanceCandidatePublication.validate_proposal(context, source, invalid)
      assert File.read!(ctx.root <> "/elixir/lib/value.txt") == "baseline"
      assert {"", 0} = fixture_git(ctx.root, ["status", "--porcelain"])
    end

    File.write!(ctx.root <> "/elixir/lib/value.txt", "concurrent edit")
    assert {:error, _} = GovernanceCandidatePublication.validate_proposal(context, source, proposal)
  end

  defp proposal_plan(ctx, plan) do
    File.mkdir_p!(ctx.root <> "/docs/issues/69")
    File.write!(ctx.root <> "/docs/issues/69/plan.md", plan)
    {_, 0} = fixture_git(ctx.root, ["add", "docs/issues/69/plan.md"])
    {_, 0} = fixture_git(ctx.root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "plan"])
    {head, 0} = fixture_git(ctx.root, ["rev-parse", "HEAD"])
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, plan), case: :lower)
    context = %{ctx.context | sha: String.trim(head), manifest: Map.put(ctx.context.manifest, "planHash", hash)}

    source =
      ctx.source
      |> put_in(["governance", "developmentExecution", "baselineCommitSha"], context.sha)
      |> put_in(["governance", "phases", "planning", "candidateCommitSha"], context.sha)
      |> put_in(["governance", "phases", "planning", "planHash"], hash)
      |> put_in(["governance", "readiness", "candidateCommitSha"], context.sha)
      |> put_in(["governance", "readiness", "planHash"], hash)

    {context, source}
  end

  test "authority remains valid at the admitted attempt ceiling but denies stale/revoked/changed plan", ctx do
    assert {:ok, _} = GovernanceExecutionAuthority.check(ctx.context, ctx.source, nil, ctx.now)

    for source <- [
          put_in(ctx.source, ["governance", "developmentExecution", "active"], false),
          put_in(
            ctx.source,
            ["governance", "developmentExecution", "lastObservedAt"],
            DateTime.to_iso8601(DateTime.add(ctx.now, -31))
          ),
          put_in(ctx.source, ["governance", "readiness", "planHash"], "other"),
          put_in(ctx.source, ["governance", "developmentExecution", "consumed", "uncachedInputTokens"], 600_001)
        ] do
      assert {:error, _} = GovernanceExecutionAuthority.check(ctx.context, source, nil, ctx.now)
    end
  end

  test "admission cannot choose a different invocation, generation or publication", ctx do
    authority = get_in(ctx.source, ["governance", "developmentExecution"])

    admission = %{
      "ownerInvocationId" => "inv-one",
      "authorityGeneration" => 1,
      "sourcePublicationId" => "pub-one",
      "budgetScopeId" => "scope-one",
      "deadline" => DateTime.to_iso8601(DateTime.add(ctx.now, 30)),
      "reservedUncachedInputTokens" => 100,
      "reservedDurationSeconds" => 30,
      "reservationId" => "reservation",
      "attemptId" => "attempt",
      "executionId" => "execution",
      "workerId" => "worker"
    }

    assert GovernanceExecutionAuthority.admission_matches?(admission, authority, ctx.context, ctx.now)

    for {key, value} <- [
          {"ownerInvocationId", "forged"},
          {"authorityGeneration", 2},
          {"sourcePublicationId", "other"},
          {"deadline", DateTime.to_iso8601(DateTime.add(ctx.now, -1))}
        ] do
      refute GovernanceExecutionAuthority.admission_matches?(
               Map.put(admission, key, value),
               authority,
               ctx.context,
               ctx.now
             )
    end
  end

  test "host Git refuses an executable clean filter before touching modified source", ctx do
    marker = ctx.root <> "/filter-executed"
    File.write!(ctx.root <> "/.gitattributes", "*.txt filter=unsafe\n")
    {_, 0} = fixture_git(ctx.root, ["config", "filter.unsafe.clean", "touch " <> marker <> "; cat"])
    File.write!(ctx.root <> "/elixir/lib/value.txt", "modified")
    assert {_, 128} = GovernanceTrustedGit.run(ctx.root, ["status", "--porcelain"])
    refute File.exists?(marker)
  end

  test "publication rejects policy/scope edits and QA tree drift", ctx do
    File.write!(ctx.root <> "/AGENTS.md", "unapproved policy")
    assert {:error, _} = GovernanceCandidatePublication.stage(ctx.context)
    File.rm!(ctx.root <> "/AGENTS.md")
    File.write!(ctx.root <> "/elixir/lib/value.txt", "authorized edit")
    assert {:ok, tree} = GovernanceCandidatePublication.stage(ctx.context)
    assert :ok = GovernanceCandidatePublication.unchanged(ctx.context, tree)
    File.write!(ctx.root <> "/elixir/lib/value.txt", "changed after QA")
    assert {:error, _} = GovernanceCandidatePublication.unchanged(ctx.context, tree)
  end

  test "new override policies cannot be staged from writable source subtrees", ctx do
    for relative <- ["elixir/lib/AGENTS.override.md", "elixir/test/nested/AGENTS.override.md"] do
      path = Path.join(ctx.root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "unapproved new override policy")
      assert {:error, :governance_candidate_scope_rejected} = GovernanceCandidatePublication.stage(ctx.context)
      assert {"", 0} = fixture_git(ctx.root, ["diff", "--cached", "--name-only"])
      File.rm!(path)
    end
  end

  test "publication refuses created symlinks, protected aliases and tracked link deletions", ctx do
    link = ctx.root <> "/elixir/lib/alias"
    File.ln_s!("/outside-synthetic", link)
    assert {:error, _} = GovernanceCandidatePublication.stage(ctx.context)
    File.rm!(link)

    File.ln!(ctx.root <> "/elixir/lib/value.txt", link)
    assert {:error, _} = GovernanceCandidatePublication.stage(ctx.context)
    File.rm!(link)

    File.ln_s!("value.txt", link)
    {_, 0} = fixture_git(ctx.root, ["add", "elixir/lib/alias"])

    {_, 0} =
      fixture_git(ctx.root, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-qm",
        "historical symlink"
      ])

    {head, 0} = fixture_git(ctx.root, ["rev-parse", "HEAD"])
    File.rm!(link)
    assert {:error, _} = GovernanceCandidatePublication.stage(%{ctx.context | sha: String.trim(head)})
  end

  test "authority loss reaps a real process and missing telemetry is never invented", _ctx do
    env = Enum.map(System.get_env(), fn {k, _} -> {String.to_charlist(k), false} end)
    port = Port.open({:spawn_executable, ~c"/usr/bin/cat"}, [:binary, :exit_status, {:env, env}])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> GovernanceProcess.stop(port) end)

    admission = %{
      "deadline" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 30)),
      "reservedDurationSeconds" => 30,
      "reservedUncachedInputTokens" => 1000
    }

    {:ok, monitor} =
      GovernanceExecutionMonitor.start(
        port,
        admission,
        fn -> {:error, :revoked} end,
        fn _ -> flunk("No native measurement exists") end,
        System.monotonic_time(:millisecond)
      )

    Process.sleep(1300)
    refute File.exists?("/proc/#{pid}")
    assert {:error, _} = GovernanceExecutionMonitor.healthy?(monitor)
    assert {:error, :governance_execution_measurement_missing} = GovernanceExecutionMonitor.finish(monitor)
  end
end
