defmodule SymphonyElixir.GovernanceSourceGuard do
  @moduledoc "Host publisher uses the same provisioned permanent inode as the API, never while making HTTP requests."
  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.GovernanceProcess

  @spec with_lock(map() | nil, (-> result)) :: result | {:error, atom()} when result: var
  def with_lock(configuration, action) when is_map(configuration) and is_function(action, 0) do
    with python when is_binary(python) <- configuration[:python_executable],
         true <- GovernanceBuildReceipt.file_digest(python) == configuration[:python_sha256],
         root when is_binary(root) <- configuration[:source_guard_directory],
         identity when is_map(identity) <- configuration[:source_guard_identity] do
      env = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(python)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, ["-I", "-S", "-c", program()]},
          {:env, env}
        ])

      try do
        Port.command(port, Jason.encode!(%{root: root, identity: identity}) <> "\n")

        with :ok <- frame(port, "", 6_000),
             result <- action.(),
             true <- Port.command(port, "check\n"),
             :ok <- frame(port, "", 1_000) do
          result
        else
          _ -> {:error, :governance_source_guard_unconfirmed}
        end
      after
        GovernanceProcess.stop(port)
      end
    else
      _ -> {:error, :governance_source_guard_unconfigured}
    end
  rescue
    _ -> {:error, :governance_source_guard_unconfirmed}
  end

  def with_lock(_, _), do: {:error, :governance_source_guard_unconfigured}

  defp frame(port, bytes, timeout) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 4096 ->
        all = bytes <> chunk

        if String.ends_with?(all, "\n") do
          if Jason.decode(all) == {:ok, %{"held" => true}}, do: :ok, else: {:error, :invalid_guard}
        else
          frame(port, all, timeout)
        end

      {^port, _} ->
        {:error, :guard_lost}
    after
      timeout -> {:error, :guard_timeout}
    end
  end

  defp program do
    ~S"""
    import os,sys,json,stat,fcntl,time
    def require(ok):
        if not ok: raise ValueError('guard rejected')
    def directory(path):
        require(isinstance(path,str) and path.startswith('/') and '..' not in path.split('/'))
        d=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        try:
            parts=[p for p in path.split('/') if p]
            require(parts)
            for i,part in enumerate(parts):
                n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=d)
                s=os.fstat(n)
                sticky=(i==0 and part=='tmp' and s.st_uid==0 and s.st_mode&stat.S_ISVTX)
                require(s.st_uid in (0,os.geteuid()) and (not s.st_mode&0o022 or sticky))
                os.close(d);d=n
            s=os.fstat(d)
            require(s.st_uid==os.geteuid() and not s.st_mode&0o077)
            return d
        except BaseException:
            os.close(d);raise
    def main():
        request=json.loads(sys.stdin.buffer.readline(4097))
        root=request['root'];identity=request['identity']
        require(set(identity)=={'directoryDev','directoryIno','lockDev','lockIno'})
        require(all(type(v) is int and v>=0 for v in identity.values()))
        d=directory(root)
        try:
            lock=os.open('.writer.lock',os.O_RDWR|os.O_NOFOLLOW,dir_fd=d)
            try:
                def check():
                    current=directory(root)
                    try:
                        ds=os.fstat(d);now=os.fstat(current);s=os.fstat(lock)
                        named=os.stat('.writer.lock',dir_fd=current,follow_symlinks=False)
                        require((ds.st_dev,ds.st_ino)==(now.st_dev,now.st_ino)==(identity['directoryDev'],identity['directoryIno']))
                        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_mode&0o777==0o600)
                        require((s.st_dev,s.st_ino)==(named.st_dev,named.st_ino)==(identity['lockDev'],identity['lockIno']))
                    finally: os.close(current)
                check()
                deadline=time.monotonic()+5
                while True:
                    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                    except BlockingIOError:
                        require(time.monotonic()<deadline);time.sleep(0.02);check()
                check()
                print('{"held":true}',flush=True)
                for line in sys.stdin:
                    require(line.strip()=='check');check()
                    print('{"held":true}',flush=True)
            finally: os.close(lock)
        finally: os.close(d)
    try: main()
    except BaseException: print('{"held":false}',flush=True);sys.exit(1)
    """
  end
end
