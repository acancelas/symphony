defmodule SymphonyElixir.GovernanceToolBoundaryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{GovernanceCatalog, GovernanceToolBoundary}

  @repository %{"repositoryId" => "game-api", "owner" => "acancelas", "repo" => "game-api"}

  defp source do
    %{
      "governanceIdentity" => %{
        "verified" => true,
        "authenticatedBy" => "bos-host-hmac-v2",
        "serviceSubject" => "one-service",
        "actorSubjectId" => "host-invocation:one",
        "logicalRole" => "security",
        "invocationId" => "inv_one",
        "repository" => @repository,
        "permissions" => ["bos:delivery", "bos:governance:review"],
        "readOnly" => true,
        "catalogCommitSha" => GovernanceCatalog.commit(),
        "bindingDigest" => "sha256:" <> String.duplicate("a", 64),
        "isolation" => "read-only-worker",
        "attestationScope" => %{"runId" => "run_536"}
      }
    }
  end

  test "effective identity needs explicitly trusted server authentication and exact role rights" do
    assert {:error, _} = GovernanceToolBoundary.identity(source(), @repository, "security")
    assert {:ok, principal} = GovernanceToolBoundary.identity(source(), @repository, "security", ["bos-host-hmac-v2"])
    assert principal.service_id == "one-service"
    assert principal.subject_id == "host-invocation:one"

    for changed <- [
          put_in(source(), ["governanceIdentity", "verified"], false),
          put_in(source(), ["governanceIdentity", "readOnly"], false),
          put_in(source(), ["governanceIdentity", "permissions"], ["bos:delivery", "bos:governance:review", "bos:admin"])
        ] do
      assert {:error, _} = GovernanceToolBoundary.identity(changed, @repository, "security", ["bos-host-hmac-v2"])
    end
  end

  test "host boundary rejects cross-scope, production and wrong candidate before transport" do
    context = %{issue: %{native_ref: %{"issueNumber" => 536, "runId" => "run_536"}}, sha: String.duplicate("a", 40), principal: %{subject_id: "logical-subject"}}

    for {tool, args} <- [
          {"bos_get_issue", %{"issueNumber" => 537}},
          {"bos_get_issue", %{"repositoryId" => "another"}},
          {"bos_create_deployment", %{}},
          {"bos_record_review", %{"artifact" => %{"commitSha" => String.duplicate("b", 40)}}}
        ] do
      assert {:error, _} = GovernanceToolBoundary.arguments(tool, args, context, [tool])
    end

    assert {:ok, %{"artifact" => %{"actor" => %{"subjectId" => "logical-subject"}}}} =
             GovernanceToolBoundary.arguments("bos_record_review", %{"artifact" => %{}}, context, ["bos_record_review"])
  end

  test "MCP failures and credential fields never become successful model output" do
    assert {:error, _} = GovernanceToolBoundary.decode_result(%{"isError" => true, "content" => []})
    assert %{"nested" => [%{"authorization" => "[REDACTED]"}]} = GovernanceToolBoundary.safe_output(%{"nested" => [%{"authorization" => "synthetic-secret"}]})
  end
end
