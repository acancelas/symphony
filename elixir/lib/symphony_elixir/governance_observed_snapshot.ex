defmodule SymphonyElixir.GovernanceObservedSnapshot do
  @moduledoc "Host-only DEV projection of original MCP text; never a source of authority."
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.{GovernanceBuildReceipt, GovernanceHostStore, GovernanceProcess, GovernanceReservation}
  @run "symphony-governance-69"
  @scope %{"repositoryId" => "symphony", "owner" => "acancelas", "repo" => "symphony", "issueNumber" => 69, "runId" => @run}
  @max_bytes 262_144

  @doc "Load the existing Front-generated allowlist by exact host-configured byte pin."
  @spec load_contract(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def load_contract(path, expected) do
    with {:ok, bytes} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected,
         {:ok, %{"$defs" => %{"payload" => schema}}} <- Jason.decode(bytes) do
      {:ok, schema}
    else
      _ -> {:error, :snapshot_contract_unverified}
    end
  rescue
    _ -> {:error, :snapshot_contract_unverified}
  end

  @doc "Collect only existing fixed read operations. Callback belongs to the trusted host, never a model tool."
  @spec collect((String.t(), map() -> {:ok, map()} | {:error, term()})) :: {:ok, map(), DateTime.t()} | {:error, atom()}
  def collect(fetch) when is_function(fetch, 2) do
    read_at = DateTime.utc_now()

    with {:ok, issue} <- fetch.("bos_get_issue", %{"issueNumber" => 69}),
         {:ok, run} <- fetch.("bos_get_delivery_run", %{"runId" => @run}),
         {:ok, timeline} <- fetch.("bos_get_run_history", %{"runId" => @run}),
         {:ok, texts} <- original_texts(%{"issue" => issue, "run" => run, "timeline" => timeline}) do
      {:ok, texts, read_at}
    else
      _ -> {:error, :snapshot_read_unavailable}
    end
  rescue
    _ -> {:error, :snapshot_read_unavailable}
  end

  @doc "Build from authentic raw reads and a pinned projection schema. Unknown metrics remain absent/null."
  @spec build(map(), map(), map(), map(), DateTime.t(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def build(context, texts, provenance, schema, read_at, now) do
    with true <- Map.take(context.issue.native_ref, ~w(repositoryId issueNumber runId)) == Map.take(@scope, ~w(repositoryId issueNumber runId)),
         true <- sha?(context.sha) and sha?(provenance["backendCommitSha"]),
         true <- provenance["origin"] == "http://127.0.0.1:8110" and provenance["providerKind"] == "synthetic",
         true <- identifier?(provenance["epoch"]) and not Map.has_key?(provenance, "hostObservationId"),
         true <- is_nil(provenance["receiptId"]) or identifier?(provenance["receiptId"]),
         true <- Enum.sort(Map.keys(texts)) == ~w(issue run timeline),
         true <- Enum.all?(Map.values(texts), &(is_binary(&1) and byte_size(&1) <= 1_048_576)),
         {:ok, issue} <- Jason.decode(texts["issue"]),
         {:ok, run} <- Jason.decode(texts["run"]),
         {:ok, timeline} <- Jason.decode(texts["timeline"]),
         true <- get_in(issue, ["governanceIdentity", "verified"]) == true,
         true <- get_in(issue, ["governanceIdentity", "authenticatedBy"]) == "bos-host-hmac-v2",
         true <- get_in(issue, ["governance", "developmentExecution", "epoch"]) == provenance["epoch"],
         :ok <- GovernanceReservation.verify(context, run, issue, now),
         true <- run["headCommit"] == context.sha and timeline["runId"] == @run,
         true <- is_list(timeline["events"]) and is_boolean(get_in(timeline, ["verification", "valid"])),
         true <- valid_timeline?(timeline),
         true <- digest?(issue["definitionDigest"]),
         {:ok, lease, _} <- DateTime.from_iso8601(issue["claim"]["leaseExpiresAt"]),
         true <- DateTime.compare(read_at, now) != :gt and DateTime.diff(now, read_at, :millisecond) < 60_000,
         expires <- earlier(DateTime.add(read_at, 60, :second), lease),
         true <- DateTime.compare(expires, now) == :gt,
         {:ok, recovery} <- recovery_metadata(provenance, issue),
         {:ok, payload} <- project(%{"issue" => issue, "run" => run, "timeline" => timeline}, schema, 0),
         true <- nested_scope?(payload),
         true <- is_nil(get_in(payload, ["run", "auditChain", "scopeId"])) or get_in(payload, ["run", "auditChain", "scopeId"]) == @run,
         true <- active_candidate?(payload["issue"], context.sha),
         payload_json <- Jason.encode!(payload) do
      source = %{
        "origin" => provenance["origin"],
        "providerKind" => "synthetic",
        "canonicalFulfillment" => false,
        "backendCommitSha" => provenance["backendCommitSha"],
        "receiptId" => provenance["receiptId"],
        "reservationKind" => "governed_run_lease",
        "reservationId" => @run,
        "reservationConfirmedByHost" => true,
        "leaseExpiresAt" => utc(lease),
        "originalResponseFormat" => "bos_mcp_text_utf8",
        "originalResponseDigests" => Map.new(texts, fn {key, bytes} -> {key, digest(bytes)} end)
      }

      source = Map.merge(source, recovery)

      envelope = %{
        "schemaVersion" => 1,
        "mode" => "observed_snapshot",
        "scope" => @scope,
        "source" => source,
        "epoch" => provenance["epoch"],
        "candidateCommitSha" => context.sha,
        "readAt" => utc(read_at),
        "issuedAt" => utc(now),
        "expiresAt" => utc(expires),
        "payloadJson" => payload_json,
        "payloadDigest" => digest(payload_json)
      }

      observation_id = observation_id(envelope)
      envelope = put_in(envelope, ["source", "hostObservationId"], observation_id)

      if byte_size(Jason.encode!(envelope)) <= @max_bytes, do: {:ok, envelope}, else: {:error, :snapshot_too_large}
    else
      _ -> {:error, :snapshot_observation_unverified}
    end
  rescue
    _ -> {:error, :snapshot_observation_unverified}
  end

  @doc "Persist an immutable host observation then atomically replace the fixed DEV export. Directory and lock must already be provisioned and pinned."
  @spec publish(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def publish(execution, custody, envelope) do
    bytes = Jason.encode!(envelope)
    id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    basis = observation_basis(envelope)
    observation_id = observation_id(basis)

    with true <- envelope["scope"] == @scope and envelope["mode"] == "observed_snapshot",
         true <- byte_size(bytes) <= @max_bytes,
         true <- get_in(envelope, ["source", "hostObservationId"]) == observation_id,
         true <- GovernanceBuildReceipt.file_digest(execution.python_executable) == execution.python_sha256,
         {:ok, _} <- GovernanceHostStore.request(execution, %{"kind" => "observation", "command" => "create", "id" => observation_id, "record" => basis}) do
      request = Map.merge(custody, %{"bytes" => bytes, "sha256" => id})
      cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(execution.python_executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-I", "-S", "-c", writer()]},
          {:env, cleared ++ [{~c"LANG", ~c"C.UTF-8"}]}
        ])

      try do
        Port.command(port, Jason.encode!(request) <> "\n")
        receive_export(port, "")
      after
        GovernanceProcess.stop(port)
      end
    else
      _ -> {:error, :snapshot_export_unverified}
    end
  rescue
    _ -> {:error, :snapshot_export_unavailable}
  end

  defp observation_basis(envelope) do
    Map.update!(envelope, "source", &Map.delete(&1, "hostObservationId"))
  end

  defp observation_id(basis) do
    basis |> CanonicalJson.encode() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp receive_export(port, bytes) do
    receive do
      {^port, {:data, data}} when byte_size(bytes) + byte_size(data) <= 4096 ->
        receive_export(port, bytes <> data)

      {^port, {:exit_status, 0}} ->
        case Jason.decode(bytes) do
          {:ok, %{"ok" => true} = result} -> {:ok, result}
          _ -> {:error, :snapshot_export_unverified}
        end

      {^port, _} ->
        {:error, :snapshot_export_unverified}
    after
      10_000 -> {:error, :snapshot_export_timeout}
    end
  end

  # Anchored dirfds, permanent pinned flock, no-follow leaf opens, bounded bytes,
  # fsync and post-publication path checks. A failure after replace is explicitly
  # indeterminate; it never becomes a successful observation or new authority.
  defp writer do
    ~S"""
    import os,sys,json,stat,fcntl,secrets,hashlib
    def require(v):
        if not v: raise ValueError('rejected')
    def walk(path):
        require(isinstance(path,str) and path.startswith('/') and '..' not in path.split('/'))
        fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        try:
            for part in [p for p in path.split('/') if p]:
                n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                s=os.fstat(n)
                sticky=(part=='tmp' and s.st_uid==0 and s.st_mode&stat.S_ISVTX!=0)
                require(s.st_uid in (0,os.geteuid()) and (s.st_mode&0o022==0 or sticky))
                os.close(fd);fd=n
            return fd
        except BaseException: os.close(fd);raise
    def secure(s):
        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_mode&0o077==0)
    def main():
        q=json.loads(sys.stdin.buffer.readline(1048577))
        require(set(q)=={'directory','directoryDevice','directoryInode','lockDevice','lockInode','bytes','sha256'})
        data=q['bytes'].encode('utf-8');require(2<=len(data)<=262144 and hashlib.sha256(data).hexdigest()==q['sha256'])
        d=walk(q['directory']);temp=None;replaced=False
        try:
            ds=os.fstat(d);require(ds.st_uid==os.geteuid() and ds.st_mode&0o077==0 and (ds.st_dev,ds.st_ino)==(q['directoryDevice'],q['directoryInode']))
            try: os.stat('.INDETERMINATE',dir_fd=d,follow_symlinks=False);raise ValueError('indeterminate')
            except FileNotFoundError: pass
            lock=os.open('.snapshot.lock',os.O_RDWR|os.O_NOFOLLOW,dir_fd=d)
            try:
                ls=os.fstat(lock);secure(ls);require((ls.st_dev,ls.st_ino)==(q['lockDevice'],q['lockInode']))
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                try: os.stat('.INDETERMINATE',dir_fd=d,follow_symlinks=False);raise ValueError('indeterminate')
                except FileNotFoundError: pass
                name='symphony-69.snapshot.json'
                try: secure(os.stat(name,dir_fd=d,follow_symlinks=False))
                except FileNotFoundError: pass
                temp='.snapshot-'+secrets.token_hex(16)
                fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=d)
                try:
                    with os.fdopen(fd,'wb',closefd=False) as f: f.write(data);f.flush();os.fsync(fd)
                finally: os.close(fd)
                check=walk(q['directory'])
                try: require((os.fstat(check).st_dev,os.fstat(check).st_ino)==(ds.st_dev,ds.st_ino))
                finally: os.close(check)
                require((os.stat('.snapshot.lock',dir_fd=d,follow_symlinks=False).st_dev,os.stat('.snapshot.lock',dir_fd=d,follow_symlinks=False).st_ino)==(ls.st_dev,ls.st_ino))
                os.replace(temp,name,src_dir_fd=d,dst_dir_fd=d);replaced=True;temp=None;os.fsync(d)
                check=walk(q['directory'])
                try: require((os.fstat(check).st_dev,os.fstat(check).st_ino)==(ds.st_dev,ds.st_ino))
                finally: os.close(check)
                current_lock=os.stat('.snapshot.lock',dir_fd=d,follow_symlinks=False);secure(current_lock)
                require((current_lock.st_dev,current_lock.st_ino)==(ls.st_dev,ls.st_ino))
                print(json.dumps({'ok':True,'sha256':q['sha256'],'file':name},separators=(',',':')))
            finally: os.close(lock)
        except BaseException:
            if replaced:
                try:
                    marker=os.open('.INDETERMINATE',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=d)
                    os.write(marker,b'export requires offline reconciliation');os.fsync(marker);os.close(marker);os.fsync(d)
                except BaseException: pass
            raise
        finally:
            if temp:
                try: os.unlink(temp,dir_fd=d)
                except FileNotFoundError: pass
            os.close(d)
    try: main()
    except BaseException: print('{"ok":false}');sys.exit(1)
    """
  end

  # The wire allowlist is reused from Front, not independently redefined here.
  # Free-form summary/title values are deliberately omitted: they can contain
  # prompts or credentials despite a valid shape. Only a short constant issue
  # label is rendered; timeline summaries are derived from validated eventType.
  defp project(nil, _, _), do: {:ok, nil}
  defp project(_, _, depth) when depth > 15, do: {:error, :snapshot_depth}

  defp project(value, %{"properties" => properties} = schema, depth) when is_map(value) do
    value = sanitize_text_fields(value)

    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      next = properties[key] || schema["additionalProperties"]

      cond do
        key in ["__proto__", "prototype", "constructor"] ->
          {:halt, {:error, :snapshot_key}}

        is_nil(next) or next == false ->
          {:cont, {:ok, acc}}

        not is_map(next) ->
          {:halt, {:error, :snapshot_schema}}

        not Map.has_key?(properties, key) and not Regex.match?(~r/^[a-z][a-z-]{0,60}$/, key) ->
          {:halt, {:error, :snapshot_key}}

        true ->
          case project(item, next, depth + 1) do
            {:ok, projected} -> {:cont, {:ok, Map.put(acc, key, projected)}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp project(value, %{"items" => item}, depth) when is_list(value) and length(value) <= 100 do
    Enum.reduce_while(value, {:ok, []}, fn value, {:ok, acc} ->
      case project(value, item, depth + 1) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp project(value, %{"additionalProperties" => additional} = schema, depth) when is_map(value) and is_map(additional),
    do: project(value, Map.put(schema, "properties", %{}), depth)

  defp project(value, %{"type" => types}, _) do
    types = List.wrap(types)
    valid = ("string" in types and safe_string?(value)) or ("number" in types and is_number(value)) or ("boolean" in types and is_boolean(value))
    if valid, do: {:ok, value}, else: {:error, :snapshot_value}
  end

  defp project(_, _, _), do: {:error, :snapshot_shape}

  defp sanitize_text_fields(value) do
    value = if value["number"] == 69 and Map.has_key?(value, "title"), do: Map.put(value, "title", "Symphony #69 (observed DEV projection)"), else: value

    if Map.has_key?(value, "summary") do
      event = value["eventType"] || value["event"]
      label = if is_binary(event) and Regex.match?(~r/^[a-z][a-z0-9_.:-]{0,80}$/, event), do: event, else: "governance observation"
      value |> Map.put("summary", label) |> Map.delete("displayName")
    else
      Map.delete(value, "displayName")
    end
  end

  defp safe_string?(v) when is_binary(v) do
    byte_size(v) <= 8192 and String.valid?(v) and not Regex.match?(~r/[\x00-\x08\x0b\x0c\x0e-\x1f]|(?:Bearer\s|sk_(?:live|test)_|sk-proj-|-----BEGIN|(?:api[_-]?key|password|secret|token)\s*[:=])/i, v)
  end

  defp safe_string?(_), do: false

  defp active_candidate?(issue, sha) do
    phases = get_in(issue, ["governance", "phases"]) || %{}
    active = phases["implementation"] || phases["planning"]
    is_nil(active) or (is_map(active) and active["candidateCommitSha"] == sha)
  end

  defp valid_timeline?(timeline) do
    count = get_in(timeline, ["verification", "eventCount"])

    (is_nil(count) or (is_integer(count) and count >= 0)) and length(timeline["events"]) <= 100 and
      Enum.all?(timeline["events"], fn event ->
        is_map(event) and Enum.all?(~w(eventId occurredAt eventType status), &is_binary(event[&1])) and
          is_integer(event["sequence"]) and event["sequence"] >= 0 and
          get_in(event, ["actor", "type"]) in ~w(human agent runner system integration) and
          is_binary(get_in(event, ["actor", "subjectId"])) and
          (not Map.has_key?(event, "runId") or event["runId"] == @run) and
          (not Map.has_key?(event, "issueNumber") or event["issueNumber"] == 69)
      end)
  end

  defp nested_scope?(value) when is_map(value) do
    Enum.all?(value, fn
      {"runId", run} -> run == @run
      {"issueNumber", number} -> number == 69
      {_, nested} -> nested_scope?(nested)
    end)
  end

  defp nested_scope?(value) when is_list(value), do: Enum.all?(value, &nested_scope?/1)
  defp nested_scope?(_), do: true

  defp recovery_metadata(provenance, issue) do
    floor = provenance["counterFloor"]
    counters = get_in(issue, ["governance", "counters"]) || %{}

    valid_floor =
      is_nil(floor) or
        (is_map(floor) and Enum.sort(Map.keys(floor)) == ~w(implementation planning technical transport) and
           Enum.all?(floor, fn {key, value} -> is_integer(value) and value >= 0 and is_integer(counters[key]) and counters[key] >= value end))

    if valid_floor and (not Map.has_key?(provenance, "rawHistoryUnknown") or is_boolean(provenance["rawHistoryUnknown"])) do
      {:ok, Map.take(provenance, ~w(rawHistoryUnknown counterFloor))}
    else
      {:error, :snapshot_recovery_unverified}
    end
  end

  defp original_texts(responses) do
    Enum.reduce_while(responses, {:ok, %{}}, fn
      {key, %{"content" => [%{"type" => "text", "text" => text}]} = response}, {:ok, acc} when is_binary(text) ->
        if response["isError"] == true, do: {:halt, {:error, :snapshot_mcp_error}}, else: {:cont, {:ok, Map.put(acc, key, text)}}

      _, _ ->
        {:halt, {:error, :snapshot_mcp_envelope}}
    end)
  end

  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp utc(time), do: time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp sha?(v), do: is_binary(v) and Regex.match?(~r/^[a-f0-9]{40}$/, v)
  defp digest?(v), do: is_binary(v) and Regex.match?(~r/^sha256:[a-f0-9]{64}$/, v)
  defp identifier?(v), do: is_binary(v) and Regex.match?(~r/^[A-Za-z0-9._:-]{1,160}$/, v)
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
