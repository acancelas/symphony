defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) and recover_non_git_directories?() and
          !File.exists?(Path.join(workspace, ".git")) ->
        recover_non_git_workspace(workspace)

      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    recover_non_git = if recover_non_git_directories?(), do: "1", else: "0"

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("recover_non_git", recover_non_git),
        "if [ -d \"$workspace\" ]; then",
        "  if [ \"$recover_non_git\" = 1 ] && [ ! -e \"$workspace/.git\" ] && [ -n \"$(find \"$workspace\" -mindepth 1 -maxdepth 1 -print -quit)\" ]; then",
        "    orphan=\"${workspace}.orphaned-$(date +%s)-$$\"",
        "    mv -- \"$workspace\" \"$orphan\"",
        "    mkdir -p \"$workspace\"",
        "    created=1",
        "  elif [ \"$recover_non_git\" = 1 ] && [ ! -e \"$workspace/.git\" ]; then",
        "    created=1",
        "  else",
        "    created=0",
        "  fi",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp recover_non_git_workspace(workspace) do
    case File.ls(workspace) do
      {:ok, []} ->
        {:ok, workspace, true}

      {:ok, _entries} ->
        orphan = "#{workspace}.orphaned-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"

        with :ok <- File.rename(workspace, orphan),
             :ok <- File.mkdir_p(workspace) do
          Logger.warning("Preserved non-Git workspace before reconstruction workspace=#{workspace} orphan=#{orphan}")
          {:ok, workspace, true}
        end

      {:error, reason} ->
        {:error, {:workspace_inspection_failed, workspace, reason}}
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)
    recover_non_git = if recover_non_git_directories?(), do: "1", else: "0"

    script =
      [
        "set -u",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("recover_non_git", recover_non_git),
        "if [ \"$recover_non_git\" = 1 ] && [ ! -e \"$workspace/.git\" ]; then",
        "  printf '%s\\n' '__SYMPHONY_GIT_STATUS_FAILED__'",
        "  printf '%s\\n' 'Configured Git workspace is missing .git metadata.'",
        "  exit 74",
        "fi",
        "if [ -e \"$workspace/.git\" ]; then",
        "  git_status=$(git -C \"$workspace\" status --porcelain=v1 --untracked-files=all 2>&1)",
        "  git_status_code=$?",
        "  if [ \"$git_status_code\" -ne 0 ]; then",
        "    printf '%s\\n' '__SYMPHONY_GIT_STATUS_FAILED__'",
        "    printf '%s\\n' \"$git_status\"",
        "    exit 74",
        "  fi",
        "  if [ -n \"$git_status\" ]; then",
        "    printf '%s\\n' '__SYMPHONY_DIRTY_WORKSPACE__'",
        "    printf '%s\\n' \"$git_status\"",
        "    exit 73",
        "  fi",
        "  upstream=$(git -C \"$workspace\" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>&1)",
        "  upstream_status=$?",
        "  if [ \"$upstream_status\" -ne 0 ] || ! git -C \"$workspace\" merge-base --is-ancestor HEAD \"$upstream\"; then",
        "    printf '%s\\n' '__SYMPHONY_UNPUBLISHED_HEAD__'",
        "    printf '%s\\n' \"$upstream\"",
        "    exit 75",
        "  fi",
        "fi",
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, 73}} ->
        preserve_dirty_workspace(workspace, worker_host, output)

      {:ok, {output, 74}} ->
        preserve_unreadable_workspace(workspace, worker_host, output)

      {:ok, {output, 75}} ->
        preserve_unpublished_workspace(workspace, worker_host, output)

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)

    case local_workspace_git_state(workspace) do
      :clean -> File.rm_rf(workspace)
      {:dirty, output} -> preserve_dirty_workspace(workspace, nil, output)
      {:unreadable, output} -> preserve_unreadable_workspace(workspace, nil, output)
      {:unpublished, output} -> preserve_unpublished_workspace(workspace, nil, output)
    end
  end

  defp local_workspace_git_state(workspace) do
    if File.exists?(Path.join(workspace, ".git")) do
      case System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {"", 0} -> local_workspace_head_state(workspace)
        {output, 0} -> {:dirty, output}
        {output, _status} -> {:unreadable, output}
      end
    else
      if recover_non_git_directories?() do
        {:unreadable, "Configured Git workspace is missing .git metadata."}
      else
        :clean
      end
    end
  rescue
    error -> {:unreadable, Exception.message(error)}
  end

  defp local_workspace_head_state(workspace) do
    with {upstream, 0} <-
           System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd("git", ["merge-base", "--is-ancestor", "HEAD", String.trim(upstream)],
             cd: workspace,
             stderr_to_stdout: true
           ) do
      :clean
    else
      {output, _status} -> {:unpublished, output}
    end
  rescue
    error -> {:unreadable, Exception.message(error)}
  end

  defp preserve_dirty_workspace(workspace, worker_host, output) do
    summary = bounded_git_status(output)

    Logger.warning("Preserving dirty workspace instead of deleting it workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} status=#{inspect(summary)}")

    {:error, {:workspace_has_uncommitted_changes, workspace, worker_host}, summary}
  end

  defp preserve_unreadable_workspace(workspace, worker_host, output) do
    summary = bounded_git_status(output)

    Logger.warning("Preserving workspace because Git state is unreadable workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} error=#{inspect(summary)}")

    {:error, {:workspace_git_status_failed, workspace, worker_host}, summary}
  end

  defp preserve_unpublished_workspace(workspace, worker_host, output) do
    summary = bounded_git_status(output)

    Logger.warning("Preserving workspace because HEAD is not confirmed by its upstream workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} detail=#{inspect(summary)}")

    {:error, {:workspace_head_not_durable, workspace, worker_host}, summary}
  end

  defp bounded_git_status(output) when is_binary(output), do: String.slice(output, 0, 4_000)
  defp bounded_git_status(output), do: output |> inspect() |> String.slice(0, 4_000)

  defp recover_non_git_directories?, do: Config.settings!().workspace.recover_non_git_directories

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: hook_environment(issue_context)
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    environment =
      issue_context
      |> hook_environment()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)

    case run_remote_command(
           worker_host,
           "cd #{shell_escape(workspace)} && env #{environment} sh -lc #{shell_escape(command)}",
           timeout_ms
         ) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    native_ref = Map.get(issue, :native_ref) || %{}

    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      repository_id: native_ref["repositoryId"],
      repository_owner: native_ref["repositoryOwner"],
      repository_name: native_ref["repositoryName"],
      repository_clone_url: native_ref["repositoryCloneUrl"],
      issue_number: native_ref["issueNumber"],
      run_id: native_ref["runId"]
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp hook_environment(issue_context) do
    %{
      "BOS_ISSUE_ID" => issue_context[:issue_id],
      "BOS_ISSUE_IDENTIFIER" => issue_context[:issue_identifier],
      "BOS_ISSUE_NUMBER" => issue_context[:issue_number],
      "BOS_REPOSITORY_ID" => issue_context[:repository_id],
      "BOS_REPOSITORY_OWNER" => issue_context[:repository_owner],
      "BOS_REPOSITORY_NAME" => issue_context[:repository_name],
      "BOS_REPOSITORY_CLONE_URL" => issue_context[:repository_clone_url],
      "BOS_RUN_ID" => issue_context[:run_id]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
