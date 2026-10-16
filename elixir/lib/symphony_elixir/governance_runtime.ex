defmodule SymphonyElixir.GovernanceRuntime do
  @moduledoc "Pinned native runtime and an empty, read-only worker cwd; original source stays behind host tools."
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.PathSafety

  @hook_events ~w(Interrupt PermissionRequest PostCompact PostToolUse PreCompact PreToolUse SessionEnd SessionStart Stop SubagentStart SubagentStop UserPromptSubmit)
  @proof_checks ~w(outsideRead secretRead symlinkEscapeRead procRootEscapeRead workspaceWrite authEnvVisible outerHostProcOpen networkConnect)

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(configuration) do
    with {:ok, _} <-
           GovernanceBuildReceipt.verify(
             configuration.package_root,
             configuration.receipt_path,
             configuration.receipt_sha256
           ),
         true <- GovernanceBuildReceipt.file_digest(configuration.executable) == configuration.executable_sha256,
         true <-
           GovernanceBuildReceipt.file_digest(Path.join(configuration.auth_home, "config.toml")) ==
             configuration.native_config_sha256,
         true <-
           is_list(configuration.disabled_mcp_servers) and
             Enum.all?(configuration.disabled_mcp_servers, &(is_binary(&1) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))),
         {:ok, report_bytes} <- File.read(configuration.proof_path),
         true <- digest(report_bytes) == configuration.proof_sha256,
         {:ok, proof} <- Jason.decode(report_bytes),
         true <-
           proof["candidate"] == configuration.executable and proof["realToolIsolationPassed"] == true and
             proof["processReaped"] == true,
         [checks] <- proof["canaryResults"],
         true <- checks["allowedRead"] == true and Enum.all?(@proof_checks, &(checks[&1] == false)) do
      :ok
    else
      _ -> {:error, :governance_runtime_proof_rejected}
    end
  rescue
    _ -> {:error, :governance_runtime_proof_rejected}
  end

  @spec launch(map(), map(), String.t(), map()) ::
          {:ok, %{workspace: String.t(), managed: map(), thread_parameters: map()}} | {:error, atom()}
  def launch(configuration, context, role, policy) do
    with :ok <- validate(configuration),
         {:ok, directory, profile, permission} <- worker(configuration, context, role, policy) do
      overrides = %{
        "permissions" => %{permission => profile},
        "default_permissions" => permission,
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

      overrides = primary_policy_overrides(overrides, permission)
      arguments = startup_arguments(configuration)
      arguments = Enum.drop(arguments, -1) ++ ["-c", "project_doc_max_bytes=0", "-c", "project_doc_fallback_filenames=[]", "app-server"]

      managed = %{
        executable: configuration.executable,
        arguments: arguments,
        permissions: permission,
        allowed_workspace_roots: [directory],
        environment: %{
          "PATH" => "/usr/bin:/bin",
          "HOME" => Path.dirname(configuration.auth_home),
          "CODEX_HOME" => configuration.auth_home,
          "LANG" => "C.UTF-8"
        }
      }

      {:ok,
       %{
         workspace: directory,
         managed: managed,
         thread_parameters: %{
           "permissions" => permission,
           "config" => overrides,
           "ephemeral" => true,
           "selectedCapabilityRoots" => []
         }
       }}
    else
      true -> {:error, :governance_private_runtime_inside_agent_workspace}
      false -> {:error, :governance_workspace_write_runtime_not_certified}
      _ -> {:error, :governance_runtime_worker_rejected}
    end
  end

  defp primary_policy_overrides(overrides, _),
    do: overrides |> Map.put("project_doc_max_bytes", 0) |> Map.put("project_doc_fallback_filenames", [])

  @spec primary_recipe_sha256() :: String.t()
  def primary_recipe_sha256 do
    digest(
      CanonicalJson.encode(%{
        version: 1,
        mode: "structured_read_only",
        documentBytes: 0,
        policy: "full-original-global-and-subtree-scopes+premodel-effective-readonly-fsync",
        sourceTools: "exact-candidate-git-only",
        nativeCommands: false,
        modelMcpWrites: false,
        hostApplicationRecipe: SymphonyElixir.GovernanceCandidatePublication.application_recipe_sha256()
      })
    )
  end

  @spec validate_primary(map()) :: :ok | {:error, atom()}
  def validate_primary(configuration) do
    with :ok <- validate(configuration),
         path when is_binary(path) <- configuration[:implementation_proof_path],
         expected when is_binary(expected) <- configuration[:implementation_proof_sha256],
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == expected,
         {:ok, proof} <- Jason.decode(bytes),
         :ok <- validate_primary_proof(configuration, proof),
         {:ok, _} <- dependencies(configuration) do
      :ok
    else
      _ -> {:error, :governance_readonly_primary_not_certified}
    end
  rescue
    _ -> {:error, :governance_readonly_primary_not_certified}
  end

  @spec validate_primary_proof(map(), map()) :: :ok | {:error, atom()}
  def validate_primary_proof(configuration, proof) do
    with true <- primary_proof_binding?(proof, configuration),
         {:ok, expiry, _} <- DateTime.from_iso8601(proof["expiresAt"]),
         true <- DateTime.compare(expiry, DateTime.utc_now()) == :gt,
         true <-
           Enum.all?(
             ~w(effectiveConfigVerified actualReadonlyScopeVerified originalPoliciesInjected originalGlobalScopeVerified structuredProposalReturned hostCasApplied processReaped noModelMcpWrites hostSourceGuardHeld singleUseJournalVerified),
             &(proof[&1] == true)
           ),
         true <- Enum.all?(~w(workspaceWrite networkConnect outsideRead secretRead policyWrite authEnvVisible), &(proof[&1] == false)) do
      :ok
    else
      _ -> {:error, :governance_readonly_primary_not_certified}
    end
  rescue
    _ -> {:error, :governance_readonly_primary_not_certified}
  end

  defp primary_proof_binding?(proof, configuration) do
    proof["mode"] == "structured_read_only" and proof["recipeSha256"] == primary_recipe_sha256() and
      proof["nativeExecutableSha256"] == configuration.executable_sha256 and
      proof["nativeConfigSha256"] == configuration.native_config_sha256 and
      proof["dependencyReceiptsSha256"] == digest(CanonicalJson.encode(configuration[:dependency_receipts] || []))
  end

  @spec validate_implementation(map()) :: :ok | {:error, atom()}
  def validate_implementation(configuration) do
    with path when is_binary(path) <- configuration[:implementation_proof_path],
         expected when is_binary(expected) <- configuration[:implementation_proof_sha256],
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == expected,
         {:ok, proof} <- Jason.decode(bytes),
         true <- proof["nativeExecutableSha256"] == configuration.executable_sha256,
         true <- proof["nativeConfigSha256"] == configuration.native_config_sha256,
         true <- proof["recipeSha256"] == SymphonyElixir.GovernanceWorkspaceProfile.recipe_sha256(),
         true <-
           proof["dependencyReceiptsSha256"] ==
             digest(CanonicalJson.encode(configuration[:dependency_receipts] || [])),
         true <- proof["effectiveConfigVerified"] == true and proof["processReaped"] == true,
         true <- proof["allowedRead"] == true and proof["workspaceWrite"] == true,
         true <- Enum.all?(SymphonyElixir.GovernanceWorkspaceProfile.required_denials(), &(proof[&1] == false)),
         {:ok, _} <- dependencies(configuration) do
      :ok
    else
      _ -> {:error, :governance_workspace_write_runtime_not_certified}
    end
  rescue
    _ -> {:error, :governance_workspace_write_runtime_not_certified}
  end

  @spec dependency_roots(map()) :: {:ok, [String.t()]} | {:error, atom()}
  def dependency_roots(configuration), do: dependencies(configuration)

  defp dependencies(configuration) do
    Enum.reduce_while(configuration[:dependency_receipts] || [], {:ok, []}, fn item, {:ok, roots} ->
      with %{"root" => root, "receiptPath" => path, "receiptSha256" => expected} <- item,
           {:ok, canonical} <- PathSafety.canonicalize(root),
           true <- canonical == Path.expand(root),
           true <-
             root != "/" and not inside?(configuration.auth_home, root) and not inside?(root, configuration.auth_home),
           {:ok, _} <- GovernanceBuildReceipt.verify(root, path, expected) do
        {:cont, {:ok, [root | roots]}}
      else
        _ -> {:halt, {:error, :governance_dependency_receipt_rejected}}
      end
    end)
  end

  defp worker(configuration, context, "task-orchestrator", %{sandbox: %{"type" => "workspaceWrite"}}) do
    with :ok <- validate_implementation(configuration),
         {:ok, roots} <- dependencies(configuration),
         {:ok, profile} <-
           SymphonyElixir.GovernanceWorkspaceProfile.build(context.workspace, configuration.vendor_root, roots) do
      {:ok, context.workspace, profile, "bos-implementation"}
    end
  end

  defp worker(configuration, context, role, %{sandbox: %{"type" => "readOnly"}}) do
    with {:ok, runtime_root} <- PathSafety.canonicalize(configuration.worker_root),
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
          ":workspace_roots" => %{
            "." => "read",
            ".env" => "deny",
            ".codex" => "deny",
            ".aws" => "deny",
            ".ssh" => "deny",
            ".bos-local" => "deny"
          }
        },
        "network" => %{"enabled" => false}
      }

      {:ok, directory, profile, "bos-review"}
    else
      _ -> {:error, :governance_runtime_worker_rejected}
    end
  end

  defp worker(_, _, _, _), do: {:error, :governance_workspace_write_runtime_not_certified}
  @doc false
  @spec startup_arguments(map()) :: [String.t()]
  def startup_arguments(configuration) do
    overrides = [
      {"mcp_servers",
       Map.new(
         configuration.disabled_mcp_servers,
         &{&1, %{"command" => "/usr/bin/false", "args" => [], "env" => %{}, "enabled" => false}}
       )},
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

    overrides = overrides ++ Enum.map(@hook_events, &{"hooks." <> &1, []})

    Enum.flat_map(overrides, fn {key, value} -> ["-c", key <> "=" <> toml(value)] end) ++ ["app-server"]
  end

  @doc false
  @spec permission_arguments(map(), String.t()) :: [String.t()]
  def permission_arguments(profile, name) when name in ["bos-review", "bos-implementation", "bos-qa"] do
    ["-c", "permissions." <> name <> "=" <> toml(profile), "-c", "default_permissions=" <> Jason.encode!(name)]
  end

  defp toml(value) when is_map(value),
    do: "{" <> Enum.map_join(value, ",", fn {key, nested} -> Jason.encode!(key) <> "=" <> toml(nested) end) <> "}"

  defp toml(value), do: Jason.encode!(value)

  defp worker_name(context, role),
    do: digest(Jason.encode!([context.issue.native_ref["repositoryId"], context.issue.native_ref["runId"], role]))

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp inside?(path, root), do: path == Path.expand(root) or String.starts_with?(path, Path.expand(root) <> "/")
end
