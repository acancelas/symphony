defmodule SymphonyElixir.GoalExecutionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GoalExecution

  defmodule GatewayClient do
    def fetch_goal_execution("symphony", 53),
      do: {:ok, SymphonyElixir.GoalExecutionTest.projection_for_gateway()}

    def inherit_goal_authorization(payload) do
      send(self(), {:inherit_goal_authorization, payload})
      {:ok, %{"authorizationId" => "authorization-1"}}
    end

    def check_goal_execution(payload) do
      send(self(), {:check_goal_execution, payload})
      {:ok, %{"status" => "authorized"}}
    end
  end

  defmodule ConfigurableGatewayClient do
    def fetch_goal_execution(_repository_id, _issue_number),
      do: Process.get(:goal_fetch_result)

    def inherit_goal_authorization(payload) do
      send(self(), {:configurable_inherit, payload})
      Process.get(:goal_inherit_result, {:ok, %{"authorizationId" => "authorization-1"}})
    end

    def check_goal_execution(payload) do
      send(self(), {:configurable_check, payload})
      Process.get(:goal_check_result, {:ok, %{"status" => "authorized"}})
    end
  end

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

  test "a fetched projection without a Goal proposal fails closed" do
    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.evaluate(%{"proposal" => nil, "consumption" => %{}}, 53, :included_issue, %{}, @now)
  end

  test "inherits once and checks the shared gateway budget before an authorized turn" do
    issue = %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => 53, "runId" => "run-53"}}

    assert {:ok, %{authorization_id: "authorization-1"}} =
             GoalExecution.check(GatewayClient, issue, :included_issue, %{"attempts" => 1})

    assert_received {:inherit_goal_authorization, inherited}
    assert inherited["goalIssueNumber"] == 22
    assert inherited["proposalId"] == "proposal-1"
    assert inherited["taskKind"] == "included_issue"

    assert_received {:check_goal_execution, checked}
    assert checked["authorizationId"] == "authorization-1"
    assert checked["requestedConsumption"] == %{"attempts" => 1}
    assert checked["operationId"] == "goal_execution_check_default_run-53_included_issue"
  end

  test "gateway checks fail closed and preserve pause decisions" do
    issue = gateway_issue()

    Process.put(:goal_fetch_result, {:ok, Map.put(projection(), "scopeChangeRequest", %{"requestId" => "change"})})
    assert {:pause, :goal_change_decision_required, _} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)
    refute_received {:configurable_inherit, _}

    Process.put(:goal_fetch_result, {:ok, %{"proposal" => nil}})

    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_fetch_result, {:error, :provider_down})
    assert {:error, :provider_down} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_fetch_result, {:ok, projection()})
    Process.put(:goal_inherit_result, {:error, :inherit_failed})
    assert {:error, :inherit_failed} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_inherit_result, :invalid_response)

    assert {:error, :invalid_goal_execution_check} =
             GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_inherit_result, {:ok, %{"authorizationId" => "authorization-1"}})
    Process.put(:goal_check_result, {:ok, %{"authorized" => true}})
    assert {:ok, _} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_check_result, {:ok, %{"status" => "paused", "reason" => "window_closed"}})
    assert {:pause, "window_closed", _} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_check_result, {:ok, %{}})
    assert {:error, :invalid_goal_execution_check} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)

    Process.put(:goal_check_result, {:ok, :invalid_response})
    assert {:error, :invalid_goal_execution_check} = GoalExecution.check(ConfigurableGatewayClient, issue, :included_issue)
  end

  test "invalid and unmanaged identities do not acquire authorization" do
    assert :unmanaged = GoalExecution.check(ConfigurableGatewayClient, %{}, :included_issue)

    assert :unmanaged = GoalExecution.check(__MODULE__, %{}, :included_issue)

    assert :unmanaged =
             GoalExecution.check(
               ConfigurableGatewayClient,
               gateway_issue(),
               :included_issue,
               %{},
               :invalid_check_key
             )

    Process.put(:goal_fetch_result, {:ok, projection()})

    assert {:error, :invalid_goal_execution_identity} =
             GoalExecution.check(
               ConfigurableGatewayClient,
               %{native_ref: %{"repositoryId" => nil, "issueNumber" => 53}},
               :included_issue
             )

    assert {:error, :invalid_goal_execution_identity} =
             GoalExecution.check(
               ConfigurableGatewayClient,
               %{native_ref: %{"repositoryId" => "  ", "issueNumber" => 53}},
               :included_issue
             )

    assert {:error, :invalid_goal_execution_identity} =
             GoalExecution.check(
               ConfigurableGatewayClient,
               %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => "53"}},
               :included_issue
             )

    invalid = put_in(projection(), ["proposal", "proposalId"], nil)
    Process.put(:goal_fetch_result, {:ok, invalid})

    assert {:error, :invalid_goal_authorization_identity} =
             GoalExecution.check(ConfigurableGatewayClient, gateway_issue(), :included_issue)
  end

  test "covers rejected approvals, malformed dates, atom keys, and derived repair identity" do
    rejected = put_in(projection(), ["approval", "status"], "rejected")

    assert {:pause, :goal_approval_required, _} =
             GoalExecution.evaluate(rejected, 53, :included_issue, %{}, @now)

    missing_approval = Map.put(projection(), "approval", nil)

    assert {:pause, :goal_approval_required, _} =
             GoalExecution.evaluate(missing_approval, 53, :included_issue, %{}, @now)

    malformed_window = put_in(projection(), ["proposal", "executionWindow"], %{"startsAt" => "bad"})

    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.evaluate(malformed_window, 53, :included_issue, %{}, @now)

    atom_projection = %{proposal: nil, consumption: %{}}

    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.evaluate(atom_projection, 53, :included_issue, %{}, @now)

    Process.put(:goal_fetch_result, {:ok, projection()})
    Process.delete(:goal_inherit_result)
    Process.put(:goal_check_result, {:ok, %{"status" => "authorized"}})
    assert {:ok, _} = GoalExecution.check(ConfigurableGatewayClient, gateway_issue(), :derived_repair)
    assert_received {:configurable_inherit, %{"derivedFromIssueNumber" => 53}}
  end

  test "malformed budgets and consumption fail closed" do
    for invalid <- ["many", nil, -1] do
      malformed = put_in(projection(), ["proposal", "budget", "maxAttempts"], invalid)

      assert {:pause, :invalid_goal_execution_projection, _} =
               GoalExecution.evaluate(malformed, 53, :included_issue, %{}, @now)
    end

    malformed = put_in(projection(), ["consumption", "tokens"], "100")

    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.evaluate(malformed, 53, :included_issue, %{}, @now)

    assert {:pause, :invalid_goal_execution_projection, _} =
             GoalExecution.evaluate(projection(), 53, :included_issue, %{"tokens" => "1"}, @now)

    for invalid_budget <- [nil, "unbounded"] do
      malformed = put_in(projection(), ["proposal", "budget"], invalid_budget)

      assert {:pause, :invalid_goal_execution_projection, _} =
               GoalExecution.evaluate(malformed, 53, :included_issue, %{}, @now)
    end

    optional_limits =
      projection()
      |> put_in(["proposal", "budget", "maxTokens"], nil)
      |> put_in(["proposal", "budget", "maxCostUsd"], nil)

    assert {:ok, _} =
             GoalExecution.evaluate(optional_limits, 53, :included_issue, %{}, @now)
  end

  test "successive logical turns use distinct stable gateway check operation IDs" do
    Process.put(:goal_fetch_result, {:ok, projection()})

    assert {:ok, _} =
             GoalExecution.check(ConfigurableGatewayClient, gateway_issue(), :included_issue, %{}, "turn_1")

    assert_received {:configurable_check, first}

    assert {:ok, _} =
             GoalExecution.check(ConfigurableGatewayClient, gateway_issue(), :included_issue, %{}, "turn_2")

    assert_received {:configurable_check, second}
    assert first["operationId"] == "goal_execution_check_turn_1_run-53_included_issue"
    assert second["operationId"] == "goal_execution_check_turn_2_run-53_included_issue"
  end

  @doc false
  def projection_for_gateway, do: projection()

  defp gateway_issue do
    %{native_ref: %{"repositoryId" => "symphony", "issueNumber" => 53, "runId" => "run-53"}}
  end

  defp projection do
    %{
      "proposal" => %{
        "issueNumber" => 22,
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
