defmodule SymphonyElixir.GovernanceDossier do
  @moduledoc "Controller-owned fixed-path dossier writer; model output is never a filesystem path."
  alias SymphonyElixir.{GovernanceCatalog, PathSafety}

  def commit(workspace, issue, draft, bindings \\ %{})

  def commit(workspace, issue, %{"plan" => plan, "manifest" => manifest} = draft, bindings)
      when is_binary(plan) and is_map(manifest) and byte_size(plan) > 0 do
    number = issue.native_ref["issueNumber"]
    relative = "docs/issues/#{number}"
    files = ["#{relative}/plan.md", "#{relative}/manifest.json"]

    with true <- Enum.sort(Map.keys(draft)) == ["manifest", "plan"],
         true <- is_integer(number) and number > 0,
         true <- is_binary(bindings["definitionDigest"]) and Regex.match?(~r/^sha256:[0-9a-f]{64}$/, bindings["definitionDigest"]),
         {:ok, root} <- PathSafety.canonicalize(workspace),
         true <- Enum.all?(files, &safe?(root, &1)),
         {"", 0} <- System.cmd("git", ["-C", root, "status", "--porcelain", "--untracked-files=all"]),
         true <- is_list(manifest["scope"]) and is_list(manifest["acceptanceCriteria"]) and is_list(manifest["requirements"]),
         :ok <- File.mkdir_p(Path.join(root, relative)),
         true <- Enum.all?(files, &safe?(root, &1)),
         manifest =
           Map.merge(manifest, %{"issueNumber" => number, "catalogCommitSha" => GovernanceCatalog.commit(), "planHash" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, plan), case: :lower)}),
         manifest = Map.merge(manifest, bindings),
         :ok <- File.write(Path.join(root, hd(files)), plan),
         :ok <- File.write(Path.join(root, List.last(files)), Jason.encode!(manifest) <> "\n"),
         {_, 0} <- System.cmd("git", ["-C", root, "add", "--" | files], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", root, "commit", "-m", "Prepare governed plan for Issue #{number}", "--" | files], stderr_to_stdout: true) do
      :ok
    else
      _ -> {:error, :governance_dossier_write_rejected}
    end
  end

  def commit(_, _, _, _), do: {:error, :governance_dossier_write_rejected}

  defp safe?(root, relative) do
    path = Path.join(root, relative)

    case PathSafety.canonicalize(path) do
      {:ok, ^path} -> true
      _ -> false
    end
  end
end
