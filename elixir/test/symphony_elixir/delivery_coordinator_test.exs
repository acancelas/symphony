defmodule SymphonyElixir.DeliveryCoordinatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.DeliveryCoordinator
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAppServer do
    def start_session(_workspace, opts) do
      actor = opts |> Keyword.fetch!(:environment_overrides) |> Map.new() |> Map.fetch!("BOS_MCP_ACTOR")
      send(Application.fetch_env!(:symphony_elixir, :delivery_test_pid), {:session_started, actor})
      {:ok, %{actor: actor}}
    end

    def run_turn(session, prompt, _issue, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :delivery_test_pid), {:turn, session.actor, prompt})
      {:ok, %{session_id: session.actor}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule FakeClient do
    def fetch_run_artifacts(_repository_id, _run_id, "reviews") do
      {:ok, Application.fetch_env!(:symphony_elixir, :delivery_test_reviews)}
    end
  end

  defmodule FakeCandidateHead do
    def confirm(workspace, issue, worker_host) do
      send(
        Application.fetch_env!(:symphony_elixir, :delivery_test_pid),
        {:candidate_confirmed, workspace, issue.branch_name, worker_host}
      )

      {:ok,
       %{
         branch: issue.branch_name,
         head_sha: "0123456789abcdef0123456789abcdef01234567",
         remote_sha: "0123456789abcdef0123456789abcdef01234567"
       }}
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :delivery_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :delivery_test_pid)
      Application.delete_env(:symphony_elixir, :delivery_test_reviews)
    end)

    :ok
  end

  test "runs independent specialist sessions and a finalizer only after durable passes" do
    roles = ~w(functional architecture security quality visual)
    Application.put_env(:symphony_elixir, :delivery_test_reviews, Enum.map(roles, &review(&1, "passed")))

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 game_api_client_module: FakeClient,
                 candidate_head_module: FakeCandidateHead,
                 review_roles: roles
               ],
               nil
             )

    actors = collect_actors(length(roles) + 1, [])
    assert actors == Enum.map(roles, &"#{&1}-reviewer") ++ ["delivery-coordinator"]
    refute "repair-agent" in actors
    assert_received {:candidate_confirmed, "/tmp/workspace", "bos/issue-42", nil}
    assert_received {:candidate_confirmed, "/tmp/workspace", "bos/issue-42", nil}
  end

  test "fails closed after bounded review repair cycles" do
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [review("security", "changes_requested")])

    assert {:error, {:review_repair_limit_reached, summary}} =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 game_api_client_module: FakeClient,
                 candidate_head_module: FakeCandidateHead,
                 review_roles: ["security"],
                 max_repair_cycles: 1
               ],
               nil
             )

    assert summary =~ "security: changes_requested"
    assert collect_actors(2, []) == ["security-reviewer", "delivery-coordinator"]
  end

  defp collect_actors(0, actors), do: Enum.reverse(actors)

  defp collect_actors(remaining, actors) do
    receive do
      {:session_started, actor} -> collect_actors(remaining - 1, [actor | actors])
      {:turn, _actor, _prompt} -> collect_actors(remaining, actors)
    after
      1_000 -> flunk("expected #{remaining} additional role sessions")
    end
  end

  defp review(role, status) do
    %{
      "reviewId" => "review_run_001_1_#{role}",
      "reviewType" => role,
      "status" => status,
      "summary" => "#{role} result",
      "findings" => []
    }
  end

  defp issue do
    %Issue{
      id: "bos-front#42",
      identifier: "bos-front-42",
      title: "Delivery",
      state: "agent:running",
      branch_name: "bos/issue-42",
      native_ref: %{
        "repositoryId" => "bos-front",
        "issueNumber" => 42,
        "runId" => "run_001",
        "attemptId" => "attempt_001"
      }
    }
  end
end
