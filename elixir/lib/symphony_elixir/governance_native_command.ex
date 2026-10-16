defmodule SymphonyElixir.GovernanceNativeCommand do
  @moduledoc "Fixed QA in a measured read-only source namespace with a fresh private output cache; no model."
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.GovernanceProcess
  alias SymphonyElixir.GovernanceRuntime
  alias SymphonyElixir.GovernanceWorkspaceProfile
  @bwrap_sha "01fb705f067bd5365b63d8ad2323a61c8d007733ca5e649437e086f3fb9935d8"
  @outputs ~w(_build bin cover)

  @spec recipe_sha256() :: String.t()
  def recipe_sha256 do
    digest(
      CanonicalJson.encode(%{
        version: 1,
        parentRecipe: GovernanceWorkspaceProfile.recipe_sha256(),
        sourceAuditRecipe: GovernanceWorkspaceProfile.qa_audit_recipe_sha256(),
        source: "read-only",
        outputs: @outputs,
        cache: "exclusive-empty-per-invocation",
        outer: ~w(empty-root unshare-user unshare-net unshare-pid die-with-parent new-session private-proc private-dev private-tmp masked-secrets readonly-root),
        bwrapSha256: @bwrap_sha,
        profile: "bos-qa",
        network: "isolated-loopback-only",
        home: "empty-no-auth"
      })
    )
  end

  @spec required_denials() :: [String.t()]
  def required_denials do
    Enum.reject(GovernanceWorkspaceProfile.required_denials(), &(&1 in ~w(workerLoopback nestedOverrideAgentsWrite))) ++
      ~w(workspaceWrite hostUnixConnect qaReadonlyAliasWrite procAncestorSecretVisible)
  end

  @spec preflight(map()) :: :ok | {:error, atom()}
  def preflight(configuration) do
    runtime = configuration.runtime

    with :ok <- GovernanceRuntime.validate(runtime),
         {:ok, dependencies} <- GovernanceRuntime.dependency_roots(runtime),
         execution when is_map(execution) <- configuration[:execution],
         executable when is_binary(executable) <- execution[:qa_executable],
         true <- GovernanceBuildReceipt.file_digest(executable) == execution[:qa_executable_sha256],
         {:ok, ^executable} <- SymphonyElixir.PathSafety.canonicalize(executable),
         true <- Enum.any?(dependencies, &String.starts_with?(executable, &1 <> "/")),
         path when is_binary(path) <- runtime[:qa_proof_path],
         pin when is_binary(pin) <- runtime[:qa_proof_sha256],
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == pin,
         {:ok, proof} <- Jason.decode(bytes),
         :ok <- validate_proof(runtime, proof) do
      :ok
    else
      _ -> {:error, :governance_qa_profile_unverified}
    end
  rescue
    _ -> {:error, :governance_qa_profile_unverified}
  end

  @doc false
  @spec validate_proof(map(), map()) :: :ok | {:error, atom()}
  def validate_proof(runtime, proof) do
    with true <- proof["qaRecipeSha256"] == recipe_sha256(),
         true <- proof["nativeExecutableSha256"] == runtime.executable_sha256,
         true <- proof["nativeConfigSha256"] == runtime.native_config_sha256,
         true <- proof["dependencyReceiptsSha256"] == digest(CanonicalJson.encode(runtime[:dependency_receipts] || [])),
         {:ok, expiry, _} <- DateTime.from_iso8601(proof["expiresAt"]),
         true <- DateTime.compare(expiry, DateTime.utc_now()) == :gt,
         true <- proof["processReaped"] == true and proof["syntheticChecksPassed"] == true,
         checks when is_map(checks) <- proof["checks"],
         true <- Enum.all?(~w(allowedRead qaOutputWrite qaReadonlyAliasRead workerLoopback ownProcRead), &(checks[&1] == true)),
         true <- checks["networkInterfaces"] == ["lo"],
         true <- Enum.all?(required_denials(), &(checks[&1] == false)),
         proxies when is_map(proxies) <- checks["hostProxyConnect"],
         true <- Enum.all?(proxies, fn {_, value} -> value == false end) do
      :ok
    else
      _ -> {:error, :governance_qa_profile_unverified}
    end
  rescue
    _ -> {:error, :governance_qa_profile_unverified}
  end

  @doc "Host-only QA sandbox prefix; no launch, approval or arbitrary model tool."
  @spec sandbox(map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def sandbox(context, runtime, cache) do
    with {:ok, deps} <- GovernanceRuntime.dependency_roots(runtime),
         {:ok, source} <- SymphonyElixir.PathSafety.canonicalize(context.workspace),
         true <- source == context.workspace,
         {:ok, canonical_cache} <- SymphonyElixir.PathSafety.canonicalize(cache),
         true <- canonical_cache == cache and not inside?(cache, source),
         true <- not inside?(cache, runtime.auth_home) and not inside?(runtime.auth_home, cache),
         true <- Enum.all?(deps ++ [runtime.vendor_root], &(not inside?(cache, &1) and not inside?(&1, cache))),
         true <- private_directory?(cache),
         {:ok, original} <- GovernanceWorkspaceProfile.build_qa(source, runtime.vendor_root, deps),
         bwrap = Path.join(runtime.vendor_root, "codex-resources/bwrap"),
         true <- GovernanceBuildReceipt.file_digest(bwrap) == @bwrap_sha,
         {:ok, profile} <- qa_profile(original, cache),
         {:ok, masks} <- masks(original, source, cache),
         true <- Enum.all?(@outputs, &directory?(Path.join([source, "elixir", &1]))),
         true <- Enum.all?(@outputs ++ ~w(home tmp outbox), &private_directory?(Path.join(cache, &1))) do
      os =
        Enum.filter(
          ~w(/usr /bin /sbin /lib /lib64 /etc/ld.so.cache /etc/ld.so.conf /etc/ld.so.conf.d /etc/nsswitch.conf /etc/passwd /etc/group /etc/hosts /etc/resolv.conf /etc/localtime),
          &File.exists?/1
        )

      binds = Enum.flat_map(Enum.uniq(os ++ deps ++ [runtime.vendor_root, source]), &["--ro-bind", &1, &1])
      outputs = Enum.flat_map(@outputs, &["--bind", Path.join(cache, &1), Path.join([source, "elixir", &1])])

      outer =
        ~w(--unshare-user --unshare-net --unshare-pid --die-with-parent --new-session --tmpfs /) ++
          binds ++
          ~w(--dev /dev --proc /proc --tmpfs /tmp --dir /run --dir /mnt) ++
          masks ++
          ["--bind", cache, cache] ++ outputs ++ ["--remount-ro", "/", "--chdir", source, "--", runtime.executable]

      native =
        Enum.drop(GovernanceRuntime.startup_arguments(runtime), -1) ++
          ["-c", "project_doc_max_bytes=0", "-c", "project_doc_fallback_filenames=[]"] ++
          GovernanceRuntime.permission_arguments(profile, "bos-qa") ++
          ["sandbox", "--permission-profile", "bos-qa", "--cd", source, "--"]

      {:ok, %{executable: bwrap, arguments: outer ++ native, profile: profile, cache: cache}}
    else
      _ -> {:error, :governance_qa_sandbox_rejected}
    end
  rescue
    _ -> {:error, :governance_qa_sandbox_rejected}
  end

  defp qa_profile(original, cache) do
    rules = Map.new(original["filesystem"][":workspace_roots"], fn {path, access} -> {path, if(access == "write", do: "read", else: access)} end)
    rules = Enum.reduce(@outputs, rules, &Map.put(&2, "elixir/" <> &1, "write"))

    profile =
      original
      |> put_in(["filesystem", ":workspace_roots"], rules)
      |> put_in(["filesystem", "/proc"], "read")
      |> put_in(["filesystem", cache], "write")
      |> put_in(["network", "enabled"], true)

    {:ok, profile}
  end

  defp masks(profile, source, cache) do
    empty = Path.join(cache, "empty-ro")

    case File.lstat(empty) do
      {:ok, %{type: :regular, size: 0, links: 1}} -> {:ok, source_masks(profile, source, empty)}
      _ -> {:error, :governance_qa_empty_mask_missing}
    end
  end

  defp source_masks(profile, source, empty) do
    profile["filesystem"][":workspace_roots"]
    |> Enum.filter(fn {path, access} -> access == "deny" and not String.contains?(path, ["*", "?"]) end)
    |> Enum.map(fn {path, _} -> Path.join(source, path) end)
    |> Enum.filter(&File.exists?/1)
    |> Enum.sort_by(&byte_size/1)
    |> Enum.reduce([], &root_mask/2)
    |> Enum.flat_map(&mask_arguments(&1, empty))
  end

  defp root_mask(path, roots) do
    if Enum.any?(roots, &inside?(path, &1)), do: roots, else: roots ++ [path]
  end

  defp mask_arguments(path, empty) do
    if File.dir?(path), do: ["--tmpfs", path, "--remount-ro", path], else: ["--ro-bind", empty, path]
  end

  defp directory?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  defp private_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, access: :read_write, mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      _ -> false
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp fresh_cache(runtime, source) do
    with {:ok, root} <- SymphonyElixir.PathSafety.canonicalize(runtime.worker_root),
         true <- root == runtime.worker_root and not inside?(root, source),
         cache = Path.join(root, "qa-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)),
         :ok <- File.mkdir(cache),
         :ok <- File.chmod(cache, 0o700),
         :ok <- create_cache_children(cache),
         :ok <- prepare_mountpoints(source) do
      {:ok, cache}
    else
      _ -> {:error, :governance_qa_cache_unavailable}
    end
  end

  defp create_cache_children(cache) do
    Enum.each(@outputs ++ ~w(home tmp outbox), fn name ->
      path = Path.join(cache, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end)

    File.write!(Path.join(cache, "empty-ro"), "", [:exclusive])
    File.chmod!(Path.join(cache, "empty-ro"), 0o400)
  end

  defp prepare_mountpoints(source) do
    Enum.reduce_while(@outputs, :ok, fn name, :ok -> mountpoint(Path.join([source, "elixir", name])) end)
  end

  defp mountpoint(path) do
    case File.mkdir(path) do
      :ok -> {:cont, :ok}
      {:error, :eexist} -> existing_mountpoint(path)
      _ -> {:halt, {:error, :invalid_qa_mountpoint}}
    end
  end

  defp existing_mountpoint(path) do
    if directory?(path), do: {:cont, :ok}, else: {:halt, {:error, :invalid_qa_mountpoint}}
  end

  @spec qa(map(), map(), (-> :ok | {:error, term()})) :: {:ok, map()} | {:error, atom()}
  def qa(context, configuration, guard) when is_function(guard, 0) do
    execution = configuration.execution

    with monitor when is_pid(monitor) <- configuration[:execution_monitor],
         true <- context.issue.native_ref["repositoryId"] == "symphony",
         executable when is_binary(executable) <- execution[:qa_executable],
         true <- GovernanceBuildReceipt.file_digest(executable) == execution[:qa_executable_sha256],
         :ok <- guard.(),
         :ok <- GovernanceRuntime.validate(configuration.runtime),
         :ok <- preflight(configuration),
         {:ok, dependencies} <- GovernanceRuntime.dependency_roots(configuration.runtime),
         {:ok, canonical_executable} <- SymphonyElixir.PathSafety.canonicalize(executable),
         true <- canonical_executable == executable,
         true <- Enum.any?(dependencies, &String.starts_with?(executable, &1 <> "/")),
         mix_home when is_binary(mix_home) <- Enum.find(dependencies, &(Path.basename(&1) == ".mix")),
         {:ok, cache} <- fresh_cache(configuration.runtime, context.workspace),
         {:ok, sandbox} <- sandbox(context, configuration.runtime, cache) do
      outbox = Path.join(cache, "outbox")
      path = Enum.map_join(dependencies, ":", &Path.join(&1, "bin")) <> ":/usr/bin:/bin"

      command = [
        "/usr/bin/env",
        "-i",
        "PATH=" <> path,
        "LANG=C.UTF-8",
        "MIX_HOME=" <> mix_home,
        "HEX_OFFLINE=1",
        "BOS_OUTBOX_ROOT=" <> outbox,
        "MIX_BUILD_PATH=" <> Path.join(cache, "_build"),
        "/usr/bin/env",
        "-C",
        Path.join(context.workspace, "elixir"),
        "/bin/sh",
        "-c",
        ~S(set -eu; umask 077; mkdir -p -- "$1/tmp" "$1/home"; export TMPDIR="$1/tmp" HOME="$1/home"; shift; MIX_ENV=dev "$@" build; MIX_ENV=dev "$@" format --check-formatted; MIX_ENV=dev "$@" lint; MIX_ENV=test "$@" test --cover; MIX_ENV=dev "$@" dialyzer --format short),
        "bos-qa",
        outbox,
        executable
      ]

      arguments = sandbox.arguments ++ command

      cleared = Enum.map(System.get_env(), fn {k, _} -> {String.to_charlist(k), false} end)

      env =
        cleared ++
          [
            {~c"PATH", ~c"/usr/bin:/bin"},
            {~c"HOME", String.to_charlist(Path.join(cache, "home"))},
            {~c"CODEX_HOME", String.to_charlist(Path.join(cache, "home"))},
            {~c"LANG", ~c"C.UTF-8"}
          ]

      {:ok, port} =
        SymphonyElixir.GovernanceExecutionMonitor.open_command(monitor, sandbox.executable, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, arguments},
          {:env, env},
          {:cd, context.workspace}
        ])

      try do
        started = System.monotonic_time(:millisecond)

        pid =
          case Port.info(port, :os_pid) do
            {:os_pid, value} -> value
            _ -> nil
          end

        with {:ok, output} <- collect(port, guard, "", started),
             :ok <- retired(port, pid, System.monotonic_time(:millisecond) + 1000) do
          {:ok,
           %{
             "kind" => "complete_qa_suite",
             "status" => "passed",
             "complete" => true,
             "environment" => "local",
             "commands" => [Enum.join(command, " ")],
             "outputSha256" => digest(output),
             "qaRecipeSha256" => recipe_sha256(),
             "privateCache" => cache,
             "processReaped" => true,
             "output" => SymphonyElixir.GovernanceToolBoundary.safe_output(output)
           }}
        else
          error -> error
        end
      after
        SymphonyElixir.GovernanceExecutionMonitor.close_command(monitor, port)
        GovernanceProcess.stop(port)
      end
    else
      _ -> {:error, :governance_sandbox_qa_unverified}
    end
  rescue
    _ -> {:error, :governance_sandbox_qa_failed}
  end

  defp retired(port, pid, deadline) when is_integer(pid) and pid > 1 do
    GovernanceProcess.stop(port)

    case File.lstat("/proc/#{pid}") do
      {:error, :enoent} -> :ok
      _ -> wait_retired(port, pid, deadline)
    end
  end

  defp retired(_, _, _), do: {:error, :governance_qa_reaping_unverified}

  defp wait_retired(port, pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      retired(port, pid, deadline)
    else
      {:error, :governance_qa_reaping_unverified}
    end
  end

  defp collect(port, guard, output, started) do
    with :ok <- guard.(), true <- System.monotonic_time(:millisecond) - started < 900_000 do
      receive do
        {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= 1_000_000 ->
          collect(port, guard, output <> bytes, started)

        {^port, {:exit_status, 0}} ->
          with :ok <- guard.(), do: {:ok, output}

        {^port, _} ->
          {:error, :governance_sandbox_qa_failed}
      after
        100 -> collect(port, guard, output, started)
      end
    else
      _ -> {:error, :governance_sandbox_qa_cancelled}
    end
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
