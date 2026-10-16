defmodule SymphonyElixir.GovernanceThreadPreflightTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Codex.AppServer

  setup do
    root = Path.join(System.tmp_dir!(), "bos-thread-preflight-#{System.unique_integer([:positive])}")
    File.mkdir!(root)

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-thread-preflight-")
      File.rm_rf!(root)
    end)

    script = ~S"""
    import sys,json
    for line in sys.stdin:
        msg=json.loads(line)
        if 'id' not in msg: continue
        result={}
        if msg['method']=='thread/start':
            result={'thread':{'id':'actual-native-thread'},'activePermissionProfile':{'id':'bos-review'},'sandbox':{'type':'read-only'},'cwd':msg['params']['cwd'],'approvalPolicy':'never'}
        print(json.dumps({'id':msg['id'],'result':result}),flush=True)
    """

    managed = %{
      executable: "/usr/bin/python3",
      arguments: ["-I", "-S", "-u", "-c", script],
      environment: %{},
      permissions: "bos-review",
      allowed_workspace_roots: [root]
    }

    {:ok, root: root, managed: managed}
  end

  defp options(ctx, callback) do
    owner = self()

    [
      managed_launch: ctx.managed,
      dynamic_tool_binding: %{tool_specs: [], secret_environment_names: []},
      host_preflight: fn port ->
        {:os_pid, pid} = Port.info(port, :os_pid)
        send(owner, {:actual_pid, pid})
        :ok
      end,
      host_thread_preflight: callback
    ]
  end

  test "host observes the actual selected profile and effective sandbox before session is returned", ctx do
    owner = self()

    callback = fn _port, response ->
      send(owner, {:actual_response, response})
      :ok
    end

    assert {:ok, session} = AppServer.start_session(ctx.root, options(ctx, callback))

    assert_receive {:actual_response,
                    %{
                      "activePermissionProfile" => %{"id" => "bos-review"},
                      "sandbox" => %{"type" => "read-only"},
                      "thread" => %{"id" => "actual-native-thread"}
                    }}

    assert_receive {:actual_pid, pid}
    AppServer.stop_session(session)
    refute File.exists?("/proc/#{pid}")
  end

  test "denied, malformed and failing host inspection reaps the process without returning capabilities", ctx do
    callbacks = [
      fn _, _ -> {:error, :effective_profile_mismatch} end,
      fn _, _ -> false end,
      fn _, _ -> raise "inspection failed" end
    ]

    for callback <- callbacks do
      assert {:error, _} = AppServer.start_session(ctx.root, options(ctx, callback))
      assert_receive {:actual_pid, pid}
      refute File.exists?("/proc/#{pid}")
    end
  end
end
