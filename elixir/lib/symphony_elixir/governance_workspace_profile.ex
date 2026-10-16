defmodule SymphonyElixir.GovernanceWorkspaceProfile do
  @moduledoc "One host-owned profile recipe; executable proof must cover this exact recipe."
  @secret ~w(.git .codex .bos-local .aws .ssh .npmrc .pypirc auth.json credentials.json secrets.json id_rsa id_ed25519)
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
    ".bos" => "read",
    "WORKFLOW.md" => "read",
    "GOVERNANCE.md" => "read",
    "docs/issues" => "read"
  }
  @checks ~w(outsideRead outsideWrite secretRead nestedSecretRead deepSecretRead symlinkEscapeRead symlinkEscapeWrite symlinkSecretRead symlinkSecretWrite symlinkPolicyRead symlinkPolicyWrite hardlinkProtectedWrite gitAdminWrite gitCommonDirWrite policyWrite agentsWrite nestedAgentsWrite originalPlanWrite manifestWrite hostPrivateRead hostPrivateWrite procRootEscapeRead outerHostProcOpen authEnvVisible networkConnect workerLoopback wslInterop)

  def recipe_sha256,
    do:
      digest(
        SymphonyElixir.Audit.CanonicalJson.encode(%{
          "version" => 1,
          "rules" => @rules,
          "globScanDepth" => 64,
          "requiredDenials" => @checks,
          "requiredPositives" => ~w(allowedRead workspaceWrite),
          "hardlinks" => "reject-at-launch",
          "writableSymlinks" => "reject-at-launch"
        })
      )

  def required_denials, do: @checks

  def build(workspace, vendor_root, dependency_roots \\ []) do
    with {:ok, root} <- SymphonyElixir.PathSafety.canonicalize(workspace),
         true <- root == Path.expand(workspace),
         {:ok, protected} <- audit(root, "", %{}, 0),
         true <- Enum.all?(dependency_roots, &(is_binary(&1) and Path.type(&1) == :absolute and not inside?(&1, root))) do
      rules = Map.merge(@rules, protected)

      filesystem =
        Map.merge(
          %{":root" => "deny", ":minimal" => "read", "/proc" => "deny", vendor_root => "read", "glob_scan_max_depth" => 64, ":workspace_roots" => rules},
          Map.new(dependency_roots, &{&1, "read"})
        )

      {:ok, %{"filesystem" => filesystem, "network" => %{"enabled" => false}}}
    else
      _ -> {:error, :governance_workspace_boundary_rejected}
    end
  end

  defp audit(root, relative, rules, depth) when depth <= 64 do
    with {:ok, names} <- File.ls(Path.join(root, relative)), true <- length(names) <= 20_000 do
      Enum.reduce_while(names, {:ok, rules}, fn name, {:ok, acc} ->
        path = Path.join(relative, name)

        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :symlink}} ->
            if Enum.any?(~w(elixir/lib elixir/test elixir/_build elixir/bin), &(path == &1 or String.starts_with?(path, &1 <> "/"))),
              do: {:halt, {:error, :governance_workspace_writable_symlink}},
              else: {:cont, {:ok, Map.put(acc, path, "deny")}}

          {:ok, %{type: :regular, links: links}} when links > 1 ->
            {:halt, {:error, :governance_workspace_hardlink}}

          {:ok, %{type: type}} ->
            cond do
              name in @secret or String.starts_with?(name, ".env") ->
                {:cont, {:ok, Map.put(acc, path, "deny")}}

              name == "AGENTS.md" ->
                {:cont, {:ok, Map.put(acc, path, "read")}}

              type == :directory ->
                case audit(root, path, acc, depth + 1) do
                  {:ok, next} -> {:cont, {:ok, next}}
                  error -> {:halt, error}
                end

              type == :regular ->
                {:cont, {:ok, acc}}

              true ->
                {:halt, {:error, :governance_workspace_special_file}}
            end

          _ ->
            {:halt, {:error, :governance_workspace_changed}}
        end
      end)
    else
      _ -> {:error, :governance_workspace_unreadable}
    end
  end

  defp audit(_, _, _, _), do: {:error, :governance_workspace_depth_exceeded}
  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
