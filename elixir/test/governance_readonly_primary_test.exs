defmodule SymphonyElixir.GovernanceReadonlyPrimaryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceCandidatePublication, as: Publication
  alias SymphonyElixir.GovernanceRuntime, as: Runtime
  alias SymphonyElixir.GovernanceSession

  test "primary and repairs share RO native permissions without removing execution admission" do
    policy = GovernanceSession.implementation_policy()
    assert policy.sandbox == %{"type" => "readOnly", "networkAccess" => false}
    assert policy.execution_scope == :implementation and policy.proposal_mode == :structured
    assert policy.tools == [] and policy.native_operations == [:read]
    schema = Publication.proposal_schema()
    refute schema["additionalProperties"]
    assert schema["required"] == ~w(candidateCommitSha planHash changes)
    assert schema["properties"]["changes"]["maxItems"] == 100
  end

  test "RO primary proof cannot borrow a write canary or omit actual policy/CAS/custody observations" do
    runtime = %{
      executable_sha256: String.duplicate("1", 64),
      native_config_sha256: String.duplicate("2", 64),
      dependency_receipts: []
    }

    proof =
      Map.new(
        ~w(effectiveConfigVerified actualReadonlyScopeVerified originalPoliciesInjected originalGlobalScopeVerified structuredProposalReturned hostCasApplied processReaped noModelMcpWrites hostSourceGuardHeld singleUseJournalVerified),
        &{&1, true}
      )
      |> Map.merge(Map.new(~w(workspaceWrite networkConnect outsideRead secretRead policyWrite authEnvVisible), &{&1, false}))
      |> Map.merge(%{
        "mode" => "structured_read_only",
        "recipeSha256" => Runtime.primary_recipe_sha256(),
        "nativeExecutableSha256" => runtime.executable_sha256,
        "nativeConfigSha256" => runtime.native_config_sha256,
        "dependencyReceiptsSha256" => Base.encode16(:crypto.hash(:sha256, CanonicalJson.encode([])), case: :lower),
        "expiresAt" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
      })

    assert :ok = Runtime.validate_primary_proof(runtime, proof)

    for bad <- [
          Map.put(proof, "workspaceWrite", true),
          Map.put(proof, "mode", "workspaceWrite"),
          Map.delete(proof, "originalGlobalScopeVerified"),
          Map.put(proof, "hostCasApplied", false),
          Map.put(proof, "nativeConfigSha256", "other"),
          Map.put(proof, "expiresAt", "2000-01-01T00:00:00Z")
        ] do
      assert {:error, _} = Runtime.validate_primary_proof(runtime, bad)
    end

    assert {:error, _} = Runtime.validate_primary(%{})
  end
end
