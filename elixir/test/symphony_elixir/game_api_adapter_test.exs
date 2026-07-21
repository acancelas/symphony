defmodule SymphonyElixir.GameApiAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GameApi.Adapter
  alias SymphonyElixir.GameApi.Client

  defmodule FakeClient do
    @spec validate_config(map()) :: :ok
    def validate_config(_settings), do: :ok

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [map()]}
    def fetch_issues_by_states(_states) do
      {:ok,
       [
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
       ]}
    end

    @spec fetch_issue(String.t(), pos_integer()) :: {:ok, map()}
    def fetch_issue("bos-front", 42), do: fetch_issues_by_states(["agent:ready"]) |> then(fn {:ok, [issue]} -> {:ok, issue} end)

    @spec reconcile_terminal_runs() :: {:ok, [map()]}
    def reconcile_terminal_runs, do: {:ok, [%{"action" => "reconciled"}]}

    @spec claim_issue(String.t(), pos_integer(), String.t() | nil) :: {:ok, map()}
    def claim_issue("bos-front", 42, nil) do
      {:ok,
       %{
         "status" => "completed",
         "disposition" => "new_run",
         "claim" => %{"runId" => "run_42_001", "runnerId" => "x1"}
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

  test "delegates durable terminal run reconciliation to game-api" do
    assert {:ok, [%{"action" => "reconciled"}]} = Adapter.reconcile_terminal_runs()
  end

  test "uses a stable operation identity within one reconciliation cycle and a fresh identity later" do
    run_id = "run_42_001"

    first = Client.reconciliation_operation_id_for_test(run_id, "cycle_one")
    repeated = Client.reconciliation_operation_id_for_test(run_id, "cycle_one")
    later = Client.reconciliation_operation_id_for_test(run_id, "cycle_two")

    assert first == repeated
    assert first != later
    assert first == "reconcile_terminal_run_42_001_cycle_one"
  end

  test "preserves audit chain conflict identity for outbox recovery" do
    assert Client.http_error(409, %{
             "detail" => %{"error" => "audit_chain_conflict", "message" => "stale"}
           }) == {:game_api_http_error, 409, "audit_chain_conflict"}

    assert Client.http_error(422, %{
             "detail" => %{"error" => "audit_event_hash_invalid", "message" => "stale payload"}
           }) == {:game_api_http_error, 422, "audit_event_hash_invalid"}

    assert Client.http_error(
             422,
             ~s({"detail":{"error":"audit_event_hash_invalid","message":"stale payload"}})
           ) == {:game_api_http_error, 422, "audit_event_hash_invalid"}

    assert Client.http_error(422, %{
             "detail" => ~s({"code":"audit_sequence_gap","message":"missing events"})
           }) == {:game_api_http_error, 422, "audit_sequence_gap"}

    assert Client.http_error(404, %{"error" => "delivery_run_not_found"}) ==
             {:game_api_http_error, 404}
  end
end
