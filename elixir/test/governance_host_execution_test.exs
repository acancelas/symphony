defmodule SymphonyElixir.GovernanceHostExecutionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.GovernanceExecutionJournal
  alias SymphonyElixir.GovernanceHostStore
  alias SymphonyElixir.GovernanceProcess
  alias SymphonyElixir.GovernanceWorkspaceProfile

  setup do
    root = Path.join(System.tmp_dir!(), "bos-host-store-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-host-store-")
      File.rm_rf!(root)
    end)

    python = "/usr/bin/python3"

    store = %{journal_root: root, python_executable: python, python_sha256: GovernanceBuildReceipt.file_digest(python)}
    {:ok, root: root, store: store}
  end

  defp execution_binding,
    do: %{
      "repositoryId" => "symphony",
      "issueNumber" => 69,
      "runId" => "run69",
      "attemptId" => "attempt1",
      "reservationId" => "reservation1",
      "hostInvocationId" => "invocation1",
      "workerId" => "worker1",
      "authorityGeneration" => 1
    }

  test "exclusive ownership spans suspended launcher, real spawn and attach; replay cannot launch", %{store: store} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, launch} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
        send(parent, {:intent, self(), launch.lease})

        receive do
          :resume -> :ok
        end

        port =
          Port.open({:spawn_executable, ~c"/usr/bin/cat"}, [
            :binary,
            :exit_status,
            {:env,
             Enum.map(System.get_env(), fn {k, _} -> {String.to_charlist(k), false} end) ++
               [{~c"BOS_HOST_WORKER_MARKER", String.to_charlist(launch.marker)}]}
          ])

        {:ok, witness} = GovernanceExecutionJournal.attach(store, execution_binding(), port, launch)
        send(parent, {:attached, witness, port})

        receive do
          :finish -> :ok
        end

        GovernanceProcess.stop(port)

        {:ok, %{"record" => %{"state" => "COMPLETED"}}} =
          GovernanceExecutionJournal.transition(store, execution_binding(), "finish")

        GovernanceHostStore.release(launch.lease)
        send(parent, :finished)
      end)

    assert_receive {:intent, ^owner, lease}, 5000

    on_exit(fn ->
      GovernanceHostStore.release(lease)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert {:error, _} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
    # A claimant with a new invocation cannot rotate the logical reservation key.
    assert {:error, _} =
             GovernanceExecutionJournal.spawn_once(store, Map.put(execution_binding(), "hostInvocationId", "other"))

    send(owner, :resume)
    assert_receive {:attached, %{"pid" => pid, "startTicks" => ticks}, port}, 5000
    on_exit(fn -> GovernanceProcess.stop(port) end)
    assert is_integer(pid) and is_binary(ticks)
    assert {:error, _} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
    send(owner, :finish)
    assert_receive :finished, 5000
    assert {:error, _} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
  end

  test "uncertain process creation is fenced and never retried as a new spawn", %{store: store} do
    {:ok, launch} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
    GovernanceHostStore.release(launch.lease)
    assert {:error, _} = GovernanceExecutionJournal.spawn_once(store, execution_binding())

    assert {:ok, %{"record" => %{"state" => "SPAWN_INTENT"}}} =
             GovernanceExecutionJournal.transition(store, execution_binding(), "read")

    assert {:ok, _} = GovernanceExecutionJournal.transition(store, execution_binding(), "fence")
    assert {:error, _} = GovernanceExecutionJournal.spawn_once(store, execution_binding())
  end

  test "tampering and crash-prepared storage deny all authority", %{store: store, root: root} do
    {:ok, _} = GovernanceExecutionJournal.transition(store, execution_binding(), "claim")
    [record] = Path.wildcard(Path.join(root, "execution-*.json"))
    File.write!(record, "{\"record\":{},\"sha256\":\"forged\"}")
    assert {:error, _} = GovernanceExecutionJournal.transition(store, execution_binding(), "read")
    File.write!(Path.join(root, ".pending"), "prepared transaction with unknown outcome")

    assert {:error, _} =
             GovernanceHostStore.request(store, %{
               "kind" => "observation",
               "id" => String.duplicate("a", 64),
               "command" => "create",
               "record" => %{}
             })
  end

  test "QA audit skips only old output directories that the sandbox fully overlays", %{root: root} do
    File.mkdir_p!(root <> "/elixir/_build/old")
    File.mkdir_p!(root <> "/elixir/lib")
    File.ln_s!("/outside-synthetic", root <> "/elixir/_build/old/dependency")
    assert {:error, _} = GovernanceWorkspaceProfile.build(root, "/pinned-vendor")
    assert {:ok, _} = GovernanceWorkspaceProfile.build_qa(root, "/pinned-vendor", [])
    File.ln_s!("/outside-synthetic", root <> "/elixir/lib/unsafe")
    assert {:error, _} = GovernanceWorkspaceProfile.build_qa(root, "/pinned-vendor", [])
    File.rm!(root <> "/elixir/lib/unsafe")
    File.rename!(root <> "/elixir/_build", root <> "/old-build")
    File.ln_s!(root <> "/old-build", root <> "/elixir/_build")
    assert {:error, _} = GovernanceWorkspaceProfile.build_qa(root, "/pinned-vendor", [])
  end

  test "pre-existing writable symlinks fail before native launch", %{root: root} do
    File.mkdir_p!(root <> "/elixir/lib")
    File.ln_s!("/outside-synthetic", root <> "/elixir/lib/alias")
    assert {:error, :governance_workspace_boundary_rejected} = GovernanceWorkspaceProfile.build(root, "/pinned-vendor")
  end

  test "observation writes are immutable, survive helper restart, and reject symlink parents", %{
    store: store,
    root: root
  } do
    operation = %{
      "kind" => "observation",
      "id" => String.duplicate("b", 64),
      "command" => "create",
      "record" => %{"probe" => "original"}
    }

    assert {:ok, %{"transitioned" => true}} = GovernanceHostStore.request(store, operation)

    assert {:ok, %{"transitioned" => false, "record" => %{"probe" => "original"}}} =
             GovernanceHostStore.request(store, operation)

    assert {:error, _} = GovernanceHostStore.request(store, put_in(operation, ["record", "probe"], "altered"))
    alias_path = root <> "-alias"
    File.ln_s!(root, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    assert {:error, _} = GovernanceHostStore.request(%{store | journal_root: alias_path}, operation)
    assert {:error, _} = GovernanceHostStore.request(%{store | python_sha256: String.duplicate("0", 64)}, operation)
  end

  test "profile enumerates deep secret and policy denials; hardlinks are rejected", %{root: root} do
    deep = Path.join([root | List.duplicate("nested", 12)])
    File.mkdir_p!(deep)
    File.write!(Path.join(deep, ".env.development"), "synthetic")
    File.write!(Path.join(root, "AGENTS.md"), "synthetic policy")
    File.ln_s!("/outside-synthetic", Path.join(root, "escape"))
    assert {:ok, profile} = GovernanceWorkspaceProfile.build(root, "/pinned-vendor")
    rules = get_in(profile, ["filesystem", ":workspace_roots"])
    assert rules[Path.relative_to(Path.join(deep, ".env.development"), root)] == "deny"
    assert rules["AGENTS.md"] == "read" and rules["docs/issues"] == "read" and rules["escape"] == "deny"
    File.ln!(Path.join(root, "AGENTS.md"), Path.join(root, "policy-alias"))
    assert {:error, _} = GovernanceWorkspaceProfile.build(root, "/pinned-vendor")
  end
end
