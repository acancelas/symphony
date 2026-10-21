defmodule SymphonyElixir.GovernanceNativeCommandTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceNativeCommand, as: QA

  defp fixture do
    runtime = %{
      executable_sha256: String.duplicate("1", 64),
      native_config_sha256: String.duplicate("2", 64),
      dependency_receipts: []
    }

    checks =
      Map.new(QA.required_denials(), &{&1, false})
      |> Map.merge(Map.new(~w(allowedRead qaOutputWrite qaReadonlyAliasRead workerLoopback ownProcRead), &{&1, true}))
      |> Map.merge(%{"networkInterfaces" => ["lo"], "hostProxyConnect" => %{}})

    proof = %{
      "qaRecipeSha256" => QA.recipe_sha256(),
      "nativeExecutableSha256" => runtime.executable_sha256,
      "nativeConfigSha256" => runtime.native_config_sha256,
      "dependencyReceiptsSha256" => Base.encode16(:crypto.hash(:sha256, CanonicalJson.encode([])), case: :lower),
      "expiresAt" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      "processReaped" => true,
      "syntheticChecksPassed" => true,
      "checks" => checks
    }

    {runtime, proof}
  end

  test "exact current QA proof accepts only observed denials and isolated loopback" do
    {runtime, proof} = fixture()
    assert :ok = QA.validate_proof(runtime, proof)

    for key <- ~w(workspaceWrite outerHostProcOpen procAncestorSecretVisible networkConnect) do
      assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(runtime, put_in(proof, ["checks", key], true))
      assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(runtime, update_in(proof, ["checks"], &Map.delete(&1, key)))
    end

    proxy = put_in(proof, ["checks", "hostProxyConnect"], %{"synthetic" => true})
    assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(runtime, proxy)
    assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(runtime, put_in(proof, ["checks", "networkInterfaces"], ["lo", "eth0"]))
  end

  test "old recipe, expired proof, substituted dependencies and unreaped process fail closed" do
    {runtime, proof} = fixture()

    for bad <- [
          Map.put(proof, "qaRecipeSha256", "old-workspace-write-proof"),
          Map.put(proof, "expiresAt", "2000-01-01T00:00:00Z"),
          Map.put(proof, "processReaped", false),
          Map.put(proof, "nativeExecutableSha256", "changed"),
          Map.delete(proof, "expiresAt")
        ] do
      assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(runtime, bad)
    end

    changed = %{runtime | dependency_receipts: [%{"changed" => true}]}
    assert {:error, :governance_qa_profile_unverified} = QA.validate_proof(changed, proof)
    assert {:error, :governance_qa_profile_unverified} = QA.preflight(%{})
  end
end
