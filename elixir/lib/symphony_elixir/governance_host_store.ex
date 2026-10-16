defmodule SymphonyElixir.GovernanceHostStore do
  @moduledoc "Host-only, anchored and fsynced storage. No model tool exposes this interface."
  alias SymphonyElixir.GovernanceBuildReceipt
  @timeout 10_000

  def request(configuration, operation) when is_map(configuration) and is_map(operation) do
    with true <- GovernanceBuildReceipt.file_digest(configuration.python_executable) == configuration.python_sha256,
         true <- Path.type(configuration.journal_root) == :absolute do
      cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(configuration.python_executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-I", "-S", "-c", program()]},
          {:env, cleared ++ [{~c"LANG", ~c"C.UTF-8"}]}
        ])

      Port.command(port, Jason.encode!(Map.put(operation, "root", configuration.journal_root)) <> "\n")
      receive_result(port, "")
    else
      _ -> {:error, :governance_host_store_pin_rejected}
    end
  rescue
    _ -> {:error, :governance_host_store_unavailable}
  end

  def request(_, _), do: {:error, :governance_host_store_unconfigured}

  def hold(configuration, id) do
    with true <- GovernanceBuildReceipt.file_digest(configuration.python_executable) == configuration.python_sha256 do
      cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(configuration.python_executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-I", "-S", "-c", program()]},
          {:env, cleared ++ [{~c"LANG", ~c"C.UTF-8"}]}
        ])

      Port.command(port, Jason.encode!(%{"root" => configuration.journal_root, "kind" => "execution", "id" => id, "command" => "hold"}) <> "\n")

      case frame(port, "") do
        {:ok, %{"ok" => true, "held" => true}} ->
          {:ok, port}

        _ ->
          SymphonyElixir.GovernanceProcess.stop(port)
          {:error, :governance_launch_owner_busy}
      end
    else
      _ -> {:error, :governance_host_store_pin_rejected}
    end
  rescue
    _ -> {:error, :governance_launch_owner_unavailable}
  end

  # The immutable helper acquires flock before its first acknowledgement and
  # never unlocks while alive. Do not consume its owner's mailbox from a monitor.
  def held?(port) when is_port(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), {:ok, bytes} <- File.read("/proc/#{pid}/stat"), [_name, tail] <- String.split(bytes, ") ", parts: 2) do
      List.first(String.split(tail)) not in ["Z", "X"]
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def held?(_), do: false
  def release(port), do: SymphonyElixir.GovernanceProcess.stop(port)

  defp frame(port, bytes) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 4096 ->
        all = bytes <> chunk
        if String.ends_with?(all, "\n"), do: Jason.decode(String.trim(all)), else: frame(port, all)

      {^port, _} ->
        {:error, :governance_launch_owner_lost}
    after
      1_000 -> {:error, :governance_launch_owner_timeout}
    end
  end

  defp receive_result(port, bytes) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 262_144 ->
        receive_result(port, bytes <> chunk)

      {^port, {:exit_status, 0}} ->
        case Jason.decode(bytes) do
          {:ok, %{"ok" => true} = result} -> {:ok, result}
          _ -> {:error, :governance_host_store_rejected}
        end

      {^port, {:exit_status, _}} ->
        {:error, :governance_host_store_rejected}

      {^port, _} ->
        SymphonyElixir.GovernanceProcess.stop(port)
        {:error, :governance_host_store_rejected}
    after
      @timeout ->
        SymphonyElixir.GovernanceProcess.stop(port)
        {:error, :governance_host_store_timeout}
    end
  end

  # Fixed host code, not a repository script or model-supplied command. Python
  # isolated mode imports only stdlib. The trusted executable is separately pinned.
  defp program do
    ~S"""
    import os, sys, json, stat, hashlib, fcntl, re, secrets

    def canonical(value):
        return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()
    def digest(value):
        return hashlib.sha256(canonical(value)).hexdigest()
    def require(ok):
        if not ok: raise ValueError('rejected')
    def secure_file(fd):
        s=os.fstat(fd)
        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_mode&0o077==0 and s.st_nlink==1)
    def read_file(root,name):
        try: fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=root)
        except FileNotFoundError: return None
        try:
            secure_file(fd)
            with os.fdopen(fd,'rb',closefd=False) as f: raw=f.read(262145)
            require(len(raw)<=262144)
            envelope=json.loads(raw)
            require(set(envelope)=={'record','sha256'} and envelope['sha256']==digest(envelope['record']))
            return envelope['record']
        finally: os.close(fd)
    def atomic(root,name,record):
        # A failed directory sync after replacement is indeterminate: leave a durable
        # marker and deny ALL subsequent writes. Never roll old RAM over new disk.
        intent=os.open('.pending',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=root)
        os.write(intent,b'prepared host transaction');os.fsync(intent);os.close(intent);os.fsync(root)
        temp='.tmp-'+secrets.token_hex(16)
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=root)
        try:
            data=canonical({'record':record,'sha256':digest(record)})
            with os.fdopen(fd,'wb',closefd=False) as f: f.write(data); f.flush(); os.fsync(fd)
            os.replace(temp,name,src_dir_fd=root,dst_dir_fd=root)
            try:
                os.fsync(root)
                os.unlink('.pending',dir_fd=root);os.fsync(root)
            except BaseException:
                marker=os.open('.INDETERMINATE',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=root)
                os.write(marker,b'host store requires offline reconciliation');os.fsync(marker);os.close(marker)
                raise
        finally:
            os.close(fd)
            try: os.unlink(temp,dir_fd=root)
            except FileNotFoundError: pass

    def main():
        request=json.loads(sys.stdin.buffer.readline(262145))
        root=request.pop('root');require(isinstance(root,str) and root.startswith('/') and '..' not in root.split('/'))
        d=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        try:
            parts=[p for p in root.split('/') if p]
            for i,part in enumerate(parts):
                try: n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=d)
                except FileNotFoundError:
                    require(i==len(parts)-1)
                    os.mkdir(part,0o700,dir_fd=d);os.fsync(d)
                    n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=d)
                s=os.fstat(n)
                sticky_tmp=(i==0 and part=="tmp" and s.st_uid==0 and s.st_mode&stat.S_ISVTX!=0)
                require(s.st_uid in (0,os.geteuid()) and (s.st_mode&0o022==0 or sticky_tmp))
                os.close(d);d=n
            require(os.fstat(d).st_uid==os.geteuid() and os.fstat(d).st_mode&0o077==0)
            if request.get('command')=='hold':
                require(request.get('kind')=='execution' and re.fullmatch('[a-f0-9]{64}',request.get('id','')))
                owner=os.open('execution-'+request['id']+'.owner.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=d);secure_file(owner)
                fcntl.flock(owner,fcntl.LOCK_EX|fcntl.LOCK_NB)
                try:
                    print('{"ok":true,"held":true}',flush=True)
                    for line in sys.stdin:
                        require(line.strip()=='ping')
                        print('{"ok":true,"held":true}',flush=True)
                finally: os.close(owner)
                return
            lock=os.open('.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=d);secure_file(lock)
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            try:
                for marker in ('.INDETERMINATE','.pending'):
                    try: os.stat(marker,dir_fd=d,follow_symlinks=False);raise ValueError('indeterminate')
                    except FileNotFoundError: pass
                kind=request['kind']; require(kind in ('execution','observation'))
                identity=request['id'];require(isinstance(identity,str) and re.fullmatch('[a-f0-9]{64}',identity))
                name=kind+'-'+identity+'.json'
                old=read_file(d,name)
                command=request['command'];changed=False
                if kind=='observation':
                    require(command in ('create','read'))
                    if command=='create':
                        value=request['record'];require(isinstance(value,dict))
                        require(old is None or old==value)
                        if old is None: atomic(d,name,value);old=value;changed=True
                else:
                    binding=request['binding'];require(isinstance(binding,dict) and set(binding)=={'repositoryId','issueNumber','runId','attemptId','reservationId','hostInvocationId','workerId','authorityGeneration'})
                    require(all(isinstance(v,str) and re.fullmatch('[A-Za-z0-9_.:-]{1,200}',v) for k,v in binding.items() if k not in ('issueNumber','authorityGeneration')))
                    require(type(binding['issueNumber']) is int and binding['issueNumber']>0 and type(binding['authorityGeneration']) is int and binding['authorityGeneration']>0)
                    require(old is None or old['binding']==binding)
                    require(command in ('claim','read','spawn_intent','attach','finish','fence'))
                    if old is None:
                        require(command=='claim')
                        old={'binding':binding,'state':'CLAIMED','witness':None};atomic(d,name,old);changed=True
                    elif command=='spawn_intent' and old['state']=='CLAIMED':
                        old={**old,'state':'SPAWN_INTENT'};atomic(d,name,old);changed=True
                    elif command=='attach':
                        require(old['state']=='SPAWN_INTENT')
                        witness=request['witness'];require(set(witness)=={'pid','startTicks','bootId','marker'})
                        pid=witness['pid'];require(type(pid) is int and pid>1)
                        require(os.stat('/proc/'+str(pid)).st_uid==os.geteuid())
                        with open('/proc/'+str(pid)+'/stat') as f: ticks=f.read().rsplit(') ',1)[1].split()[19]
                        with open('/proc/sys/kernel/random/boot_id') as f: boot=f.read().strip()
                        with open('/proc/'+str(pid)+'/environ','rb') as f: environment=f.read(262144).split(b'\0')
                        require(ticks==witness['startTicks'] and boot==witness['bootId'] and ('BOS_HOST_WORKER_MARKER='+witness['marker']).encode() in environment)
                        old={**old,'state':'ATTACHED','witness':witness};atomic(d,name,old);changed=True
                    elif command=='finish':
                        require(old['state']=='ATTACHED')
                        # PID reuse is deliberately conservative: never turn absence
                        # of the original worker into authority to launch another.
                        require(not os.path.exists('/proc/'+str(old['witness']['pid'])))
                        old={**old,'state':'COMPLETED'};atomic(d,name,old);changed=True
                    elif command=='fence':
                        old={**old,'state':'FENCED'};atomic(d,name,old);changed=True
                print(json.dumps({'ok':True,'record':old,'recordDigest':digest(old),'transitioned':changed},separators=(',',':')))
            finally: os.close(lock)
        finally: os.close(d)
    try: main()
    except BaseException: print('{"ok":false}');sys.exit(1)
    """
  end
end
