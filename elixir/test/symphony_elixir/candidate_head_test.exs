defmodule SymphonyElixir.CandidateHeadTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport,
    only: [register_process_cleanup!: 1, restore_env: 2]

  alias SymphonyElixir.CandidateHead
  alias SymphonyElixir.Tracker.Issue

  test "uses real local git to publish and confirm the default candidate path" do
    root = Path.join(System.tmp_dir!(), "candidate-head-real-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    workspace = Path.join(root, "workspace")
    process_owner = register_process_cleanup!("candidate-head-git-push-#{System.unique_integer([:positive])}")
    previous_owner = System.get_env("SYMPHONY_TEST_PROCESS_OWNER")

    on_exit(fn -> restore_env("SYMPHONY_TEST_PROCESS_OWNER", previous_owner) end)
    System.put_env("SYMPHONY_TEST_PROCESS_OWNER", process_owner)

    try do
      File.mkdir_p!(root)
      assert {_, 0} = System.cmd("git", ["init", "--bare", remote])
      assert {_, 0} = System.cmd("git", ["init", "-b", "bos/issue-6", workspace])
      assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      File.write!(Path.join(workspace, "README.md"), "candidate\n")
      assert {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])
      assert {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "candidate"])
      assert {_, 0} = System.cmd("git", ["-C", workspace, "remote", "add", "origin", remote])

      assert {:ok, %{branch: "bos/issue-6", head_sha: head, remote_sha: head}} =
               CandidateHead.confirm(workspace, %Issue{branch_name: "bos/issue-6"})

      assert String.length(head) == 40
    after
      File.rm_rf(root)
    end
  end

  test "pushes an unpublished clean candidate and confirms the exact remote SHA" do
    parent = self()
    head = "0123456789abcdef0123456789abcdef01234567"

    runner = fn workspace, worker_host, executable, args ->
      send(parent, {:command, workspace, worker_host, executable, args})

      case args do
        ["status" | _] ->
          {:ok, {"", 0}}

        ["rev-parse", "HEAD"] ->
          {:ok, {head <> "\n", 0}}

        ["symbolic-ref" | _] ->
          {:ok, {"bos/issue-6\n", 0}}

        ["ls-remote" | _] ->
          count = Process.get(:remote_queries, 0)
          Process.put(:remote_queries, count + 1)
          if count == 0, do: {:ok, {"", 0}}, else: {:ok, {"#{head}\trefs/heads/bos/issue-6\n", 0}}

        ["push", "--set-upstream", "origin", "HEAD:refs/heads/bos/issue-6"] ->
          {:ok, {"pushed\n", 0}}
      end
    end

    issue = %Issue{branch_name: "bos/issue-6"}

    assert {:ok, %{branch: "bos/issue-6", head_sha: ^head, remote_sha: ^head}} =
             CandidateHead.confirm("/workspace", issue, nil, command_runner: runner)

    assert_received {:command, "/workspace", nil, "git", ["push", "--set-upstream", "origin", "HEAD:refs/heads/bos/issue-6"]}
  end

  test "fails closed before any push when tracked files are dirty" do
    runner = fn _workspace, _worker_host, _executable, ["status" | _] ->
      {:ok, {" M lib/example.ex\n", 0}}
    end

    assert {:error, {:candidate_workspace_dirty, diagnosis}} =
             CandidateHead.confirm(
               "/workspace",
               %Issue{branch_name: "bos/issue-6"},
               nil,
               command_runner: runner
             )

    assert diagnosis.paths == ["lib/example.ex"]
    assert diagnosis.status == "M lib/example.ex"
    assert String.length(diagnosis.fingerprint) == 64
  end

  test "never force-pushes a divergent remote branch" do
    parent = self()
    local = "0123456789abcdef0123456789abcdef01234567"
    remote = "fedcba9876543210fedcba9876543210fedcba98"

    runner = fn _workspace, _worker_host, _executable, args ->
      send(parent, {:args, args})

      case args do
        ["status" | _] -> {:ok, {"", 0}}
        ["rev-parse", "HEAD"] -> {:ok, {local, 0}}
        ["symbolic-ref" | _] -> {:ok, {"bos/issue-6", 0}}
        ["ls-remote" | _] -> {:ok, {"#{remote}\trefs/heads/bos/issue-6\n", 0}}
        ["push" | _] -> {:ok, {"rejected non-fast-forward", 1}}
      end
    end

    assert {:error, {:candidate_git_failed, ["push" | push_args], 1, "rejected non-fast-forward"}} =
             CandidateHead.confirm(
               "/workspace",
               %Issue{branch_name: "bos/issue-6"},
               nil,
               command_runner: runner
             )

    refute "--force" in push_args
    refute "--force-with-lease" in push_args
  end

  test "accepts an already confirmed remote head without pushing" do
    head = "0123456789abcdef0123456789abcdef01234567"

    runner = fn _workspace, _worker_host, _executable, args ->
      case args do
        ["status" | _] -> {:ok, {"", 0}}
        ["rev-parse", "HEAD"] -> {:ok, {head, 0}}
        ["symbolic-ref" | _] -> {:ok, {"actual", 0}}
        ["ls-remote" | _] -> {:ok, {"#{head}\trefs/heads/actual", 0}}
      end
    end

    assert {:ok, %{head_sha: ^head}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: nil}, nil, command_runner: runner)

    assert {:ok, %{head_sha: ^head}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: ""}, nil, command_runner: runner)
  end

  test "rejects a branch mismatch before querying the remote" do
    runner = fn _workspace, _worker_host, _executable, args ->
      case args do
        ["status" | _] -> {:ok, {"", 0}}
        ["rev-parse", "HEAD"] -> {:ok, {String.duplicate("a", 40), 0}}
        ["symbolic-ref" | _] -> {:ok, {"actual", 0}}
      end
    end

    assert {:error, {:candidate_branch_mismatch, "expected", "actual"}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: "expected"}, nil, command_runner: runner)
  end

  test "reports invalid or failed remote confirmation without masking the cause" do
    head = String.duplicate("a", 40)
    other = String.duplicate("b", 40)

    base = fn args ->
      case args do
        ["status" | _] -> {:ok, {"", 0}}
        ["rev-parse", "HEAD"] -> {:ok, {head, 0}}
        ["symbolic-ref" | _] -> {:ok, {"bos/issue-6", 0}}
      end
    end

    invalid = fn _workspace, _worker_host, _executable, args ->
      case args do
        ["ls-remote" | _] -> {:ok, {"one two three", 0}}
        _ -> base.(args)
      end
    end

    assert {:error, {:invalid_candidate_remote_response, "one two three"}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: "bos/issue-6"}, nil, command_runner: invalid)

    Process.put(:remote_query, 0)

    stale_after_push = fn _workspace, _worker_host, _executable, args ->
      case args do
        ["ls-remote" | _] ->
          Process.put(:remote_query, Process.get(:remote_query) + 1)
          {:ok, {"#{other}\trefs/heads/bos/issue-6", 0}}

        ["push" | _] ->
          {:ok, {"pushed", 0}}

        _ ->
          base.(args)
      end
    end

    assert {:error, {:candidate_remote_mismatch, ^head, ^other, ^other}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: "bos/issue-6"}, nil, command_runner: stale_after_push)

    assert Process.get(:remote_query) == 2
  end

  test "preserves initial and post-push transport failures" do
    head = String.duplicate("a", 40)

    base = fn args ->
      case args do
        ["status" | _] -> {:ok, {"", 0}}
        ["rev-parse", "HEAD"] -> {:ok, {head, 0}}
        ["symbolic-ref" | _] -> {:ok, {"bos/issue-6", 0}}
      end
    end

    initial_failure = fn _workspace, _worker_host, _executable, args ->
      if hd(args) == "ls-remote", do: {:error, :offline}, else: base.(args)
    end

    assert {:error, {:candidate_git_transport_failed, ["ls-remote" | _], :offline}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: "bos/issue-6"}, nil, command_runner: initial_failure)

    Process.put(:post_push_query, 0)

    post_push_failure = fn _workspace, _worker_host, _executable, args ->
      case args do
        ["ls-remote" | _] ->
          query = Process.get(:post_push_query)
          Process.put(:post_push_query, query + 1)
          if query == 0, do: {:ok, {"", 0}}, else: {:error, :offline}

        ["push" | _] ->
          {:ok, {"pushed", 0}}

        _ ->
          base.(args)
      end
    end

    assert {:error, {:candidate_git_transport_failed, ["ls-remote" | _], :offline}} =
             CandidateHead.confirm("/workspace", %Issue{branch_name: "bos/issue-6"}, nil, command_runner: post_push_failure)
  end

  test "fails explicitly for remote workers until atomic remote confirmation is implemented" do
    assert {:error, {:candidate_remote_worker_unsupported, "worker-2"}} =
             CandidateHead.confirm(
               "/workspace",
               %Issue{branch_name: "bos/issue-6"},
               "worker-2"
             )
  end
end
