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
