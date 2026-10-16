defmodule SymphonyElixir.GovernanceSourceGuardTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.GovernanceSourceGuard

  setup do
    root = Path.join(System.tmp_dir!(), "bos-source-guard-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.write!(root <> "/.writer.lock", "")
    File.chmod!(root <> "/.writer.lock", 0o600)

    on_exit(fn ->
      for path <- [root, root <> ".old"] do
        true = String.starts_with?(Path.expand(path), Path.expand(System.tmp_dir!()) <> "/bos-source-guard-")
        File.rm_rf!(path)
      end
    end)

    {text, 0} =
      System.cmd("/usr/bin/python3", [
        "-I",
        "-S",
        "-c",
        "import os,sys,json;d=os.stat(sys.argv[1]);s=os.stat(sys.argv[1]+'/.writer.lock');print(json.dumps(dict(directoryDev=d.st_dev,directoryIno=d.st_ino,lockDev=s.st_dev,lockIno=s.st_ino)))",
        root
      ])

    config = %{
      python_executable: "/usr/bin/python3",
      python_sha256: GovernanceBuildReceipt.file_digest("/usr/bin/python3"),
      source_guard_directory: root,
      source_guard_identity: Jason.decode!(text)
    }

    {:ok, root: root, config: config}
  end

  test "publisher holds the real permanent flock until the callback finishes", ctx do
    assert {:ok, :publication} =
             GovernanceSourceGuard.with_lock(ctx.config, fn ->
               {text, 0} =
                 System.cmd("/usr/bin/python3", [
                   "-I",
                   "-S",
                   "-c",
                   "import os,sys,fcntl;f=os.open(sys.argv[1]+'/.writer.lock',os.O_RDWR)\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);print('UNSAFE')\nexcept BlockingIOError: print('BUSY')",
                   ctx.root
                 ])

               assert String.trim(text) == "BUSY"
               {:ok, :publication}
             end)

    assert {:ok, :second} = GovernanceSourceGuard.with_lock(ctx.config, fn -> {:ok, :second} end)
  end

  test "configured directory replacement never obtains authority or confirms publication", ctx do
    owner = self()

    assert {:error, :governance_source_guard_unconfirmed} =
             GovernanceSourceGuard.with_lock(ctx.config, fn ->
               File.rename!(ctx.root, ctx.root <> ".old")
               File.mkdir!(ctx.root)
               File.chmod!(ctx.root, 0o700)
               File.write!(ctx.root <> "/.writer.lock", "")
               File.chmod!(ctx.root <> "/.writer.lock", 0o600)

               assert {:error, _} =
                        GovernanceSourceGuard.with_lock(ctx.config, fn ->
                          send(owner, :unapproved)
                          {:ok, :bad}
                        end)

               {:ok, :must_not_confirm}
             end)

    refute_received :unapproved
  end

  test "no missing configuration, forged identity, symlink or missing lock can run publisher", ctx do
    owner = self()

    action = fn ->
      send(owner, :unapproved)
      :ok
    end

    assert {:error, _} = GovernanceSourceGuard.with_lock(nil, action)

    assert {:error, _} =
             GovernanceSourceGuard.with_lock(put_in(ctx.config, [:source_guard_identity, "lockIno"], 0), action)

    File.rm!(ctx.root <> "/.writer.lock")
    assert {:error, _} = GovernanceSourceGuard.with_lock(ctx.config, action)
    refute File.exists?(ctx.root <> "/.writer.lock")
    File.ln_s!("/outside-synthetic", ctx.root <> "/.writer.lock")
    assert {:error, _} = GovernanceSourceGuard.with_lock(ctx.config, action)
    refute_received :unapproved
  end
end
