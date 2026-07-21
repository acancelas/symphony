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

    def run_turn(%{actor: "pull-request-readiness-coordinator", workspace: workspace}, _prompt, _issue, _opts) do
      path = Path.join(workspace, ".bos-local/pull-request-readiness.json")
      intent = path |> File.read!() |> Jason.decode!()
      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:role, "pull-request-readiness-coordinator"})

      case Application.get_env(:symphony_elixir, :readiness_test_mode, :confirm) do
        :confirm ->
          confirm_readiness(path, intent)
          {:ok, %{session_id: "pull-request-readiness-coordinator"}}

        {:response_loss, state} ->
          Agent.get_and_update(state, fn
            :draft ->
              send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:provider_mutation, intent["operationId"]})
              {{:error, :response_lost}, :ready}

            :ready ->
              confirm_readiness(path, intent)
              {{:ok, %{session_id: "pull-request-readiness-coordinator"}}, :ready}
          end)

        {:reject, kind} ->
          rejected =
            intent
            |> Map.put("status", "rejected")
            |> Map.put("failureKind", kind)
            |> Map.put("failure", %{"code" => kind})

          File.write!(path, Jason.encode!(rejected))
          {:ok, %{session_id: "pull-request-readiness-coordinator"}}
      end
    end

    def run_turn(%{actor: actor}, _prompt, _issue, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:role, actor})
      {:ok, %{session_id: actor}}
    end

    def stop_session(_session), do: :ok

    defp confirm_readiness(path, intent) do
      confirmed =
        intent
        |> Map.put("status", "confirmed")
        |> Map.put("pullRequest", %{
          "number" => intent["pullRequestNumber"],
          "headSha" => intent["expectedHeadSha"],
          "state" => "open",
          "draft" => false
        })
        |> Map.put("receipt", %{"receiptId" => "ready_receipt_001"})

      File.write!(path, Jason.encode!(confirmed))
    end
  end

  defmodule FakeClient do
    def record_runtime_probe(request) do
      send(Application.fetch_env!(:symphony_elixir, :post_approval_test_pid), {:probe, request})
      {:ok, %{"status" => "completed", "receipt" => %{"receiptId" => "receipt_001"}}}
    end

    def fetch_issue("bos-front", 42), do: {:ok, %{"labels" => ["bos:issue", "agent:done"]}}

    def fetch_run("bos-front", "run_001") do
      {:ok,
       %{
         "status" => "completed",
         "currentAttemptId" => "attempt_002",
         "headCommit" => "a1b2c3d4",
         "pullRequestNumber" => 17
       }}
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

    assert_receive {:role, "pull-request-readiness-coordinator"}
    assert_receive {:role, "deployment-verifier"}
    assert_receive {:probe, request}
    assert request["repository"]["owner"] == "acancelas"
    assert request["probe"]["commitSha"] == "a1b2c3d4"
    assert_receive {:role, "release-manager"}

    Application.delete_env(:symphony_elixir, :post_approval_test_pid)
    Application.delete_env(:symphony_elixir, :readiness_test_mode)
    File.rm_rf!(workspace)
  end

  test "restart after remote readiness acceptance reuses the operation without a duplicate mutation" do
    workspace = temporary_workspace()
    Application.put_env(:symphony_elixir, :post_approval_test_pid, self())
    {:ok, remote_state} = Agent.start_link(fn -> :draft end)
    Application.put_env(:symphony_elixir, :readiness_test_mode, {:response_loss, remote_state})
    opts = [app_server_module: FakeAppServer, game_api_client_module: FakeClient]

    assert {:error, :response_lost} = PostApprovalCoordinator.run(workspace, issue(), nil, opts, nil)
    assert_receive {:provider_mutation, operation_id}

    handoff = workspace |> readiness_path() |> File.read!() |> Jason.decode!()
    assert handoff["status"] == "pending"
    assert handoff["operationId"] == operation_id

    assert :ok = PostApprovalCoordinator.run(workspace, issue(), nil, opts, nil)
    refute_receive {:provider_mutation, _}
    assert Agent.get(remote_state, & &1) == :ready

    confirmed = workspace |> readiness_path() |> File.read!() |> Jason.decode!()
    assert confirmed["status"] == "confirmed"
    assert confirmed["operationId"] == operation_id

    cleanup(workspace)
  end

  test "stale HEAD is a bounded readiness rejection and merge role never starts" do
    workspace = temporary_workspace()
    Application.put_env(:symphony_elixir, :post_approval_test_pid, self())
    Application.put_env(:symphony_elixir, :readiness_test_mode, {:reject, "stale_head"})

    assert {:error, {:pull_request_readiness_rejected, "stale_head", %{"code" => "stale_head"}}} =
             PostApprovalCoordinator.run(
               workspace,
               issue(),
               nil,
               [app_server_module: FakeAppServer, game_api_client_module: FakeClient],
               nil
             )

    refute_receive {:role, "deployment-verifier"}
    refute_receive {:probe, _}
    cleanup(workspace)
  end

  test "closed PR and provider failures remain distinct bounded states" do
    for kind <- ["closed_pull_request", "provider_failure"] do
      workspace = temporary_workspace()
      Application.put_env(:symphony_elixir, :post_approval_test_pid, self())
      Application.put_env(:symphony_elixir, :readiness_test_mode, {:reject, kind})

      assert {:error, {:pull_request_readiness_rejected, ^kind, %{"code" => ^kind}}} =
               PostApprovalCoordinator.run(
                 workspace,
                 issue(),
                 nil,
                 [app_server_module: FakeAppServer, game_api_client_module: FakeClient],
                 nil
               )

      cleanup(workspace)
    end
  end

  defp temporary_workspace do
    workspace = Path.join(System.tmp_dir!(), "bos-post-approval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp readiness_path(workspace), do: Path.join(workspace, ".bos-local/pull-request-readiness.json")

  defp cleanup(workspace) do
    Application.delete_env(:symphony_elixir, :post_approval_test_pid)
    Application.delete_env(:symphony_elixir, :readiness_test_mode)
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
