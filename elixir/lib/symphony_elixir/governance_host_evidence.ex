defmodule SymphonyElixir.GovernanceHostEvidence do
  @moduledoc "Fixed host observations, never model claims or repository script output."
  alias SymphonyElixir.{GovernanceHostStore, GovernanceRuntime, GovernanceReservation, GovernanceBuildReceipt, GovernanceWorkspaceProfile}
  @recipe "host-environment-v1:clean-git+exact-dossier+lease+HMAC-epoch+sealed-builds+real-profile-proof"
  def recipe_sha256, do: digest(@recipe)

  def observe(context, configuration, source, run) do
    with execution when is_map(execution) <- configuration[:execution],
         true <- get_in(source, ["governanceIdentity", "verified"]) == true,
         true <- get_in(source, ["governanceIdentity", "authenticatedBy"]) == "bos-host-hmac-v2",
         epoch when is_binary(epoch) and byte_size(epoch) > 0 <- get_in(source, ["governance", "developmentExecution", "epoch"]),
         :ok <- GovernanceReservation.verify(context, run, source),
         {head, 0} <- git(context.workspace, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == context.sha,
         {"", 0} <- git(context.workspace, ["status", "--porcelain", "--untracked-files=all"]),
         {branch, 0} <- git(context.workspace, ["symbolic-ref", "--short", "HEAD"]),
         true <- String.trim(branch) == run["branch"],
         {:ok, plan} <- File.read(Path.join(context.workspace, "docs/issues/#{context.issue.native_ref["issueNumber"]}/plan.md")),
         true <- "sha256:" <> digest(plan) == context.manifest["planHash"],
         true <- get_in(source, ["governance", "requirementDefinition", "currentDigest"]) == context.manifest["definitionDigest"],
         :ok <- GovernanceRuntime.validate(configuration.runtime),
         :ok <- GovernanceRuntime.validate_implementation(configuration.runtime),
         {:ok, _} <- GovernanceBuildReceipt.verify(configuration.mcp.build_root, configuration.mcp.receipt_path, configuration.mcp.receipt_sha256),
         {:ok, _} <- GovernanceWorkspaceProfile.build(context.workspace, configuration.runtime.vendor_root) do
      observation = %{
        "recipeSha256" => recipe_sha256(),
        "repositoryId" => context.issue.native_ref["repositoryId"],
        "issueNumber" => context.issue.native_ref["issueNumber"],
        "runId" => context.issue.native_ref["runId"],
        "candidateCommitSha" => context.sha,
        "planHash" => context.manifest["planHash"],
        "definitionDigest" => context.manifest["definitionDigest"],
        "catalogCommitSha" => context.manifest["catalogCommitSha"],
        "epoch" => epoch,
        "observedAt" => DateTime.to_iso8601(DateTime.utc_now()),
        "claim" => Map.take(source["claim"], ~w(runId runnerId leaseExpiresAt)),
        "pins" => %{
          "mcpReceipt" => configuration.mcp.receipt_sha256,
          "nativeExecutable" => configuration.runtime.executable_sha256,
          "nativeConfig" => configuration.runtime.native_config_sha256,
          "readOnlyProof" => configuration.runtime.proof_sha256,
          "implementationProof" => configuration.runtime.implementation_proof_sha256,
          "profileRecipe" => GovernanceWorkspaceProfile.recipe_sha256()
        }
      }

      id = digest(SymphonyElixir.Audit.CanonicalJson.encode(observation))

      with {:ok, _} <- GovernanceHostStore.request(execution, %{"kind" => "observation", "command" => "create", "id" => id, "record" => observation}) do
        artifact = %{
          "evidenceId" => "host_environment_" <> id,
          "runId" => context.issue.native_ref["runId"],
          "commitSha" => context.sha,
          "phase" => "readiness",
          "status" => "passed",
          "acceptanceCriteria" => [%{"id" => "environment", "name" => "Host-observed exact-candidate local execution environment", "status" => "passed", "verified" => true}],
          "checks" => [%{"id" => "environment", "kind" => "environment", "status" => "passed", "verified" => true, "environment" => "local", "commands" => [@recipe]}],
          "artifacts" => [%{"kind" => "host_environment_observation", "sha256" => id, "recipeSha256" => recipe_sha256(), "epoch" => epoch, "observedAt" => observation["observedAt"]}],
          "summary" => "Host observed fixed Git/dossier/lease/HMAC-epoch/build/profile checks. No repository script executed on the privileged host; no implementation acceptance asserted."
        }

        {:ok, artifact}
      end
    else
      _ -> {:error, :governance_host_environment_unverified}
    end
  rescue
    _ -> {:error, :governance_host_environment_unverified}
  end

  defp git(workspace, args), do: SymphonyElixir.GovernanceTrustedGit.run(workspace, args)
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
