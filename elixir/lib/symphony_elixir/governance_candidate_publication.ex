defmodule SymphonyElixir.GovernanceCandidatePublication do
  @moduledoc "Host-only staged tree confirmation; the worker cannot change Git administration or the plan."
  def stage(context) do
    with {text, 0} <- git(context, ["diff", "--name-only", "-z", "HEAD"]),
         {untracked, 0} <- git(context, ["ls-files", "--others", "--exclude-standard", "-z"]),
         paths = String.split(text <> untracked, <<0>>, trim: true) |> Enum.uniq(),
         true <- Enum.all?(paths, &(permitted?(&1) and regular_change?(context.workspace, &1))),
         {original_modes, 0} <- if(paths == [], do: {"", 0}, else: git(context, ["ls-tree", "-z", "HEAD", "--" | paths])),
         true <- regular_modes?(original_modes),
         {_, 0} <- if(paths == [], do: {"", 0}, else: git(context, ["add", "--" | paths])),
         {staged_modes, 0} <- if(paths == [], do: {"", 0}, else: git(context, ["ls-files", "--stage", "-z", "--" | paths])),
         true <- regular_modes?(staged_modes),
         {tree, 0} <- git(context, ["write-tree"]) do
      {:ok, String.trim(tree)}
    else
      _ -> {:error, :governance_candidate_scope_rejected}
    end
  end

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

  def publish(context, tree) do
    with :ok <- unchanged(context, tree),
         {current_tree, 0} <- git(context, ["rev-parse", "HEAD^{tree}"]),
         {_, 0} <- if(String.trim(current_tree) == tree, do: {"", 0}, else: git(context, ["commit", "-m", "Implement governed Issue #{context.issue.native_ref["issueNumber"]}"])),
         {:ok, candidate} <- SymphonyElixir.GovernanceCandidateHead.confirm(context.workspace, context.issue, context[:worker_host]),
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
      Enum.all?(Path.split(path), &(not String.starts_with?(&1, ".") and &1 not in ~w(AGENTS.md WORKFLOW.md GOVERNANCE.md auth.json credentials.json secrets.json)))
  end

  defp git(context, args), do: SymphonyElixir.GovernanceTrustedGit.run(context.workspace, args)
end
