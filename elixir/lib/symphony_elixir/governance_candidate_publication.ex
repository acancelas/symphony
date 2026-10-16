defmodule SymphonyElixir.GovernanceCandidatePublication do
  alias SymphonyElixir.Audit.CanonicalJson
  @moduledoc "Host-only staged tree confirmation; the worker cannot change Git administration or the plan."
  @doc "Read bounded targets from the exact approved hashed plan; this grants no write or launch authority."
  @spec proposal_paths(map(), map()) :: {:ok, [String.t()]} | {:error, atom()}
  def proposal_paths(context, source) do
    with {:ok, authority} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, source),
         baseline = authority["baselineCommitSha"],
         true <- is_binary(baseline) and Regex.match?(~r/^[a-f0-9]{40}$/, baseline),
         number = context.issue.native_ref["issueNumber"],
         true <- is_integer(number) and number > 0,
         plan_path = "docs/issues/#{number}/plan.md",
         {mode, 0} <- git(context, ["ls-tree", baseline, "--", plan_path]),
         true <- String.starts_with?(mode, "100644 blob "),
         {plan, 0} <- git(context, ["show", baseline <> ":" <> plan_path]),
         true <- byte_size(plan) <= 262_144,
         true <- context.manifest["planHash"] == "sha256:" <> digest(plan),
         [[_, json]] <- Regex.scan(~r/^```bos-implementation-files\n([^\n]+)\n```$/m, plan),
         {:ok, %{"version" => 1, "files" => paths} = inventory} <- Jason.decode(json),
         true <- Enum.sort(Map.keys(inventory)) == ~w(files version),
         true <- IO.iodata_to_binary(CanonicalJson.encode(inventory)) == json,
         true <- is_list(paths) and length(paths) in 1..100,
         true <- length(Enum.uniq(paths)) == length(paths),
         true <- Enum.all?(paths, &proposal_path?/1) do
      {:ok, paths}
    else
      _ -> {:error, :governance_approved_proposal_paths_unverified}
    end
  rescue
    _ -> {:error, :governance_approved_proposal_paths_unverified}
  end

  defp proposal_path?(path) when is_binary(path) do
    byte_size(path) <= 1024 and String.valid?(path) and
      not Regex.match?(~r/[\x00-\x1f\x7f\\]/, path) and
      Enum.join(Path.split(path), "/") == path and permitted?(path)
  end

  defp proposal_path?(_), do: false
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc "Validate the whole structured proposal without writing files or consuming a launch."
  @spec validate_proposal(map(), map(), map()) :: {:ok, [map()]} | {:error, atom()}
  def validate_proposal(context, source, proposal) when is_map(proposal) do
    with {:ok, allowed} <- proposal_paths(context, source),
         true <- Enum.sort(Map.keys(proposal)) == ~w(candidateCommitSha changes planHash),
         true <- proposal["candidateCommitSha"] == context.sha and proposal["planHash"] == context.manifest["planHash"],
         changes when is_list(changes) <- proposal["changes"],
         true <- length(changes) in 1..100,
         true <- Enum.all?(changes, &valid_proposal_change?(context, &1, allowed)),
         true <- length(Enum.uniq_by(changes, & &1["path"])) == length(changes),
         true <- Enum.sum(Enum.map(changes, &byte_size(&1["content"]))) <= 1_048_576,
         {"", 0} <- git(context, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, changes}
    else
      _ -> {:error, :governance_structured_proposal_rejected}
    end
  rescue
    _ -> {:error, :governance_structured_proposal_rejected}
  end

  def validate_proposal(_, _, _), do: {:error, :governance_structured_proposal_rejected}

  defp valid_proposal_change?(context, change, allowed) when is_map(change) do
    path = change["path"]
    content = change["content"]

    Enum.sort(Map.keys(change)) == ~w(content expectedBlobSha path) and path in allowed and
      is_binary(content) and byte_size(content) <= 262_144 and String.valid?(content) and
      not String.contains?(content, <<0>>) and regular_change?(context.workspace, path) and
      proposal_blob_matches?(context, path, change["expectedBlobSha"])
  end

  defp valid_proposal_change?(_, _, _), do: false

  defp proposal_blob_matches?(context, path, expected) do
    case git(context, ["ls-tree", "-z", context.sha, "--", path]) do
      {"", 0} ->
        is_nil(expected)

      {entry, 0} ->
        case String.split(entry, [" ", "\t"], parts: 4) do
          [mode, "blob", sha, _] -> mode in ~w(100644 100755) and sha == expected
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "Host-only single-use application after verified worker retirement; never a model tool."
  @spec apply_proposal(map(), map(), map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def apply_proposal(context, source, proposal, execution, admission) do
    with true <- context[:phase] == "implementation",
         {:ok, _} <- SymphonyElixir.GovernanceExecutionAuthority.check(context, source, admission),
         binding = SymphonyElixir.GovernanceExecutionJournal.binding(context, admission),
         :ok <- retired_worker(execution, binding) do
      SymphonyElixir.GovernanceSourceGuard.with_lock(execution, fn ->
        apply_locked_proposal(context, source, proposal, execution, binding, admission)
      end)
    else
      _ -> {:error, :governance_proposal_worker_or_authority_unverified}
    end
  rescue
    _ -> {:error, :governance_proposal_application_unavailable}
  end

  defp retired_worker(execution, binding) do
    with {:ok, %{"record" => %{"state" => "COMPLETED", "witness" => %{"pid" => pid, "bootId" => boot_id}}}} <-
           SymphonyElixir.GovernanceExecutionJournal.transition(execution, binding, "read"),
         true <- is_integer(pid) and pid > 1,
         {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- String.trim(boot) == boot_id,
         {:error, :enoent} <- File.lstat("/proc/#{pid}") do
      :ok
    else
      _ -> {:error, :governance_proposal_worker_not_retired}
    end
  end

  defp apply_locked_proposal(context, source, proposal, execution, binding, admission) do
    with :ok <- retired_worker(execution, binding),
         {:ok, %{type: :directory} = root} <- File.lstat(context.workspace),
         {:ok, changes} <- validate_proposal(context, source, proposal),
         {:ok, deadline} <- proposal_deadline(source, admission),
         id = digest("structured-proposal:" <> SymphonyElixir.GovernanceExecutionJournal.identity(binding)),
         intent = proposal_intent(context, proposal, binding),
         {:ok, %{"transitioned" => true}} <- proposal_observation(execution, id, intent) do
      result = fixed_proposal_writer(execution, context.workspace, changes, root, deadline)
      finish_proposal_application(execution, id, intent, result)
    else
      _ -> {:error, :governance_proposal_rejected_or_already_consumed}
    end
  end

  defp proposal_deadline(source, admission) do
    values = [admission["deadline"], get_in(source, ["claim", "leaseExpiresAt"])]

    with [{:ok, deadline, _}, {:ok, lease, _}] <- Enum.map(values, &DateTime.from_iso8601/1),
         {:ok, observed, _} <- DateTime.from_iso8601(get_in(source, ["governance", "developmentExecution", "lastObservedAt"])) do
      minimum = [deadline, lease, DateTime.add(observed, 30, :second)] |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
      {:ok, DateTime.to_iso8601(minimum)}
    else
      _ -> {:error, :governance_proposal_deadline_unverified}
    end
  end

  defp proposal_intent(context, proposal, binding) do
    %{
      "kind" => "structured_source_application",
      "state" => "PREPARED",
      "candidateCommitSha" => context.sha,
      "planHash" => context.manifest["planHash"],
      "proposalDigest" => digest(CanonicalJson.encode(proposal)),
      "executionJournalId" => SymphonyElixir.GovernanceExecutionJournal.identity(binding)
    }
  end

  defp proposal_observation(execution, id, record),
    do:
      SymphonyElixir.GovernanceHostStore.request(
        execution,
        %{"kind" => "observation", "command" => "create", "id" => id, "record" => record}
      )

  defp finish_proposal_application(execution, id, intent, result) do
    state = if match?({:ok, _}, result), do: "APPLIED", else: "INDETERMINATE"
    outcome = Map.merge(intent, %{"state" => state, "preparedObservationId" => id})

    with {:ok, %{"transitioned" => true}} <- proposal_observation(execution, digest(id <> ":outcome"), outcome),
         {:ok, receipt} <- result do
      {:ok, Map.merge(receipt, %{"preparedObservationId" => id, "outcome" => state})}
    else
      _ -> {:error, :governance_proposal_application_indeterminate}
    end
  end

  defp fixed_proposal_writer(execution, workspace, changes, root, deadline) do
    cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(execution.python_executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-I", "-S", "-c", proposal_writer()]},
          {:env, cleared}
        ]
      )

    try do
      true = Port.command(port, Jason.encode!(%{workspace: workspace, changes: changes, rootDevice: root.major_device, rootInode: root.inode, deadline: deadline}) <> "\n")

      with {:ok, receipt} <- proposal_writer_result(port, "", System.monotonic_time(:millisecond) + 10_000),
           {:ok, current} <- File.lstat(workspace),
           true <- current.inode == root.inode and current.major_device == root.major_device,
           true <- Enum.sort(Map.keys(receipt)) == ~w(files ok) and receipt["files"] == length(changes) do
        {:ok, receipt}
      else
        _ -> {:error, :governance_proposal_writer_unconfirmed}
      end
    after
      SymphonyElixir.GovernanceProcess.stop(port)
    end
  rescue
    _ -> {:error, :governance_proposal_writer_unavailable}
  end

  defp proposal_writer_result(port, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(bytes) + byte_size(chunk) <= 8192 ->
        proposal_writer_result(port, bytes <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        case Jason.decode(bytes) do
          {:ok, %{"ok" => true} = receipt} -> {:ok, receipt}
          _ -> {:error, :governance_proposal_writer_unconfirmed}
        end

      {^port, _} ->
        {:error, :governance_proposal_writer_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :governance_proposal_writer_timeout}
    end
  end

  defp proposal_writer do
    ~S"""
    import os,sys,json,stat,hashlib,secrets,datetime
    def require(value):
        if not value: raise ValueError('source application rejected')
    def directory(path):
        require(type(path) is str and path.startswith('/') and '..' not in path.split('/'))
        fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        try:
            for i,part in enumerate(p for p in path.split('/') if p):
                nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                meta=os.fstat(nxt)
                sticky=i==0 and part=='tmp' and meta.st_uid==0 and meta.st_mode&stat.S_ISVTX
                require(meta.st_uid in (0,os.geteuid()) and (not meta.st_mode&0o022 or sticky))
                os.close(fd);fd=nxt
            return fd
        except BaseException:
            os.close(fd);raise
    def current(parent,leaf,expected):
        try: fd=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        except FileNotFoundError:
            require(expected is None);return None
        try:
            meta=os.fstat(fd)
            require(stat.S_ISREG(meta.st_mode) and meta.st_nlink==1 and meta.st_uid==os.geteuid())
            require(not meta.st_mode&0o7022)
            data=os.read(fd,262145);require(len(data)<=262144)
            actual=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
            require(actual==expected)
            return (meta.st_dev,meta.st_ino,stat.S_IMODE(meta.st_mode))
        finally: os.close(fd)
    def main():
        request=json.loads(sys.stdin.buffer.readline(8388609))
        changes=request['changes'];require(type(changes) is list and 0<len(changes)<=100)
        root=directory(request['workspace']);prepared=[]
        rootmeta=os.fstat(root);require((rootmeta.st_dev,rootmeta.st_ino)==(request['rootDevice'],request['rootInode']))
        deadline=datetime.datetime.fromisoformat(request['deadline'].replace('Z','+00:00'))
        def live(): require(datetime.datetime.now(datetime.timezone.utc)<deadline)
        live()
        try:
            for change in changes:
                path=change['path'];parts=path.split('/')
                require(parts[:2] in (['elixir','lib'],['elixir','test']))
                require(all(p and not p.startswith('.') and p not in ('AGENTS.md','AGENTS.override.md','WORKFLOW.md','GOVERNANCE.md','auth.json','credentials.json','secrets.json') for p in parts))
                parent=os.dup(root)
                try:
                    for part in parts[:-1]:
                        nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
                        meta=os.fstat(nxt);require(meta.st_uid==os.geteuid() and not meta.st_mode&0o022)
                        os.close(parent);parent=nxt
                    data=change['content'].encode('utf-8');require(len(data)<=262144 and b'\0' not in data)
                    before=current(parent,parts[-1],change['expectedBlobSha'])
                    prepared.append(dict(path=path,parent=parent,leaf=parts[-1],expected=change['expectedBlobSha'],before=before,data=data,temp=None))
                    parent=None
                finally:
                    if parent is not None: os.close(parent)
            require(sum(len(item['data']) for item in prepared)<=1048576)
            # Every path/content/identity is validated before preparing any source file.
            for item in prepared:
                live()
                item['temp']='.bos-cas-'+secrets.token_hex(16)
                fd=os.open(item['temp'],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=item['parent'])
                try:
                    data=memoryview(item['data'])
                    while data:
                        count=os.write(fd,data);require(count>0);data=data[count:]
                    os.fchmod(fd,item['before'][2] if item['before'] else 0o644)
                    os.fsync(fd)
                finally: os.close(fd)
            for item in prepared:
                require(current(item['parent'],item['leaf'],item['expected'])==item['before'])
            for item in prepared:
                require(current(item['parent'],item['leaf'],item['expected'])==item['before'])
                live()
                os.replace(item['temp'],item['leaf'],src_dir_fd=item['parent'],dst_dir_fd=item['parent'])
                item['temp']=None;os.fsync(item['parent'])
            os.fsync(root)
            # Confirm named-path effects, not merely success on a detached directory descriptor.
            for item in prepared:
                named=os.dup(root)
                try:
                    for part in item['path'].split('/')[:-1]:
                        nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=named)
                        os.close(named);named=nxt
                    actual=os.fstat(named);held=os.fstat(item['parent'])
                    require((actual.st_dev,actual.st_ino)==(held.st_dev,held.st_ino))
                    data=item['data']
                    expected=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
                    require(current(named,item['leaf'],expected) is not None)
                finally: os.close(named)
            live()
            print(json.dumps(dict(ok=True,files=len(prepared))))
        finally:
            for item in prepared:
                if item['temp']:
                    try: os.unlink(item['temp'],dir_fd=item['parent'])
                    except FileNotFoundError: pass
                os.close(item['parent'])
            os.close(root)
    try: main()
    except BaseException: print('{"ok":false}');sys.exit(1)
    """
  end

  @spec stage(map()) :: {:ok, String.t()} | {:error, atom()}
  def stage(context) do
    with {text, 0} <- git(context, ["diff", "--name-only", "-z", "HEAD"]),
         {untracked, 0} <- git(context, ["ls-files", "--others", "--exclude-standard", "-z"]),
         paths = String.split(text <> untracked, <<0>>, trim: true) |> Enum.uniq(),
         true <- Enum.all?(paths, &(permitted?(&1) and regular_change?(context.workspace, &1))),
         {original_modes, 0} <-
           if(paths == [], do: {"", 0}, else: git(context, ["ls-tree", "-z", "HEAD", "--" | paths])),
         true <- regular_modes?(original_modes),
         {_, 0} <- if(paths == [], do: {"", 0}, else: git(context, ["add", "--" | paths])),
         {staged_modes, 0} <-
           if(paths == [], do: {"", 0}, else: git(context, ["ls-files", "--stage", "-z", "--" | paths])),
         true <- regular_modes?(staged_modes),
         {tree, 0} <- git(context, ["write-tree"]) do
      {:ok, String.trim(tree)}
    else
      _ -> {:error, :governance_candidate_scope_rejected}
    end
  end

  @spec unchanged(map(), String.t()) :: :ok | {:error, atom()}
  def unchanged(context, tree) do
    with {"", 0} <- git(context, ["diff", "--name-only"]),
         {"", 0} <- git(context, ["ls-files", "--others", "--exclude-standard"]),
         {current, 0} <- git(context, ["write-tree"]),
         true <- String.trim(current) == tree,
         {head, 0} <- git(context, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == context.sha do
      :ok
    else
      _ -> {:error, :governance_candidate_changed_during_qa}
    end
  end

  @spec publish(map(), String.t(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def publish(context, tree, execution) do
    SymphonyElixir.GovernanceSourceGuard.with_lock(execution, fn -> do_publish(context, tree) end)
  end

  defp do_publish(context, tree) do
    with :ok <- unchanged(context, tree),
         {current_tree, 0} <- git(context, ["rev-parse", "HEAD^{tree}"]),
         {_, 0} <-
           if(String.trim(current_tree) == tree,
             do: {"", 0},
             else: git(context, ["commit", "-m", "Implement governed Issue #{context.issue.native_ref["issueNumber"]}"])
           ),
         {:ok, candidate} <-
           SymphonyElixir.GovernanceCandidateHead.confirm(context.workspace, context.issue, context[:worker_host]),
         {published_tree, 0} <- git(context, ["rev-parse", candidate.head_sha <> "^{tree}"]),
         true <- String.trim(published_tree) == tree do
      {:ok, candidate}
    else
      _ -> {:error, :governance_candidate_publication_unconfirmed}
    end
  end

  defp regular_change?(root, path) do
    full = Path.join(root, path)

    case File.lstat(full) do
      {:ok, %{type: :regular, links: 1}} ->
        SymphonyElixir.PathSafety.canonicalize(full) == {:ok, full}

      {:error, :enoent} ->
        SymphonyElixir.PathSafety.canonicalize(Path.dirname(full)) == {:ok, Path.dirname(full)}

      _ ->
        false
    end
  end

  defp regular_modes?(text) do
    text
    |> String.split(<<0>>, trim: true)
    |> Enum.all?(fn entry ->
      case String.split(entry, " ", parts: 2) do
        [mode, _] -> mode in ["100644", "100755"]
        _ -> false
      end
    end)
  end

  defp permitted?(path) do
    String.starts_with?(path, ["elixir/lib/", "elixir/test/"]) and
      Enum.all?(
        Path.split(path),
        &(not String.starts_with?(&1, ".") and
            &1 not in ~w(AGENTS.md AGENTS.override.md WORKFLOW.md GOVERNANCE.md auth.json credentials.json secrets.json))
      )
  end

  defp git(context, args), do: SymphonyElixir.GovernanceTrustedGit.run(context.workspace, args)
end
