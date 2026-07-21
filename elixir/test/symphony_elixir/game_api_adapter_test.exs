defmodule SymphonyElixir.GameApiAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GameApi.Adapter
  alias SymphonyElixir.GameApi.Client

  defmodule FakeClient do
    @spec validate_config(map()) :: :ok
    def validate_config(_settings), do: :ok

    @spec fetch_ready_issues() :: {:ok, [map()]}
    def fetch_ready_issues do
      {:ok,
       Application.get_env(:symphony_elixir, :game_api_test_issues, [
         %{
           "number" => 42,
           "title" => "Implement BOS Delivery",
           "body" => "Acceptance contract",
           "labels" => ["bos:issue", "agent:ready"],
           "url" => "https://github.test/issues/42",
           "updatedAt" => "2026-07-19T18:00:00Z",
           "claim" => nil,
           "_repositoryId" => "bos-front"
         }
       ])}
    end

    @spec fetch_issue(String.t(), pos_integer()) :: {:ok, map()}
    def fetch_issue("bos-front", 42), do: fetch_ready_issues() |> then(fn {:ok, [issue]} -> {:ok, issue} end)

    @spec claim_issue(String.t(), pos_integer(), String.t() | nil) :: {:ok, map()}
    def claim_issue("bos-front", 42, nil) do
      {:ok,
       %{
         "status" => "completed",
         "disposition" => "new_run",
         "claim" => %{"runId" => "run_42_001", "runnerId" => "x1"}
       }}
    end

    def claim_issue("game-api", 80, "run_80_existing") do
      {:ok,
       %{
         "status" => "completed",
         "disposition" => "resume_run",
         "claim" => %{"runId" => "run_80_existing", "runnerId" => "x1"},
         "issue" => %{"labels" => ["bos:issue", "agent:running"]}
       }}
    end

    @spec start_execution(SymphonyElixir.Tracker.Issue.t(), pos_integer()) ::
            {:ok, String.t()}
    def start_execution(%SymphonyElixir.Tracker.Issue{native_ref: %{"runId" => "run_42_001"}}, 1) do
      {:ok, "attempt_run_42_001_1"}
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :game_api_client_module)
    Application.put_env(:symphony_elixir, :game_api_client_module, FakeClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :game_api_test_issues)

      if previous_client do
        Application.put_env(:symphony_elixir, :game_api_client_module, previous_client)
      else
        Application.delete_env(:symphony_elixir, :game_api_client_module)
      end
    end)

    :ok
  end

  test "normalizes ready issues without exposing GitHub credentials" do
    assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["agent:ready"])
    assert issue.id == "bos-front#42"
    assert issue.identifier == "bos-front-42"
    assert issue.state == "agent:ready"
    assert issue.dispatchable
  end

  test "preserves the exact run identity for an expired running claim" do
    Application.put_env(:symphony_elixir, :game_api_test_issues, [
      %{
        "number" => 80,
        "title" => "Recover repository settings",
        "body" => "Resume the exact AgentRun",
        "labels" => ["bos:issue", "agent:running"],
        "url" => "https://github.test/issues/80",
        "updatedAt" => "2026-07-21T03:00:00Z",
        "claim" => %{
          "runId" => "run_80_existing",
          "runnerId" => "x1",
          "leaseExpiresAt" => "2026-07-21T03:15:00Z"
        },
        "_repositoryId" => "game-api",
        "_repositoryCloneUrl" => "git@github.com:acancelas/game-api.git"
      }
    ])

    assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["agent:running"])

    assert issue.state == "agent:running"
    assert issue.dispatchable
    assert issue.native_ref["runId"] == "run_80_existing"
    assert issue.native_ref["repositoryId"] == "game-api"

    assert {:ok, resumed} = Adapter.claim_issue(issue)
    assert resumed.native_ref["runId"] == "run_80_existing"
    assert resumed.state == "agent:running"
  end

  test "claims through game-api before dispatch" do
    assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["agent:ready"])
    assert {:ok, claimed} = Adapter.claim_issue(issue)
    assert claimed.native_ref["runId"] == "run_42_001"
    assert claimed.state == "agent:running"
  end

  test "persists the execution identity before Codex starts" do
    assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["agent:ready"])
    assert {:ok, claimed} = Adapter.claim_issue(issue)
    assert {:ok, started} = Adapter.start_execution(claimed, 1)
    assert started.native_ref["attemptId"] == "attempt_run_42_001_1"
  end

  test "preserves audit chain conflict identity for outbox recovery" do
    assert Client.http_error(409, %{
             "detail" => %{"error" => "audit_chain_conflict", "message" => "stale"}
           }) == {:game_api_http_error, 409, "audit_chain_conflict"}

    assert Client.http_error(404, %{"error" => "delivery_run_not_found"}) ==
             {:game_api_http_error, 404}
  end
end
