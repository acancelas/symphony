defmodule SymphonyElixir.CandidateHead do
  @moduledoc """
  Confirms that the exact clean candidate commit is durably reachable from the
  issue branch before reviews or evidence are allowed to reference it.

  The push is deliberately non-forcing. A divergent remote branch fails closed
  so recovery cannot silently replace work accepted by another runner.
  """

  alias SymphonyElixir.Tracker.Issue

  @type confirmation :: %{
          branch: String.t(),
          head_sha: String.t(),
          remote_sha: String.t()
        }

  @spec confirm(Path.t(), Issue.t(), String.t() | nil, keyword()) ::
          {:ok, confirmation()} | {:error, term()}
  def confirm(workspace, %Issue{} = issue, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    with :ok <- require_local_worker(worker_host),
         command_runner <- Keyword.get(opts, :command_runner, &run_command/4),
         {:ok, status} <- git(command_runner, workspace, worker_host, ["status", "--porcelain", "--untracked-files=no"]),
         :ok <- require_clean(status),
         {:ok, head_sha} <- git(command_runner, workspace, worker_host, ["rev-parse", "HEAD"]),
         {:ok, branch} <- git(command_runner, workspace, worker_host, ["symbolic-ref", "--short", "HEAD"]),
         :ok <- require_issue_branch(issue, branch),
         {:ok, remote_sha} <- ensure_remote_head(command_runner, workspace, worker_host, branch, head_sha) do
      {:ok, %{branch: branch, head_sha: head_sha, remote_sha: remote_sha}}
    end
  end

  defp require_local_worker(nil), do: :ok

  defp require_local_worker(worker_host),
    do: {:error, {:candidate_remote_worker_unsupported, worker_host}}

  defp ensure_remote_head(command_runner, workspace, worker_host, branch, head_sha) do
    case remote_head(command_runner, workspace, worker_host, branch) do
      {:ok, ^head_sha} ->
        {:ok, head_sha}

      {:ok, nil} ->
        push_and_confirm(command_runner, workspace, worker_host, branch, head_sha)

      {:ok, remote_sha} ->
        with {:ok, _output} <-
               git(command_runner, workspace, worker_host, [
                 "push",
                 "--set-upstream",
                 "origin",
                 "HEAD:refs/heads/#{branch}"
               ]) do
          confirm_remote_head(command_runner, workspace, worker_host, branch, head_sha, remote_sha)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_and_confirm(command_runner, workspace, worker_host, branch, head_sha) do
    with {:ok, _output} <-
           git(command_runner, workspace, worker_host, [
             "push",
             "--set-upstream",
             "origin",
             "HEAD:refs/heads/#{branch}"
           ]) do
      confirm_remote_head(command_runner, workspace, worker_host, branch, head_sha, nil)
    end
  end

  defp confirm_remote_head(command_runner, workspace, worker_host, branch, head_sha, previous_remote_sha) do
    case remote_head(command_runner, workspace, worker_host, branch) do
      {:ok, ^head_sha} -> {:ok, head_sha}
      {:ok, remote_sha} -> {:error, {:candidate_remote_mismatch, head_sha, remote_sha, previous_remote_sha}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_head(command_runner, workspace, worker_host, branch) do
    with {:ok, output} <-
           git(command_runner, workspace, worker_host, [
             "ls-remote",
             "--heads",
             "origin",
             "refs/heads/#{branch}"
           ]) do
      case String.split(output, ~r/\s+/, trim: true) do
        [] -> {:ok, nil}
        [sha, _ref] -> {:ok, sha}
        _ -> {:error, {:invalid_candidate_remote_response, output}}
      end
    end
  end

  defp require_clean(""), do: :ok

  defp require_clean(status) do
    paths =
      status
      |> String.split("\n", trim: true)
      |> Enum.map(&String.replace(&1, ~r/^.{1,2}\s+/, ""))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:error,
     {:candidate_workspace_dirty,
      %{
        fingerprint: :crypto.hash(:sha256, status) |> Base.encode16(case: :lower),
        paths: paths,
        status: status
      }}}
  end

  defp require_issue_branch(%Issue{branch_name: nil}, _branch), do: :ok
  defp require_issue_branch(%Issue{branch_name: ""}, _branch), do: :ok
  defp require_issue_branch(%Issue{branch_name: branch}, branch), do: :ok

  defp require_issue_branch(%Issue{branch_name: expected}, actual),
    do: {:error, {:candidate_branch_mismatch, expected, actual}}

  defp git(command_runner, workspace, worker_host, args) do
    case command_runner.(workspace, worker_host, "git", args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:error, {:candidate_git_failed, args, status, String.trim(output)}}
      {:error, reason} -> {:error, {:candidate_git_transport_failed, args, reason}}
    end
  end

  defp run_command(workspace, nil, executable, args) do
    {:ok, System.cmd(executable, args, cd: workspace, stderr_to_stdout: true)}
  end
end
