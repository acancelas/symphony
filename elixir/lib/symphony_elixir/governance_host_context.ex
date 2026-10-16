defmodule SymphonyElixir.GovernanceHostContext do
  @moduledoc false
  @spec prepare(map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(%{sha: sha, manifest: manifest} = context, _policy) when is_binary(sha) and is_map(manifest),
    do: {:ok, context}

  def prepare(context, policy) do
    number = context.issue.native_ref["issueNumber"]

    with {text, 0} <- SymphonyElixir.GovernanceTrustedGit.run(context.workspace, ["rev-parse", "HEAD"]),
         sha = String.trim(text),
         true <- Regex.match?(~r/^[0-9a-f]{40}$/, sha),
         {"", 0} <- SymphonyElixir.GovernanceTrustedGit.run(context.workspace, ["diff", "--cached", "--name-only"]),
         {:ok, bytes} <- File.read(Path.join(context.workspace, "docs/issues/#{number}/manifest.json")),
         {:ok, manifest} <- Jason.decode(bytes),
         {:ok, plan} <- File.read(Path.join(context.workspace, "docs/issues/#{number}/plan.md")),
         true <-
           manifest["issueNumber"] == number and
             manifest["planHash"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, plan), case: :lower),
         true <- manifest["catalogCommitSha"] == SymphonyElixir.GovernanceCatalog.commit() do
      phase =
        if get_in(policy, [:sandbox, "type"]) == "workspaceWrite",
          do: "implementation",
          else: context[:phase] || "implementation"

      {:ok, context |> Map.put(:sha, sha) |> Map.put(:manifest, manifest) |> Map.put(:phase, phase)}
    else
      _ -> {:error, :governance_host_context_unverified}
    end
  end
end
