defmodule SymphonyElixir.TurnBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentRunner, Codex.TurnBudget, Tracker.Issue}

  @limits %{
    "soft_wall_clock_ms" => 1_000,
    "hard_wall_clock_ms" => 2_000,
    "soft_uncached_input_tokens" => 100,
    "hard_uncached_input_tokens" => 200
  }

  test "budgets uncached input and emits checkpoint then interrupt once" do
    budget = TurnBudget.new("security-reviewer", @limits, 0)

    budget =
      TurnBudget.observe(budget, %{
        "params" => %{
          "tokenUsage" => %{
            "total" => %{"inputTokens" => 1_100, "cachedInputTokens" => 1_000}
          }
        }
      })

    assert {[:checkpoint], budget} = TurnBudget.actions(budget, 10)
    assert budget.uncached_input_tokens == 100
    assert budget.pause_reason == :soft_uncached_input

    budget =
      TurnBudget.observe(budget, %{
        "usage" => %{"input_tokens" => 1_250, "cached_input_tokens" => 1_000}
      })

    assert {[:interrupt], budget} = TurnBudget.actions(budget, 20)
    assert budget.pause_reason == :hard_uncached_input
    assert {[], ^budget} = TurnBudget.actions(budget, 30)
  end

  test "wall clock hard limit also emits a checkpoint when soft was skipped" do
    budget = TurnBudget.new("implementation-agent", @limits, 0)

    assert {[:checkpoint, :interrupt], budget} = TurnBudget.actions(budget, 2_000)
    assert budget.pause_reason == :hard_wall_clock
  end

  test "accepts a direct usage payload from compatible app-server versions" do
    budget = TurnBudget.new("default", @limits, 0)
    budget = TurnBudget.observe(budget, %{"input_tokens" => 80, "cached_input_tokens" => 30})

    assert budget.input_tokens == 80
    assert budget.cached_input_tokens == 30
    assert budget.uncached_input_tokens == 50
  end

  test "a paused implementation returns control without opening delivery coordination" do
    issue = %Issue{id: "issue-40", identifier: "BOS-40"}
    parent = self()
    coordinator = fn -> send(parent, :delivery_coordinator_started) end

    assert :ok =
             AgentRunner.continue_after_implementation_for_test(
               {:paused, %{pause_reason: :hard_uncached_input}},
               issue,
               coordinator
             )

    refute_receive :delivery_coordinator_started

    assert :delivery_started =
             AgentRunner.continue_after_implementation_for_test(:ok, issue, fn ->
               :delivery_started
             end)
  end
end
