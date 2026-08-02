defmodule SymphonyElixir.GoalExecutionPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GoalExecutionPolicy
  alias SymphonyElixir.Tracker.Issue

  test "one approval authorizes an included Issue and selects reviewers from risk" do
    assert {:ok, policy} =
             GoalExecutionPolicy.evaluate(issue(), execution(), ~U[2026-07-23 22:00:00Z])

    assert policy.approval_id == "approval_123"
    assert policy.reviewers == ~w(functional quality security architecture visual)
    assert policy.scope_frozen == false
  end

  test "strictly derived repairs inherit approval but new functionality does not" do
    repair =
      issue(%{
        "workItemId" => "repair_1",
        "derived" => true,
        "repairsCriterionId" => "criterion_7"
      })

    assert {:ok, _policy} =
             GoalExecutionPolicy.evaluate(repair, execution(), ~U[2026-07-23 22:00:00Z])

    feature =
      issue(%{
        "workItemId" => "feature_2",
        "derived" => false,
        "repairsCriterionId" => nil
      })

    assert {:error, :work_item_not_approved} =
             GoalExecutionPolicy.evaluate(feature, execution(), ~U[2026-07-23 22:00:00Z])
  end

  test "75 percent freezes scope and 100 percent pauses new turns" do
    frozen = put_in(execution(), ["consumption"], %{"totalTokens" => 3_750_000})

    assert {:ok, %{scope_frozen: true}} =
             GoalExecutionPolicy.evaluate(issue(), frozen, ~U[2026-07-23 22:00:00Z])

    exhausted = put_in(execution(), ["consumption"], %{"totalTokens" => 5_000_000})

    assert {:pause, :goal_budget_exhausted} =
             GoalExecutionPolicy.evaluate(issue(), exhausted, ~U[2026-07-23 22:00:00Z])
  end

  test "execution window pauses without invalidating the approval" do
    assert {:pause, :execution_window_not_started} =
             GoalExecutionPolicy.evaluate(issue(), execution(), ~U[2026-07-23 19:00:00Z])

    assert {:pause, :execution_window_closed} =
             GoalExecutionPolicy.evaluate(issue(), execution(), ~U[2026-07-24 06:00:00Z])
  end

  test "legacy unscoped work remains compatible and the default clock is supported" do
    unscoped = %Issue{
      id: "legacy#1",
      identifier: "legacy-1",
      native_ref: %{"repositoryId" => "legacy", "issueNumber" => 1}
    }

    assert {:ok, %{legacy_unscoped: true, reviewers: ~w(functional quality)}} =
             GoalExecutionPolicy.evaluate(unscoped, %{})

    wide_window =
      execution()
      |> put_in(["proposal", "executionWindow"], %{
        "notBefore" => "2020-01-01T00:00:00Z",
        "mustFinishBefore" => "2030-01-01T00:00:00Z"
      })
      |> put_in(["approval", "executionWindow"], %{
        "notBefore" => "2020-01-01T00:00:00Z",
        "mustFinishBefore" => "2030-01-01T00:00:00Z"
      })

    assert {:ok, _policy} = GoalExecutionPolicy.evaluate(issue(), wide_window)
  end

  test "invalid inherited authorization and parent Goal identities fail closed" do
    malformed_authorization =
      issue()
      |> put_in([Access.key!(:native_ref), "inheritedAuthorization"], %{"authorizationInherited" => false})

    assert {:error, :inherited_authorization_missing} =
             GoalExecutionPolicy.locator(malformed_authorization)

    for parent_goal_id <- [123, "bos-front", "bos-front#0", "bos-front#not-a-number"] do
      malformed_goal =
        issue(%{"parentGoalId" => parent_goal_id})

      assert {:error, :invalid_parent_goal_id} = GoalExecutionPolicy.locator(malformed_goal)
    end
  end

  test "incomplete or mismatched approval projections fail closed" do
    rejected = put_in(execution(), ["approval", "decision"], "rejected")

    assert {:error, :goal_approval_invalid} =
             GoalExecutionPolicy.evaluate(issue(), rejected, ~U[2026-07-23 22:00:00Z])

    missing_proposal = Map.delete(execution(), "proposal")

    assert {:error, :goal_execution_projection_incomplete} =
             GoalExecutionPolicy.evaluate(issue(), missing_proposal, ~U[2026-07-23 22:00:00Z])
  end

  test "optional and malformed execution windows are evaluated safely" do
    no_window =
      execution()
      |> put_in(["proposal", "executionWindow"], %{})
      |> put_in(["approval", "executionWindow"], %{})

    assert {:ok, _policy} =
             GoalExecutionPolicy.evaluate(issue(), no_window, ~U[2026-07-23 22:00:00Z])

    for invalid_value <- ["not-a-date", 123] do
      malformed = put_in(execution(), ["approval", "executionWindow", "notBefore"], invalid_value)

      assert {:error, :invalid_execution_window} =
               GoalExecutionPolicy.evaluate(issue(), malformed, ~U[2026-07-23 22:00:00Z])
    end
  end

  test "minimal proposals keep only the baseline reviewers" do
    minimal =
      execution()
      |> put_in(["proposal", "repositories"], ["bos-front"])
      |> put_in(["proposal", "riskTags"], [])
      |> put_in(["proposal", "requiredReviewers"], [])

    assert {:ok, %{reviewers: ~w(functional quality)}} =
             GoalExecutionPolicy.evaluate(issue(), minimal, ~U[2026-07-23 22:00:00Z])
  end

  defp issue(overrides \\ %{}) do
    authorization =
      Map.merge(
        %{
          "authorizationInherited" => true,
          "parentGoalId" => "bos-front#123",
          "goalProposalVersion" => 3,
          "goalApprovalId" => "approval_123",
          "workItemId" => "issue_1",
          "derived" => false,
          "repairsCriterionId" => nil
        },
        overrides
      )

    %Issue{
      id: "bos-front#456",
      identifier: "bos-front-456",
      native_ref: %{
        "repositoryId" => "bos-front",
        "issueNumber" => 456,
        "inheritedAuthorization" => authorization
      }
    }
  end

  defp execution do
    %{
      "proposal" => %{
        "proposalVersion" => 3,
        "repositories" => ["bos-front", "game-api"],
        "riskTags" => ["security", "high"],
        "requiredReviewers" => ["visual"],
        "executionWindow" => %{
          "notBefore" => "2026-07-23T20:00:00Z",
          "mustFinishBefore" => "2026-07-24T05:00:00Z",
          "timezone" => "Europe/Madrid"
        }
      },
      "approval" => %{
        "approvalId" => "approval_123",
        "proposalVersion" => 3,
        "decision" => "approved",
        "approvedIssueIds" => ["issue_1"],
        "maximumDurationSeconds" => 21_600,
        "maximumTotalTokens" => 5_000_000,
        "executionWindow" => %{
          "notBefore" => "2026-07-23T20:00:00Z",
          "mustFinishBefore" => "2026-07-24T05:00:00Z",
          "timezone" => "Europe/Madrid"
        }
      },
      "consumption" => %{"durationSeconds" => 0, "totalTokens" => 0}
    }
  end
end
