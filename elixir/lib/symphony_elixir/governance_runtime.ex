defmodule SymphonyElixir.GovernanceRuntime do
  @moduledoc "Pinned native runtime and an empty, read-only worker cwd; original source stays behind host tools."
  alias SymphonyElixir.{GovernanceBuildReceipt, PathSafety}
  @hook_events ~w(Interrupt PermissionRequest PostCompact PostToolUse PreCompact PreToolUse SessionEnd SessionStart Stop SubagentStart SubagentStop UserPromptSubmit)
  @proof_checks ~w(outsideRead secretRead symlinkEscapeRead procRootEscapeRead workspaceWrite authEnvVisible outerHostProcOpen networkConnect)

  def validate(configuration) do
    with {:ok, _} <- GovernanceBuildReceipt.verify(configuration.package_root, configuration.receipt_path, configuration.receipt_sha256),
         true <- GovernanceBuildReceipt.file_digest(configuration.executable) == configuration.executable_sha256,
         true <- GovernanceBuildReceipt.file_digest(Path.join(configuration.auth_home, "config.toml")) == configuration.native_config_sha256,
         true <- is_list(configuration.disabled_mcp_servers) and Enum.all?(configuration.disabled_mcp_servers, &(is_binary(&1) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))),
         {:ok, report_bytes} <- File.read(configuration.proof_path),
         true <- digest(report_bytes) == configuration.proof_sha256,
         {:ok, proof} <- Jason.decode(report_bytes),
         true <- proof["candidate"] == configuration.executable and proof["realToolIsolationPassed"] == true and proof["processReaped"] == true,
         [checks] <- proof["canaryResults"],
         true <- checks["allowedRead"] == true and Enum.all?(@proof_checks, &(checks[&1] == false)) do
      :ok
    else
      _ -> {:error, :governance_runtime_proof_rejected}
    end
  rescue
    _ -> {:error, :governance_runtime_proof_rejected}
  end

  def launch(configuration, context, role, policy) do
    with :ok <- validate(configuration),
         true <- policy.sandbox["type"] == "readOnly",
         {:ok, runtime_root} <- PathSafety.canonicalize(configuration.worker_root),
         false <- inside?(runtime_root, context.workspace),
         directory = Path.join(runtime_root, worker_name(context, role)),
         :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, ^directory} <- PathSafety.canonicalize(directory),
         {:ok, []} <- File.ls(directory) do
      profile = %{
        "filesystem" => %{
          ":root" => "deny",
          ":minimal" => "read",
          "/proc" => "deny",
          configuration.vendor_root => "read",
          ":workspace_roots" => %{"." => "read", ".env" => "deny", ".codex" => "deny", ".aws" => "deny", ".ssh" => "deny", ".bos-local" => "deny"}
        },
        "network" => %{"enabled" => false}
      }

      overrides = %{
        "permissions" => %{"bos-review" => profile},
        "default_permissions" => "bos-review",
        "mcp_servers" => Map.new(configuration.disabled_mcp_servers, &{&1, %{"enabled" => false}}),
        "plugins" => %{},
        "hooks" => Map.new(@hook_events, &{&1, []}),
        "web_search" => "disabled",
        "shell_environment_policy" => %{"inherit" => "none"},
        "features.apps" => false,
        "features.plugins" => false,
        "features.multi_agent" => false,
        "features.shell_snapshot" => false,
        "features.workspace_dependencies" => false
      }

      managed = %{
        executable: configuration.executable,
        arguments: startup_arguments(configuration),
        permissions: "bos-review",
        allowed_workspace_roots: [directory],
        environment: %{
          "PATH" => "/usr/bin:/bin",
          "HOME" => Path.dirname(configuration.auth_home),
          "CODEX_HOME" => configuration.auth_home,
          "LANG" => "C.UTF-8"
        }
      }

      {:ok, %{workspace: directory, managed: managed, thread_parameters: %{"permissions" => "bos-review", "config" => overrides, "ephemeral" => true, "selectedCapabilityRoots" => []}}}
    else
      true -> {:error, :governance_private_runtime_inside_agent_workspace}
      false -> {:error, :governance_workspace_write_runtime_not_certified}
      _ -> {:error, :governance_runtime_worker_rejected}
    end
  end

  defp startup_arguments(configuration) do
    overrides = [
      {"mcp_servers", %{}},
      {"plugins", %{}},
      {"hooks", %{}},
      {"web_search", "disabled"},
      {"features.apps", false},
      {"features.plugins", false},
      {"features.multi_agent", false},
      {"features.shell_snapshot", false},
      {"features.workspace_dependencies", false},
      {"shell_environment_policy", %{"inherit" => "none"}}
    ]

    overrides = overrides ++ Enum.map(configuration.disabled_mcp_servers, &{"mcp_servers." <> &1 <> ".enabled", false}) ++ Enum.map(@hook_events, &{"hooks." <> &1, []})

    Enum.flat_map(overrides, fn {key, value} -> ["-c", key <> "=" <> toml(value)] end) ++ ["app-server"]
  end

  defp toml(value) when is_map(value), do: "{" <> Enum.map_join(value, ",", fn {key, nested} -> Jason.encode!(key) <> "=" <> toml(nested) end) <> "}"
  defp toml(value), do: Jason.encode!(value)

  defp worker_name(context, role), do: digest(Jason.encode!([context.issue.native_ref["repositoryId"], context.issue.native_ref["runId"], role]))
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp inside?(path, root), do: path == Path.expand(root) or String.starts_with?(path, Path.expand(root) <> "/")
end
