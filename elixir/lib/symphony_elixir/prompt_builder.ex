defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.Config
  alias SymphonyElixir.GovernanceTrustedGit
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workflow

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @doc "Assemble original, exact-candidate policy texts before any governed implementation turn."
  @spec governed_policy_material(map(), map()) :: {:ok, map()} | {:error, atom()}
  def governed_policy_material(context, configuration) do
    with pins when is_list(pins) <- configuration[:policy_sources],
         fallbacks when is_list(fallbacks) <- configuration[:policy_fallback_filenames],
         true <- valid_policy_names?(fallbacks),
         names = ["AGENTS.override.md", "AGENTS.md" | fallbacks],
         {:ok, external} <- external_policies(context.workspace, configuration.auth_home, names, pins),
         {:ok, repository} <- repository_policies(context, names),
         true <- external != [] and repository != [] do
      entries = external ++ repository
      manifest = Enum.map(entries, &Map.drop(&1, ["text"]))
      digest = policy_digest(CanonicalJson.encode(manifest))
      prompt = policy_scope_instructions(context.workspace) <> Enum.map_join(entries, "\n\n", &policy_message/1)
      {:ok, %{prompt: prompt, manifest: manifest, digest: digest}}
    else
      _ -> {:error, :governance_original_policy_material_rejected}
    end
  rescue
    _ -> {:error, :governance_original_policy_material_rejected}
  end

  defp valid_policy_names?(names) do
    Enum.all?(names, fn name ->
      is_binary(name) and name != "" and Path.basename(name) == name and
        name not in [".", "..", "AGENTS.override.md", "AGENTS.md"] and
        not String.contains?(name, ["\\", "\n", "\r", <<0>>])
    end) and Enum.uniq(names) == names
  end

  defp external_policies(workspace, auth_home, names, pins) do
    global = selected_external(auth_home, ["AGENTS.override.md", "AGENTS.md"])
    directories = workspace |> Path.expand() |> Path.dirname() |> policy_ancestors()
    selected = (global ++ Enum.flat_map(directories, &selected_external(&1, names))) |> Enum.uniq()
    pinned = Map.new(pins, &{&1["path"], &1["sha256"]})

    if global != [] and map_size(pinned) == length(pins) and Enum.sort(Map.keys(pinned)) == Enum.sort(selected) do
      policy_entries(selected, &scoped_external_policy(&1, pinned[&1], global))
    else
      {:error, :governance_external_policy_inventory_mismatch}
    end
  end

  defp scoped_external_policy(path, expected, global) do
    with {:ok, entry} <- external_policy(path, expected) do
      if path in global,
        do: {:ok, entry |> Map.put("scope", "GLOBAL") |> Map.put("scopeKind", "global")},
        else: {:ok, Map.put(entry, "scopeKind", "bos-host-ancestor")}
    end
  end

  defp policy_ancestors("/"), do: ["/"]
  defp policy_ancestors(path), do: policy_ancestors(Path.dirname(path)) ++ [path]

  defp selected_external(directory, names) do
    Enum.reduce_while(names, [], fn name, _ ->
      path = Path.join(directory, name)

      case File.lstat(path) do
        {:error, :enoent} -> {:cont, []}
        {:ok, %{type: :regular, size: 0}} -> {:cont, []}
        _ -> {:halt, [path]}
      end
    end)
  end

  defp external_policy(path, expected) do
    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %{type: :regular, links: 1}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- bytes != "" and String.valid?(bytes) and policy_digest(bytes) == expected do
      {:ok, %{"path" => path, "scope" => Path.dirname(path), "source" => "host-pinned", "sha256" => expected, "text" => bytes}}
    else
      _ -> {:error, :governance_external_policy_pin_rejected}
    end
  end

  defp repository_policies(context, names) do
    with {raw, 0} <- GovernanceTrustedGit.run(context.workspace, ["ls-tree", "-r", "-z", context.sha]),
         entries = String.split(raw, <<0>>, trim: true),
         {:ok, policies} <- parse_policy_tree(entries, names),
         {:ok, policies} <- nonempty_policy_blobs(context.workspace, policies),
         :ok <- reject_untracked_policies(context.workspace, names) do
      selected = policies |> Enum.group_by(&Path.dirname(&1.path)) |> Enum.sort_by(fn {directory, _} -> {length(Path.split(directory)), directory} end)
      paths = Enum.map(selected, fn {_, files} -> Enum.min_by(files, &policy_priority(&1, names)) end)
      policy_entries(paths, &repository_policy(context, &1))
    else
      _ -> {:error, :governance_repository_policy_inventory_rejected}
    end
  end

  defp nonempty_policy_blobs(workspace, policies) do
    Enum.reduce_while(policies, {:ok, []}, fn policy, {:ok, acc} ->
      case GovernanceTrustedGit.run(workspace, ["cat-file", "blob", policy.oid]) do
        {"", 0} -> {:cont, {:ok, acc}}
        {_, 0} -> {:cont, {:ok, [policy | acc]}}
        _ -> {:halt, {:error, :governance_policy_blob_unavailable}}
      end
    end)
  end

  defp reject_untracked_policies(workspace, names) do
    scopes = names ++ Enum.map(names, &Path.join("elixir", &1)) ++ ["elixir/lib", "elixir/test"]

    Enum.reduce_while([[], ["--ignored"]], :ok, fn flags, :ok ->
      workspace
      |> GovernanceTrustedGit.run(["ls-files", "--others", "--exclude-standard", "-z"] ++ flags ++ ["--" | scopes])
      |> untracked_policy_result(names)
    end)
  end

  defp policy_priority(policy, names), do: Enum.find_index(names, &(&1 == Path.basename(policy.path)))

  defp untracked_policy_result({raw, 0}, names) do
    if Enum.any?(String.split(raw, <<0>>, trim: true), &(Path.basename(&1) in names)), do: {:halt, {:error, :governance_untracked_policy_rejected}}, else: {:cont, :ok}
  end

  defp untracked_policy_result(_, _), do: {:halt, {:error, :governance_untracked_policy_inventory_failed}}

  defp parse_policy_tree(entries, names) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case String.split(entry, "\t", parts: 2) do
        [metadata, path] -> parse_policy_entry(metadata, path, names, acc)
        _ -> {:halt, {:error, :governance_policy_tree_malformed}}
      end
    end)
  end

  defp parse_policy_entry(metadata, path, names, acc) do
    if Path.basename(path) in names do
      case String.split(metadata, " ") do
        [mode, "blob", oid] when mode in ["100644", "100755"] -> {:cont, {:ok, [%{path: path, oid: oid} | acc]}}
        _ -> {:halt, {:error, :governance_policy_file_kind_rejected}}
      end
    else
      {:cont, {:ok, acc}}
    end
  end

  defp repository_policy(context, %{path: path, oid: oid}) do
    absolute = Path.join(context.workspace, path)

    with {bytes, 0} <- GovernanceTrustedGit.run(context.workspace, ["cat-file", "blob", oid]),
         true <- bytes != "" and String.valid?(bytes),
         {:ok, ^absolute} <- PathSafety.canonicalize(absolute),
         {:ok, %{type: :regular, links: 1}} <- File.lstat(absolute),
         {:ok, ^bytes} <- File.read(absolute) do
      {:ok, %{"path" => path, "scope" => Path.dirname(path), "source" => "git:" <> context.sha, "scopeKind" => "repository-subtree", "sha256" => policy_digest(bytes), "text" => bytes}}
    else
      _ -> {:error, :governance_repository_policy_drift}
    end
  end

  defp policy_entries(paths, load) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, entries} ->
      case load.(path) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp policy_scope_instructions(workspace) do
    """
    Original policy scope rules for exact source workspace: #{workspace}
    GLOBAL applies to every operation of this worker, including source paths outside CODEX_HOME.
    A policy file location is provenance, not a restriction of global scope.
    Repository subtree scopes are paths relative to this exact Git workspace.
    For an operation on a source path, apply only repository scopes that are ancestors of that path;
    a sibling subtree policy never applies globally or overrides another subtree.
    Closer applicable repository scopes follow ancestor scopes.
    bos-host-ancestor entries are additional, explicitly pinned BOS guards from recorded absolute ancestor scopes.
    They apply only to this governed source workspace under those ancestors; they are not native Codex discovery
    and are not Git policy objects of this candidate. They do not replace exact-candidate repository policies.
    No policy expands host permissions or authorizes another project.

    """
  end

  defp policy_message(entry) do
    "# Original governed policy: " <>
      entry["path"] <>
      "\nScope: " <>
      entry["scope"] <>
      "\nScope kind: " <> entry["scopeKind"] <> "\nSource: " <> entry["source"] <> "\nSHA-256: " <> entry["sha256"] <> "\n\n" <> entry["text"]
  end

  defp policy_digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
