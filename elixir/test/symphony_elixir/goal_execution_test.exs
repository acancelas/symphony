defmodule SymphonyElixir.GoalExecutionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GoalExecution

  @now ~U[2026-08-02 12:00:00Z]

  test "one exact approval authorizes every included issue and strictly-derived repair" do
    projection = projection()

    assert {:ok, %{authorization_id: "approval-1", scope_frozen: false}} =
             GoalExecution.evaluate(projection, 53, :included_issue, %{"attempts" => 1}, @now)

    assert {:ok, %{authorization_id: "approval-1"}} =
             GoalExecution.evaluate(projection, 999, :derived_repair, %{"tokens" => 50}, @now)
  end

  test "new scope and higher ceilings pause at the single Goal decision boundary" do
    assert {:pause, :goal_scope_change_required, _} =
             GoalExecution.evaluate(projection(), 999, :included_issue, %{}, @now)

    assert {:pause, :goal_budget_exhausted, _} =
             GoalExecution.evaluate(projection(), 53, :included_issue, %{"tokens" => 901}, @now)

    pending = Map.put(projection(), "scopeChangeRequest", %{"requestId" => "change-1"})

    assert {:pause, :goal_change_decision_required, _} =
             GoalExecution.evaluate(pending, 53, :included_issue, %{}, @now)
  end

  test "75 percent freezes scope and 100 percent stops new turns without replenishing on resume" do
    frozen = put_in(projection(), ["consumption", "tokens"], 750)
    assert {:ok, %{scope_frozen: true}} = GoalExecution.evaluate(frozen, 53, :included_issue, %{}, @now)

    exhausted = put_in(frozen, ["consumption", "tokens"], 1_000)

    assert {:pause, :goal_budget_exhausted, snapshot} =
             GoalExecution.evaluate(exhausted, 53, :included_issue, %{"tokens" => 1}, @now)

    assert snapshot.consumption["tokens"] == 1_000
  end

  test "pause and resume retain proposal version and authorization identity" do
    before_window = ~U[2026-08-01 23:59:59Z]

    assert {:pause, :goal_execution_window_closed, snapshot} =
             GoalExecution.evaluate(projection(), 53, :included_issue, %{}, before_window)

    assert snapshot.approval["approvalId"] == "approval-1"
    assert snapshot.proposal["version"] == 4

    assert {:ok, %{authorization_id: "approval-1"}} =
             GoalExecution.evaluate(projection(), 53, :included_issue, %{}, @now)
  end

  test "ordinary issues without a Goal proposal remain unmanaged" do
    assert :unmanaged =
             GoalExecution.evaluate(%{"proposal" => nil, "consumption" => %{}}, 53, :included_issue, %{}, @now)
  end

  defp projection do
    %{
      "proposal" => %{
        "proposalId" => "proposal-1",
        "version" => 4,
        "includedIssueNumbers" => [53, 54],
        "repairPolicy" => "strictly_derived",
        "executionWindow" => %{"startsAt" => "2026-08-02T00:00:00Z", "endsAt" => "2026-08-03T00:00:00Z"},
        "budget" => %{"maxAttempts" => 5, "maxTokens" => 1_000, "maxCostUsd" => 10.0}
      },
      "approval" => %{"approvalId" => "approval-1", "proposalVersion" => 4, "status" => "approved"},
      "scopeChangeRequest" => nil,
      "scopeChangeDecision" => nil,
      "consumption" => %{"attempts" => 1, "tokens" => 100, "costUsd" => 1.0}
    }
  end
end
