defmodule SymphonyElixir.WorkspaceAdmissionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.WorkspaceAdmission
  @guard_source System.get_env("BOS_WORKSPACE_GUARD_FIXTURE")

  @tag skip: is_nil(@guard_source)
  test "real guard caps principal plus three tasks, reuses ownership and pins freshly fetched main" do
    root = Path.join(System.tmp_dir!(), "symphony-admission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    remote = Path.join(root, "origin.git")
    canonical = Path.join(root, "principal")
    File.mkdir_p!(canonical)
    git!(root, ["init", "--bare", remote])
    git!(canonical, ["init", "-b", "main"])
    git!(canonical, ["config", "user.name", "Fixture"])
    git!(canonical, ["config", "user.email", "fixture@example.test"])
    git!(canonical, ["remote", "add", "origin", remote])
    File.write!(Path.join(canonical, "value"), "main1")
    git!(canonical, ["add", "value"])
    git!(canonical, ["commit", "-m", "initial"])
    git!(canonical, ["push", "origin", "main"])
    git!(canonical, ["switch", "-c", "unrelated-feature"])
    File.write!(Path.join(canonical, "feature"), "unrelated")
    git!(canonical, ["add", "feature"])
    git!(canonical, ["commit", "-m", "feature"])

    guard = @guard_source
    assert File.regular?(guard)
    wrapper = Path.join(root, "bos-workspace")
    node = System.find_executable("node")
    assert is_binary(node)
    File.write!(wrapper, "#!/bin/sh\nHOME='#{root}/fixture-home' exec '#{node}' '#{guard}' \"$@\"\n")
    File.chmod!(wrapper, 0o700)

    config = %{
      "command" => wrapper,
      "command_sha256" => digest(File.read!(wrapper)),
      "guard_path" => guard,
      "guard_sha256" => digest(File.read!(guard)),
      "canonical_repositories" => %{"fixture" => canonical}
    }

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "legacy"), hook_after_create: "printf admitted > hook-result")
    text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(text, "workspace:\n", "workspace:\n  admission: #{Jason.encode!(config)}\n"))
    context = %{repository_id: "fixture", issue_id: "1", run_id: "stable-run-1"}
    assert {:ok, first} = WorkspaceAdmission.create(context)
    refute File.exists?(Path.join(first, "feature"))

    # Advance the real fixture remote after the first admission while preserving feature HEAD.
    git!(canonical, ["switch", "main"])
    File.write!(Path.join(canonical, "value"), "main2")
    git!(canonical, ["commit", "-am", "updated main"])
    main = git!(canonical, ["rev-parse", "HEAD"]) |> String.trim()
    git!(canonical, ["push", "origin", "main"])
    git!(canonical, ["switch", "unrelated-feature"])
    assert {:ok, second} = WorkspaceAdmission.create(%{context | issue_id: "2"})
    assert String.trim(git!(second, ["rev-parse", "HEAD"])) == main
    assert File.read!(Path.join(second, "value")) == "main2"
    assert {:ok, third} = WorkspaceAdmission.create(%{context | issue_id: "3"})
    assert {:ok, ^first} = WorkspaceAdmission.create(context)
    assert {:error, {:workspace_admission_blocked, "consolidation_required"}} = WorkspaceAdmission.create(%{context | issue_id: "4"})
    assert {:error, {:workspace_admission_blocked, "task_owned_by_another_session"}} = WorkspaceAdmission.create(%{context | run_id: "other-run"})
    assert {:error, :workspace_admission_scope_unverified} = WorkspaceAdmission.create(%{context | repository_id: "unknown"})
    assert Enum.all?([first, second, third], &File.dir?/1)
    assert length(String.split(git!(canonical, ["worktree", "list", "--porcelain"]), "worktree ")) - 1 == 4
    refute File.exists?(Path.join(root, "legacy"))

    issue = %{id: "1", identifier: "FIX-1", native_ref: %{"repositoryId" => "fixture", "runId" => "stable-run-1"}}
    assert {:ok, ^first} = Workspace.create_for_issue(issue)
    assert File.read!(Path.join(first, "hook-result")) == "admitted"
    File.write!(Path.join(first, "hook-result"), "preserved")
    assert {:ok, ^first} = Workspace.create_for_issue(issue)
    assert File.read!(Path.join(first, "hook-result")) == "preserved"
    assert {:error, :workspace_admission_remote_not_configured} = Workspace.create_for_issue(issue, "remote-host")
    assert {:error, :workspace_admission_retirement_requires_owner_check, ^first} = Workspace.remove(first)
    retirement = Workspace.remove_recorded(first, nil)
    assert {:error, :workspace_admission_retirement_requires_owner_check, ^first} = retirement
    assert File.dir?(first)
    assert {:error, :workspace_admission_path_unverified} = WorkspaceAdmission.validate_path(canonical)
    unregistered = Path.join(root, "unregistered")
    assert {:error, :workspace_admission_path_unverified} = WorkspaceAdmission.validate_path(unregistered)
    assert {:error, {:invalid_workspace_cwd, :admission_unverified, ^canonical}} = AppServer.start_session(canonical)

    # A second primary with the same origin cannot obtain another allocation namespace.
    alternate = Path.join(root, "alternate")
    File.mkdir_p!(alternate)
    git!(alternate, ["init", "-b", "main"])
    git!(alternate, ["config", "user.name", "Fixture"])
    git!(alternate, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(alternate, "value"), "other primary")
    git!(alternate, ["add", "value"])
    git!(alternate, ["commit", "-m", "alternate"])
    git!(alternate, ["remote", "add", "origin", remote])
    changed = put_in(config, ["canonical_repositories", "fixture"], alternate)
    File.write!(Workflow.workflow_file_path(), String.replace(text, "workspace:\n", "workspace:\n  admission: #{Jason.encode!(changed)}\n"))
    assert {:error, {:workspace_admission_blocked, "duplicate_clone_or_canonical_mismatch"}} = WorkspaceAdmission.create(%{context | issue_id: "5"})
    File.write!(Workflow.workflow_file_path(), String.replace(text, "workspace:\n", "workspace:\n  admission: #{Jason.encode!(config)}\n"))
    # A failed canonical inventory read must deny an otherwise valid worktree.
    git_binary = System.find_executable("git")
    bin = Path.join(root, "fault-bin")
    File.mkdir_p!(bin)
    shim = Path.join(bin, "git")
    script = "#!/bin/sh\nif [ \"$3\" = worktree ] && [ \"$4\" = list ]; then exit 74; fi\nexec '#{git_binary}' \"$@\"\n"
    File.write!(shim, script)
    File.chmod!(shim, 0o700)
    previous_path = System.get_env("PATH")

    try do
      System.put_env("PATH", bin <> ":" <> previous_path)
      assert {:error, :workspace_admission_path_unverified} = WorkspaceAdmission.validate_path(second)
    after
      System.put_env("PATH", previous_path)
    end

    File.write!(wrapper, "# changed pin\n", [:append])
    assert {:error, :workspace_admission_configuration_invalid} = WorkspaceAdmission.create(context)
  end

  test "malformed admission configuration fails closed without legacy bootstrap" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_after_create: "exit 99")
    text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(text, "workspace:\n", "workspace:\n  admission: {}\n"))
    issue = %{id: "1", identifier: "X", native_ref: %{}}
    assert {:error, :workspace_admission_configuration_invalid} = Workspace.create_for_issue(issue)
  end

  test "guard protocol errors, output bounds and timeout preserve scope without a clone fallback" do
    root = Path.join(System.tmp_dir!(), "symphony-admission-errors-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    guard = Path.join(root, "guard")
    File.write!(guard, "synthetic guarded entrypoint")
    command = Path.join(root, "bos-workspace")
    context = %{repository_id: "fixture", issue_id: "1", run_id: "run"}
    config = %{"command" => command, "guard_path" => guard, "guard_sha256" => digest(File.read!(guard)), "canonical_repositories" => %{"fixture" => root}}

    for {body, expected} <- [
          {"printf invalid", :workspace_admission_response_invalid},
          {"printf invalid; exit 1", :workspace_admission_failed_reconcile_required},
          {"head -c 70000 /dev/zero", :workspace_admission_output_exceeded}
        ] do
      configure_command!(command, body, config)
      assert {:error, ^expected} = WorkspaceAdmission.create(context)
    end

    task = WorkspaceAdmission.task_id("fixture", "1")

    record = %{
      "status" => "created",
      "enforced" => true,
      "state" => "created",
      "task" => task,
      "owner" => "run",
      "limit" => 4,
      "occupied" => 1,
      "baseSha" => String.duplicate("a", 40),
      "path" => Path.join([Path.dirname(root), ".bos-worktrees", Path.basename(root), task]),
      "branch" => "refs/heads/codex/" <> task
    }

    configure_command!(command, "printf '%s' '" <> Jason.encode!(record) <> "'", config)
    assert {:error, :workspace_admission_scope_unverified} = WorkspaceAdmission.create(context)
    assert {:error, :workspace_admission_path_unverified} = WorkspaceAdmission.validate_path(nil)

    configure_command!(command, "sleep 30", Map.put(config, "timeout_ms", 25))
    assert {:error, :workspace_admission_timeout_reconcile_required} = WorkspaceAdmission.create(context)
    refute File.exists?(Path.join(root, ".git"))
    configure_command!(command, "exit 0", config)
    File.chmod!(command, 0o600)
    assert {:error, :workspace_admission_unavailable} = WorkspaceAdmission.create(context)
  end

  defp configure_command!(path, body, config) do
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o700)
    config = Map.put(config, "command_sha256", digest(File.read!(path)))
    write_workflow_file!(Workflow.workflow_file_path())
    text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(text, "workspace:\n", "workspace:\n  admission: #{Jason.encode!(config)}\n"))
  end

  defp git!(directory, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: directory, stderr_to_stdout: true)
    output
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
