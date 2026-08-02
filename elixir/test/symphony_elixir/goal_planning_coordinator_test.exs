defmodule SymphonyElixir.GoalPlanningCoordinatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GoalPlanningCoordinator
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    def start_session(_workspace, opts) do
      actor = opts |> Keyword.fetch!(:environment_overrides) |> Map.new() |> Map.fetch!("BOS_MCP_ACTOR")
      send(Application.fetch_env!(:symphony_elixir, :goal_planning_test_pid), {:session_started, actor})
      {:ok, %{actor: actor}}
    end

    def run_turn(session, _prompt, _issue, _opts), do: {:ok, %{session_id: session.actor}}
    def stop_session(_session), do: :ok
  end

  defmodule FakeClient do
    def fetch_goal_planning(_repository_id, _issue_number) do
      {:ok,
       %{
         "proposal" => %{"operationId" => "proposal_001"},
         "review" => %{"reviewId" => "review_001", "status" => "passed"}
       }}
    end

    def fetch_goal_execution(_repository_id, _issue_number) do
      send(Application.fetch_env!(:symphony_elixir, :goal_planning_test_pid), :execution_proposal_confirmed)

      {:ok,
       %{
         "proposal" => %{"proposalVersion" => 1, "maximumTotalTokens" => 1_000_000},
         "approval" => nil
       }}
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :goal_planning_test_pid, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :goal_planning_test_pid) end)
    :ok
  end

  test "uses independent analyst and reviewer sessions before confirming one Goal decision queue" do
    assert :ok =
             GoalPlanningCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [app_server_module: FakeAppServer, game_api_client_module: FakeClient],
               nil
             )

    assert_receive {:session_started, "goal-analyst"}
    assert_receive {:session_started, "goal-proposal-reviewer"}
    assert_receive :execution_proposal_confirmed
  end

  defp issue do
    %Issue{
      id: "bos-front#12",
      identifier: "bos-front-12",
      title: "Automate delivery",
      state: "agent:running",
      labels: ["bos:goal", "agent:running"],
      native_ref: %{
        "repositoryId" => "bos-front",
        "issueNumber" => 12,
        "runId" => "run_goal_001",
        "attemptId" => "attempt_goal_001"
      }
    }
  end
end
