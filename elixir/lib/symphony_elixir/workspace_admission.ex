defmodule SymphonyElixir.WorkspaceAdmission do
  @moduledoc "Opt-in host guard for future local workspaces; never moves admitted worktrees or falls back to cloning."
  alias SymphonyElixir.{Config, GovernanceProcess, PathSafety}

  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(Config.settings!().workspace.admission)

  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  def create(context) do
    with {:ok, configuration} <- configuration(),
         canonical when is_binary(canonical) <- configuration["canonical_repositories"][context[:repository_id]],
         {:ok, ^canonical} <- PathSafety.canonicalize(canonical),
         owner when is_binary(owner) <- context[:run_id] || configuration["owner"],
         true <- Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9:._-]{0,159}$/, owner),
         id when is_binary(id) and id != "" <- context[:issue_id],
         task = task_id(context[:repository_id], id),
         {:ok, record} <- invoke(configuration, canonical, task, owner),
         true <- valid_record?(record, canonical, task, owner),
         :ok <- validate_path(record["path"]) do
      {:ok, record["path"]}
    else
      {:error, _} = error -> error
      _ -> {:error, :workspace_admission_scope_unverified}
    end
  rescue
    _ -> {:error, :workspace_admission_unavailable}
  end

  @spec task_id(String.t(), String.t()) :: String.t()
  def task_id(repository, id) do
    hash = :crypto.hash(:sha256, Jason.encode!([repository, id])) |> Base.encode16(case: :lower)
    "issue-" <> binary_part(hash, 0, 58)
  end

  @spec guarded_path?(String.t()) :: boolean()
  def guarded_path?(path), do: ".bos-worktrees" in Path.split(Path.expand(path))

  @spec validate_path(String.t()) :: :ok | {:error, atom()}
  def validate_path(path) do
    with {:ok, configuration} <- configuration(),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         true <- Enum.any?(configuration["canonical_repositories"], fn {_, canonical} -> registered?(canonical, path) end) do
      :ok
    else
      _ -> {:error, :workspace_admission_path_unverified}
    end
  rescue
    _ -> {:error, :workspace_admission_path_unverified}
  end

  defp configuration do
    value = Config.settings!().workspace.admission
    allowed = ~w(command command_sha256 guard_path guard_sha256 canonical_repositories owner)

    with true <- is_map(value) and Enum.all?(Map.keys(value), &(&1 in allowed)),
         command when is_binary(command) <- value["command"],
         true <- Path.type(command) == :absolute,
         expected when is_binary(expected) <- value["command_sha256"],
         true <- Regex.match?(~r/^[a-f0-9]{64}$/, expected),
         {:ok, %{type: :regular}} <- File.lstat(command),
         true <- digest(File.read!(command)) == expected,
         guard when is_binary(guard) <- value["guard_path"],
         true <- Path.type(guard) == :absolute,
         {:ok, %{type: :regular}} <- File.lstat(guard),
         true <- digest(File.read!(guard)) == value["guard_sha256"],
         roots when is_map(roots) and map_size(roots) > 0 <- value["canonical_repositories"],
         true <- Enum.all?(roots, fn {id, root} -> is_binary(id) and is_binary(root) and Path.type(root) == :absolute end) do
      {:ok, value}
    else
      _ -> {:error, :workspace_admission_configuration_invalid}
    end
  end

  defp invoke(configuration, canonical, task, owner) do
    arguments = ["create", "--canonical", canonical, "--task", task, "--owner", owner]

    port =
      Port.open({:spawn_executable, String.to_charlist(configuration["command"])}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(arguments, &String.to_charlist/1),
        cd: String.to_charlist(canonical)
      ])

    try do
      collect(port, "", System.monotonic_time(:millisecond) + 180_000)
    after
      GovernanceProcess.stop(port)
    end
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(output) + byte_size(chunk) <= 65_536 ->
        collect(port, output <> chunk, deadline)

      {^port, {:data, _}} ->
        {:error, :workspace_admission_output_exceeded}

      {^port, {:exit_status, status}} ->
        result(output, status)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, :workspace_admission_timeout_reconcile_required}
    end
  end

  defp result(output, 0) do
    case Jason.decode(output) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, :workspace_admission_response_invalid}
    end
  end

  defp result(output, _) do
    case Jason.decode(output) do
      {:ok, %{"status" => "blocked", "reason" => reason}} when is_binary(reason) -> {:error, {:workspace_admission_blocked, reason}}
      _ -> {:error, :workspace_admission_failed_reconcile_required}
    end
  end

  defp valid_record?(record, canonical, task, owner) do
    expected = %{
      "enforced" => true,
      "state" => "created",
      "task" => task,
      "owner" => owner,
      "path" => target(canonical, task),
      "branch" => "refs/heads/codex/" <> task,
      "limit" => 4
    }

    Enum.all?(expected, fn {key, value} -> record[key] == value end) and valid_capacity?(record) and
      is_binary(record["baseSha"]) and Regex.match?(~r/^[a-f0-9]{40}([a-f0-9]{24})?$/, record["baseSha"])
  end

  defp valid_capacity?(%{"status" => status, "occupied" => occupied})
       when status in ["created", "reuse_existing"] and is_integer(occupied) and occupied >= 2,
       do: status == "reuse_existing" or occupied <= 4

  defp valid_capacity?(_), do: false

  defp registered?(canonical, path) do
    task = Path.basename(path)

    with true <- Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,63}$/, task),
         true <- path == target(canonical, task),
         {:ok, ^canonical} <- PathSafety.canonicalize(canonical),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(path, ".git")),
         {common, 0} <- System.cmd("git", ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], stderr_to_stdout: true),
         {:ok, expected} <- PathSafety.canonicalize(Path.join(canonical, ".git")),
         {:ok, ^expected} <- PathSafety.canonicalize(String.trim(common)),
         {branch, 0} <- System.cmd("git", ["-C", path, "symbolic-ref", "HEAD"], stderr_to_stdout: true),
         true <- String.trim(branch) == "refs/heads/codex/" <> task,
         true <- listed?(canonical, path, String.trim(branch)) do
      true
    else
      _ -> false
    end
  end

  defp listed?(canonical, path, branch) do
    case System.cmd("git", ["-C", canonical, "worktree", "list", "--porcelain", "-z"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(<<0, 0>>)
        |> Enum.any?(fn entry ->
          fields = String.split(entry, <<0>>)
          ("worktree " <> path) in fields and ("branch " <> branch) in fields
        end)

      _ ->
        false
    end
  end

  defp target(canonical, task), do: Path.join([Path.dirname(canonical), ".bos-worktrees", Path.basename(canonical), task])
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
