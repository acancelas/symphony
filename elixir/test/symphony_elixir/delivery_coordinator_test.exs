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

      if String.ends_with?(session.actor, "-reviewer") do
        role = String.trim_trailing(session.actor, "-reviewer")
        [_, cycle] = Regex.run(~r/, cycle (\d+)\./, prompt)
        statuses = Application.get_env(:symphony_elixir, :delivery_review_statuses, %{})
        status = Map.get(statuses, role, "passed")
        reviews = Application.get_env(:symphony_elixir, :delivery_test_reviews, [])

        Application.put_env(
          :symphony_elixir,
          :delivery_test_reviews,
          [review_artifact(role, status, String.to_integer(cycle)) | reviews]
        )
      end

      {:ok, %{session_id: session.actor}}
    end

    def stop_session(_session), do: :ok

    defp review_artifact(role, status, cycle) do
      %{
        "reviewId" => "review_run_001_#{cycle}_#{role}",
        "reviewType" => role,
        "status" => status,
        "summary" => "#{role} result",
        "findings" => []
      }
    end
  end

  defmodule FakeClient do
    def fetch_run_artifacts(_repository_id, _run_id, "reviews") do
      {:ok, Application.fetch_env!(:symphony_elixir, :delivery_test_reviews)}
    end
  end

  defmodule RetryAppServer do
    def start_session(workspace, opts), do: FakeAppServer.start_session(workspace, opts)

    def run_turn(session, prompt, _issue, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :delivery_test_pid), {:turn, session.actor, prompt})
      result = {:ok, %{session_id: session.actor}}
      attempt = Application.get_env(:symphony_elixir, :delivery_review_record_attempt, 0) + 1
      Application.put_env(:symphony_elixir, :delivery_review_record_attempt, attempt)

      if attempt == 2 do
        Application.put_env(:symphony_elixir, :delivery_test_reviews, [
          %{
            "reviewId" => "review_run_001_1_functional",
            "reviewType" => "functional",
            "status" => "passed",
            "summary" => "functional result",
            "findings" => []
          }
        ])
      end

      result
    end

    def stop_session(session), do: FakeAppServer.stop_session(session)
  end

  defmodule RateLimitedReviewClient do
    def fetch_run_artifacts(_repository_id, _run_id, "reviews") do
      attempt = Application.get_env(:symphony_elixir, :delivery_review_lookup_attempt, 0) + 1
      Application.put_env(:symphony_elixir, :delivery_review_lookup_attempt, attempt)

      if attempt == 1 do
        {:error, {:game_api_rate_limited, 743_083}}
      else
        {:ok, Application.fetch_env!(:symphony_elixir, :delivery_test_reviews)}
      end
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

  defmodule SequencedCandidateHead do
    def confirm(_workspace, issue, _worker_host) do
      [result | remaining] = Application.fetch_env!(:symphony_elixir, :delivery_candidate_results)
      Application.put_env(:symphony_elixir, :delivery_candidate_results, remaining)

      case result do
        {:dirty, status, paths, fingerprint} ->
          {:error, {:candidate_workspace_dirty, %{status: status, paths: paths, fingerprint: fingerprint}}}

        {:clean, head_sha} ->
          {:ok, %{branch: issue.branch_name, head_sha: head_sha, remote_sha: head_sha}}
      end
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :delivery_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :delivery_test_pid)
      Application.delete_env(:symphony_elixir, :delivery_test_reviews)
      Application.delete_env(:symphony_elixir, :delivery_review_record_attempt)
      Application.delete_env(:symphony_elixir, :delivery_review_lookup_attempt)
      Application.delete_env(:symphony_elixir, :delivery_review_statuses)
      Application.delete_env(:symphony_elixir, :delivery_candidate_results)
    end)

    :ok
  end

  test "runs independent specialist sessions and a finalizer only after durable passes" do
    roles = ~w(functional architecture security quality visual)
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: FakeCandidateHead,
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
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])
    Application.put_env(:symphony_elixir, :delivery_review_statuses, %{"security" => "changes_requested"})

    assert {:error, {:review_repair_limit_reached, summary}} =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: FakeCandidateHead,
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

  test "retries only the missing reviewer artifact before restarting broader delivery" do
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: RetryAppServer,
                 candidate_head_module: FakeCandidateHead,
                 game_api_client_module: FakeClient,
                 review_roles: ["functional"]
               ],
               nil
             )

    assert collect_actors(3, []) == ["functional-reviewer", "functional-reviewer", "delivery-coordinator"]
  end

  test "waits for the provider circuit without rerunning a completed reviewer" do
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])
    test_pid = self()

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: FakeCandidateHead,
                 game_api_client_module: RateLimitedReviewClient,
                 review_roles: ["functional"],
                 review_lookup_sleep: fn delay_ms -> send(test_pid, {:review_lookup_sleep, delay_ms}) end
               ],
               nil
             )

    assert_received {:review_lookup_sleep, 743_083}
    assert collect_actors(2, []) == ["functional-reviewer", "delivery-coordinator"]
  end

  test "detects and reuses a durable review stage on scheduler retry" do
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [review("functional", "passed")])

    assert {:ok, true} =
             DeliveryCoordinator.review_stage_started?(issue(), game_api_client_module: FakeClient)

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: FakeCandidateHead,
                 game_api_client_module: FakeClient,
                 review_roles: ["functional"]
               ],
               nil
             )

    assert collect_actors(1, []) == ["delivery-coordinator"]
  end

  test "reports a fresh implementation stage when no Reviews exist" do
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])

    assert {:ok, false} =
             DeliveryCoordinator.review_stage_started?(issue(), game_api_client_module: FakeClient)
  end

  test "routes a generated lockfile into one repair turn before fresh exact-head reviews" do
    new_head = String.duplicate("b", 40)
    fingerprint = String.duplicate("c", 64)
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])

    Application.put_env(:symphony_elixir, :delivery_candidate_results, [
      {:dirty, " M uv.lock", ["uv.lock"], fingerprint},
      {:clean, new_head},
      {:clean, new_head},
      {:clean, new_head}
    ])

    assert :ok =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: SequencedCandidateHead,
                 game_api_client_module: FakeClient,
                 review_roles: ["functional"],
                 prior_command_context: %{command: "uv lock", exit_code: 0}
               ],
               nil
             )

    assert_received {:turn, "dirty-candidate-repair-agent", prompt}
    assert prompt =~ "uv.lock"
    assert prompt =~ fingerprint
    assert prompt =~ "uv lock"

    assert collect_actors(3, []) == [
             "dirty-candidate-repair-agent",
             "functional-reviewer",
             "delivery-coordinator"
           ]
  end

  test "blocks after the bounded repair leaves an unsafe tracked change dirty" do
    fingerprint = String.duplicate("d", 64)
    diagnosis = {:dirty, " M config/runtime.secret", ["config/runtime.secret"], fingerprint}
    Application.put_env(:symphony_elixir, :delivery_test_reviews, [])
    Application.put_env(:symphony_elixir, :delivery_candidate_results, [diagnosis, diagnosis])

    assert {:error, {:candidate_dirty_repair_unresolved, unresolved}} =
             DeliveryCoordinator.run(
               "/tmp/workspace",
               issue(),
               nil,
               [
                 app_server_module: FakeAppServer,
                 candidate_head_module: SequencedCandidateHead,
                 game_api_client_module: FakeClient,
                 review_roles: ["functional"]
               ],
               nil
             )

    assert_received {:turn, "delivery-coordinator", prompt}
    assert prompt =~ fingerprint
    assert prompt =~ "config/runtime.secret"
    assert unresolved.paths == ["config/runtime.secret"]
    assert collect_actors(2, []) == ["dirty-candidate-repair-agent", "delivery-coordinator"]
    refute_received {:session_started, "functional-reviewer"}
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
