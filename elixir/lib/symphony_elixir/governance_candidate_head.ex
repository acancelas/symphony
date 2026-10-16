defmodule SymphonyElixir.GovernanceCandidateHead do
  @moduledoc "Reuse candidate confirmation against the server-verified configured repository without editing shared remotes."
  def confirm(workspace, issue, worker_host) do
    configuration = Application.fetch_env!(:symphony_elixir, :governance)[:broker]
    repository = configuration.repositories[issue.native_ref["repositoryId"]]

    if is_map(repository) and Enum.all?(~w(owner repo), &(is_binary(repository[&1]) and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, repository[&1]))) do
      remote = "https://github.com/#{repository["owner"]}/#{repository["repo"]}.git"
      SymphonyElixir.CandidateHead.confirm(workspace, issue, worker_host, remote: remote, command_runner: &trusted_git/4)
    else
      {:error, :governance_canonical_repository_unverified}
    end
  end

  defp trusted_git(workspace, nil, "git", arguments) do
    {:ok, SymphonyElixir.GovernanceTrustedGit.run(workspace, arguments)}
  end
end
