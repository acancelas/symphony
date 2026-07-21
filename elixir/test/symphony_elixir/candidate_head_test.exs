defmodule SymphonyElixir.CandidateHeadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CandidateHead
  alias SymphonyElixir.Tracker.Issue

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

    assert {:error, {:candidate_workspace_dirty, "M lib/example.ex"}} =
             CandidateHead.confirm(
               "/workspace",
               %Issue{branch_name: "bos/issue-6"},
               nil,
               command_runner: runner
             )
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
end
