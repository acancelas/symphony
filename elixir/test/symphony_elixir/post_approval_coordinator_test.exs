defmodule SymphonyElixir.PostApprovalCoordinatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PostApprovalCoordinator
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    def start_session(workspace, opts) do
      actor = opts |> Keyword.fetch!(:environment_overrides) |> Map.new() |> Map.fetch!("BOS_MCP_ACTOR")
      {:ok, %{actor: actor, workspace: workspace}}
    end

    def run_turn(%{actor: "deployment-verifier", workspace: workspace}, _prompt, _issue, _opts) do
      path = Path.join(workspace, ".bos-local/deployment-probe.json")
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "probeId" => "probe_001",
          "deploymentId" => "deployment_001",
          "repositoryId" => "bos-front",
          "commitSha" => "a1b2c3d4",
          "environment" => "production",
          "status" => "passed"
        })
      )

      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:role, "deployment-verifier"})
      {:ok, %{session_id: "deployment-verifier"}}
    end

    def run_turn(%{actor: actor}, _prompt, _issue, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:role, actor})
      {:ok, %{session_id: actor}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule FakeClient do
    def record_runtime_probe(request) do
      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:probe, request})
      {:ok, %{"status" => "completed", "receipt" => %{"receiptId" => "receipt_001"}}}
    end

    def fetch_issue("bos-front", 42), do: {:ok, %{"labels" => ["bos:issue", "agent:done"]}}

    def fetch_run("bos-front", "run_001") do
      {:ok, %{"status" => "completed", "currentAttemptId" => "attempt_002"}}
    end

    def fetch_run_artifacts("bos-front", "run_001", "deployment-verifications") do
      {:ok,
       [
         %{
           "status" => "passed",
           "deploymentId" => "deployment_001",
           "commitSha" => "a1b2c3d4",
           "environment" => "production"
         }
       ]}
    end

    def fetch_run_artifacts("bos-front", "run_001", "attempts") do
      {:ok,
       [
         %{
           "attemptId" => "attempt_002",
           "status" => "passed",
           "completedAt" => "2026-07-20T12:00:00Z"
         }
       ]}
    end

    def fetch_run_artifacts("bos-front", "run_001", "learnings") do
      {:ok, [%{"learningId" => "learning_001"}]}
    end
  end

  test "runner confirms the bounded probe handoff between deploy and release roles" do
    workspace = Path.join(System.tmp_dir!(), "bos-post-approval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :post_approval_test_pid, self())

    assert :ok =
             PostApprovalCoordinator.run(
               workspace,
               issue(),
               nil,
               [app_server_module: FakeAppServer, game_api_client_module: FakeClient],
               nil
             )

    assert_receive {:role, "deployment-verifier"}
    assert_receive {:probe, request}
    assert request["repository"]["owner"] == "acancelas"
    assert request["probe"]["commitSha"] == "a1b2c3d4"
    assert_receive {:role, "release-manager"}

    Application.delete_env(:symphony_elixir, :post_approval_test_pid)
    File.rm_rf!(workspace)
  end

  defp issue do
    %Issue{
      id: "bos-front#42",
      identifier: "bos-front-42",
      title: "Release",
      state: "agent:merging",
      branch_name: "bos/issue-42",
      native_ref: %{
        "repositoryId" => "bos-front",
        "repositoryOwner" => "acancelas",
        "repositoryName" => "bos-front",
        "issueNumber" => 42,
        "runId" => "run_001",
        "attemptId" => "attempt_002"
      }
    }
  end
end
