defmodule SymphonyElixir.GovernanceHostEvidence do
  @moduledoc "Fixed host observations, never model claims or repository script output."
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceBuildReceipt
  alias SymphonyElixir.GovernanceHostStore
  alias SymphonyElixir.GovernanceReservation
  alias SymphonyElixir.GovernanceRuntime

  @runtime_states ~w(attached running worker_stopped interrupted cancelled settled handoff charge_only)
  @doc "Build the existing strict runtime-observation envelope; never acceptance or a source of authority."
  @spec runtime_observation(map(), map(), map(), map(), String.t(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def runtime_observation(context, execution, witness, measurement, state, continuation \\ nil) do
    with true <- state in @runtime_states,
         true <- runtime_measurement?(measurement, state),
         {:ok, public_witness} <- runtime_witness(witness, state),
         true <- runtime_continuation?(continuation, state, context, execution) do
      observation = %{
        "kind" => "development_execution_observation",
        "reservationId" => execution.admission["reservationId"],
        "executionId" => execution.admission["executionId"],
        "workerId" => execution.admission["workerId"],
        "ownershipGeneration" => execution.ownership.generation,
        "authorityGeneration" => execution.admission["authorityGeneration"],
        "sequence" => measurement.sequence,
        "observedAt" => measurement.observedAt,
        "state" => state,
        "usage" => %{"uncachedInputTokens" => measurement.uncachedInputTokens, "wallTimeSeconds" => measurement.wallTimeSeconds},
        "processWitness" => public_witness
      }

      observation = if continuation, do: Map.put(observation, "continuation", continuation), else: observation
      observation = Map.put(observation, "proofDigest", "sha256:" <> digest(CanonicalJson.encode(observation)))
      id = "execution_observation_" <> digest(CanonicalJson.encode([execution.admission["executionId"], measurement.sequence, state]))

      {:ok,
       %{
         "evidenceId" => id,
         "runId" => context.issue.native_ref["runId"],
         "commitSha" => context.sha,
         "phase" => "implementation",
         "status" => "inconclusive",
         "acceptanceCriteria" => [%{"id" => "runtime_usage", "name" => "Host runtime observation", "status" => "inconclusive", "verified" => false}],
         "checks" => [],
         "artifacts" => [observation],
         "summary" => "Operational accounting from the host process witness and native token telemetry only."
       }}
    else
      _ -> {:error, :governance_runtime_observation_unverified}
    end
  rescue
    _ -> {:error, :governance_runtime_observation_unverified}
  end

  defp runtime_measurement?(measurement, state) when is_map(measurement) do
    Enum.all?(~w(sequence uncachedInputTokens wallTimeSeconds observedAt)a, &Map.has_key?(measurement, &1)) and
      is_integer(measurement.sequence) and measurement.sequence > 0 and
      match?({:ok, _, _}, DateTime.from_iso8601(measurement.observedAt)) and
      runtime_usage?(measurement.uncachedInputTokens, :tokens, state) and
      runtime_usage?(measurement.wallTimeSeconds, :seconds, state)
  end

  defp runtime_measurement?(_, _), do: false

  defp runtime_usage?(nil, _, state), do: state in ~w(charge_only interrupted cancelled)
  defp runtime_usage?(value, :tokens, _), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp runtime_usage?(value, :seconds, _), do: is_number(value) and value >= 0 and value <= 9_007_199_254_740_991

  defp runtime_witness(_witness, "charge_only"), do: {:ok, nil}

  defp runtime_witness(%{"pid" => pid, "startTicks" => ticks, "bootId" => boot_id, "marker" => marker} = witness, state)
       when is_integer(pid) and pid > 1 and is_binary(marker) do
    with {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         true <- String.trim(boot) == boot_id,
         {:ok, reaped} <- runtime_process_state(pid, ticks, state) do
      {:ok, witness |> Map.take(~w(pid startTicks bootId)) |> Map.put("markerDigest", digest(marker)) |> Map.put("processReaped", reaped)}
    else
      _ -> {:error, :governance_runtime_process_unverified}
    end
  end

  defp runtime_witness(_, _), do: {:error, :governance_runtime_process_unverified}

  defp runtime_process_state(pid, ticks, state) do
    case File.lstat("/proc/#{pid}") do
      {:error, :enoent} when state not in ~w(attached running) ->
        {:ok, true}

      {:ok, _} when state not in ~w(worker_stopped settled handoff) ->
        live_runtime_process(pid, ticks)

      _ ->
        {:error, :governance_runtime_process_not_reaped}
    end
  end

  defp live_runtime_process(pid, ticks) do
    case SymphonyElixir.GovernanceProcess.witness(pid, "not-exported") do
      {:ok, %{"startTicks" => ^ticks}} -> {:ok, false}
      _ -> {:error, :governance_runtime_process_reused}
    end
  end

  defp runtime_continuation?(nil, state, _, _), do: state != "handoff"

  defp runtime_continuation?(value, "handoff", context, execution) when is_map(value) do
    Enum.sort(Map.keys(value)) == ~w(candidateCommitSha invocationId nextOwnershipGeneration sourcePublicationId workerId) and
      value["nextOwnershipGeneration"] == execution.ownership.generation + 1 and
      value["invocationId"] != context.principal.invocation_id and
      runtime_continuation_ids?(value)
  end

  defp runtime_continuation?(_, _, _, _), do: false

  defp runtime_continuation_ids?(value) do
    Enum.all?(~w(invocationId sourcePublicationId workerId), fn key ->
      is_binary(value[key]) and Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, value[key])
    end) and is_binary(value["candidateCommitSha"]) and Regex.match?(~r/^[a-f0-9]{40}$/, value["candidateCommitSha"])
  end

  @recipe "host-environment-v2:clean-git+exact-dossier+lease+HMAC-epoch+sealed-builds+readonly-primary+separate-qa-proof"
  @spec recipe_sha256() :: String.t()
  def recipe_sha256, do: digest(@recipe)

  @spec observe(map(), map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def observe(context, configuration, source, run) do
    with execution when is_map(execution) <- configuration[:execution],
         true <- get_in(source, ["governanceIdentity", "verified"]) == true,
         true <- get_in(source, ["governanceIdentity", "authenticatedBy"]) == "bos-host-hmac-v2",
         epoch when is_binary(epoch) and byte_size(epoch) > 0 <-
           get_in(source, ["governance", "developmentExecution", "epoch"]),
         :ok <- GovernanceReservation.verify(context, run, source),
         {head, 0} <- git(context.workspace, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == context.sha,
         {"", 0} <- git(context.workspace, ["status", "--porcelain", "--untracked-files=all"]),
         {branch, 0} <- git(context.workspace, ["symbolic-ref", "--short", "HEAD"]),
         true <- String.trim(branch) == run["branch"],
         {:ok, plan} <-
           File.read(Path.join(context.workspace, "docs/issues/#{context.issue.native_ref["issueNumber"]}/plan.md")),
         true <- "sha256:" <> digest(plan) == context.manifest["planHash"],
         true <-
           get_in(source, ["governance", "requirementDefinition", "currentDigest"]) ==
             context.manifest["definitionDigest"],
         :ok <- GovernanceRuntime.validate(configuration.runtime),
         :ok <- GovernanceRuntime.validate_primary(configuration.runtime),
         :ok <- SymphonyElixir.GovernanceNativeCommand.preflight(configuration),
         {:ok, _} <-
           GovernanceBuildReceipt.verify(
             configuration.mcp.build_root,
             configuration.mcp.receipt_path,
             configuration.mcp.receipt_sha256
           ),
         {:ok, _} <- GovernanceRuntime.dependency_roots(configuration.runtime) do
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
          "profileRecipe" => GovernanceRuntime.primary_recipe_sha256(),
          "qaProfileProof" => configuration.runtime.qa_proof_sha256,
          "qaProfileRecipe" => SymphonyElixir.GovernanceNativeCommand.recipe_sha256()
        }
      }

      id = digest(CanonicalJson.encode(observation))

      with {:ok, _} <-
             GovernanceHostStore.request(execution, %{
               "kind" => "observation",
               "command" => "create",
               "id" => id,
               "record" => observation
             }) do
        artifact = %{
          "evidenceId" => "host_environment_" <> id,
          "runId" => context.issue.native_ref["runId"],
          "commitSha" => context.sha,
          "phase" => "readiness",
          "status" => "passed",
          "acceptanceCriteria" => [
            %{
              "id" => "environment",
              "name" => "Host-observed exact-candidate local execution environment",
              "status" => "passed",
              "verified" => true
            }
          ],
          "checks" => [
            %{
              "id" => "environment",
              "kind" => "environment",
              "status" => "passed",
              "verified" => true,
              "environment" => "local",
              "commands" => [@recipe]
            }
          ],
          "artifacts" => [
            %{
              "kind" => "host_environment_observation",
              "sha256" => id,
              "recipeSha256" => recipe_sha256(),
              "epoch" => epoch,
              "observedAt" => observation["observedAt"]
            }
          ],
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
