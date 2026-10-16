defmodule SymphonyElixir.GovernanceWorkspaceProfile do
  alias SymphonyElixir.Audit.CanonicalJson
  @moduledoc "One host-owned profile recipe; executable proof must cover this exact recipe."
  @secret ~w(AGENTS.override.md .git .codex .bos-local .aws .ssh .npmrc .pypirc auth.json credentials.json secrets.json id_rsa id_ed25519)
  @rules %{
    "." => "read",
    "elixir/lib" => "write",
    "elixir/test" => "write",
    "elixir/_build" => "write",
    "elixir/bin" => "write",
    ".git" => "deny",
    ".codex" => "deny",
    ".bos-local" => "deny",
    ".aws" => "deny",
    ".ssh" => "deny",
    ".env" => "deny",
    ".env.*" => "deny",
    "**/.env" => "deny",
    "**/.env.*" => "deny",
    "AGENTS.md" => "read",
    "**/AGENTS.md" => "deny",
    "AGENTS.override.md" => "deny",
    "**/AGENTS.override.md" => "deny",
    ".bos" => "read",
    "WORKFLOW.md" => "read",
    "GOVERNANCE.md" => "read",
    "docs/issues" => "read"
  }
  @checks ~w(outsideRead outsideWrite secretRead nestedSecretRead deepSecretRead symlinkEscapeRead symlinkEscapeWrite symlinkSecretRead symlinkSecretWrite symlinkPolicyRead symlinkPolicyWrite hardlinkProtectedWrite gitAdminWrite gitCommonDirWrite policyWrite agentsWrite nestedAgentsWrite overrideAgentsWrite nestedOverrideAgentsWrite originalPlanWrite manifestWrite hostPrivateRead hostPrivateWrite procRootEscapeRead outerHostProcOpen authEnvVisible networkConnect workerLoopback wslInterop)

  @spec recipe_sha256() :: String.t()
  def recipe_sha256,
    do:
      digest(
        CanonicalJson.encode(%{
          "version" => 2,
          "rules" => @rules,
          "globScanDepth" => 64,
          "requiredDenials" => @checks,
          "requiredPositives" => ~w(allowedRead workspaceWrite),
          "hardlinks" => "reject-at-launch",
          "writableSymlinks" => "reject-at-launch"
        })
      )

  @spec required_denials() :: [String.t()]
  def required_denials, do: @checks

  @spec build(String.t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def build(workspace, vendor_root, dependency_roots \\ []),
    do: build_profile(workspace, vendor_root, dependency_roots, :implementation)

  @spec build_qa(String.t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def build_qa(workspace, vendor_root, dependency_roots),
    do: build_profile(workspace, vendor_root, dependency_roots, :qa)

  @spec qa_audit_recipe_sha256() :: String.t()
  def qa_audit_recipe_sha256 do
    digest(
      CanonicalJson.encode(%{
        parent: recipe_sha256(),
        version: 1,
        maskedOutputs: ~w(elixir/_build elixir/bin elixir/cover),
        condition: "only-real-directory-mountpoints-fully-overlaid-by-exclusive-empty-QA-cache"
      })
    )
  end

  defp build_profile(workspace, vendor_root, dependency_roots, mode) do
    with {:ok, root} <- SymphonyElixir.PathSafety.canonicalize(workspace),
         true <- root == Path.expand(workspace),
         {:ok, protected} <- audit(root, "", %{}, 0, mode),
         true <- Enum.all?(dependency_roots, &(is_binary(&1) and Path.type(&1) == :absolute and not inside?(&1, root))) do
      rules = Map.merge(@rules, protected)

      filesystem =
        Map.merge(
          %{
            ":root" => "deny",
            ":minimal" => "read",
            "/proc" => "deny",
            vendor_root => "read",
            "glob_scan_max_depth" => 64,
            ":workspace_roots" => rules
          },
          Map.new(dependency_roots, &{&1, "read"})
        )

      {:ok, %{"filesystem" => filesystem, "network" => %{"enabled" => false}}}
    else
      _ -> {:error, :governance_workspace_boundary_rejected}
    end
  end

  defp audit(root, relative, rules, depth, mode) when depth <= 64 do
    with {:ok, names} <- File.ls(Path.join(root, relative)), true <- length(names) <= 20_000 do
      Enum.reduce_while(names, {:ok, rules}, &audit_entry(root, relative, &1, &2, depth, mode))
    else
      _ -> {:error, :governance_workspace_unreadable}
    end
  end

  defp audit(_, _, _, _, _), do: {:error, :governance_workspace_depth_exceeded}

  defp audit_entry(root, relative, name, {:ok, rules}, depth, mode) do
    path = Path.join(relative, name)

    case File.lstat(Path.join(root, path)) do
      {:ok, %{type: :symlink}} ->
        audit_link(path, rules)

      {:ok, %{type: :regular, links: links}} when links > 1 ->
        {:halt, {:error, :governance_workspace_hardlink}}

      {:ok, %{type: type}} ->
        audit_kind(root, path, name, type, rules, depth, mode)

      _ ->
        {:halt, {:error, :governance_workspace_changed}}
    end
  end

  defp audit_link(path, rules) do
    writable = Enum.any?(~w(elixir/lib elixir/test elixir/_build elixir/bin), &inside?(path, &1))

    if writable,
      do: {:halt, {:error, :governance_workspace_writable_symlink}},
      else: {:cont, {:ok, Map.put(rules, path, "deny")}}
  end

  defp audit_kind(root, path, name, type, rules, depth, mode) do
    cond do
      name in @secret or String.starts_with?(name, ".env") ->
        {:cont, {:ok, Map.put(rules, path, "deny")}}

      name == "AGENTS.md" ->
        {:cont, {:ok, Map.put(rules, path, "read")}}

      masked_qa_output?(type, mode, path) ->
        {:cont, {:ok, rules}}

      type == :directory ->
        descend(root, path, rules, depth + 1, mode)

      type == :regular ->
        {:cont, {:ok, rules}}

      true ->
        {:halt, {:error, :governance_workspace_special_file}}
    end
  end

  defp masked_qa_output?(:directory, :qa, path), do: path in ~w(elixir/_build elixir/bin elixir/cover)
  defp masked_qa_output?(_, _, _), do: false

  defp descend(root, path, rules, depth, mode) do
    case audit(root, path, rules, depth, mode) do
      {:ok, next} -> {:cont, {:ok, next}}
      error -> {:halt, error}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
