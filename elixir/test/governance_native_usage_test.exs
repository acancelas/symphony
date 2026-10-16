defmodule SymphonyElixir.GovernanceNativeUsageTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceNativeUsage, as: Usage

  defp event(id, input, cached),
    do: %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "threadId" => id,
        "turnId" => "turn-" <> id,
        "tokenUsage" => %{"total" => %{"inputTokens" => input, "cachedInputTokens" => cached}}
      }
    }

  test "fresh sessions remain unknown until real native measurements and aggregate without duplicate charge" do
    {:ok, state} = Usage.register(Usage.new(), "primary", %{witness: "actual-host-pid-birth-primary"})
    assert {:error, :native_usage_measurement_missing} = Usage.snapshot(state)
    {:ok, state} = Usage.observe(state, event("primary", 100, 40))
    {:ok, state} = Usage.observe(state, event("primary", 100, 40))
    {:ok, state} = Usage.observe(state, event("primary", 180, 100))
    {:ok, state} = Usage.register(state, "reviewer", %{witness: "actual-host-pid-birth-reviewer"})
    assert {:error, :native_usage_measurement_missing} = Usage.snapshot(state)
    {:ok, state} = Usage.observe(state, event("reviewer", 50, 10))

    assert {:ok, %{inputTokens: 230, cachedInputTokens: 110, uncachedInputTokens: 120, threads: 2}} =
             Usage.snapshot(state)

    assert {:ok, ^state} = Usage.register(state, "primary", %{witness: "actual-host-pid-birth-primary"})
  end

  test "actual native protocol trace charges cumulative uncached usage once with preserved provenance" do
    fixture = File.read!(Path.join(__DIR__, "fixtures/bos_native_usage_20261016.json")) |> Jason.decode!()
    assert fixture["sourceReportSha256"] == "fdb85942a3865d2bfecdca844ca24e91f6f3f877401aaee5f9b142f4f571d932"

    {:ok, state} =
      Usage.register(Usage.new(), fixture["nativeThreadId"], %{sourceReportSha256: fixture["sourceReportSha256"]})

    state =
      Enum.reduce(fixture["events"] ++ Enum.take(fixture["events"], -1), state, fn event, acc ->
        {:ok, next} = Usage.observe(acc, event)
        next
      end)

    assert {:ok, %{inputTokens: 385_508, cachedInputTokens: 308_608, uncachedInputTokens: 76_900, threads: 1}} =
             Usage.snapshot(state)
  end

  test "source text, tool output and arbitrary nested token maps cannot forge actual usage" do
    {:ok, state} = Usage.register(Usage.new(), "known", %{role: "qa"})

    for payload <- [
          %{"usage" => %{"input_tokens" => 0}},
          %{"method" => "item/completed", "params" => %{"item" => %{"inputTokens" => 0}}},
          %{
            "method" => "thread/tokenUsage/updated-fake",
            "params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 0}}}
          }
        ] do
      assert {:ignored, ^state} = Usage.observe(state, payload)
    end

    assert {:error, :native_usage_measurement_missing} = Usage.snapshot(state)
    assert {:error, _} = Usage.observe(state, event("foreign", 100, 0))
    assert {:error, _} = Usage.register(state, "known", %{role: "different-host-process"})
  end

  test "invalid native counters and regression fail closed; late cache reconciliation cannot refund charge" do
    {:ok, state} = Usage.register(Usage.new(), "known", %{role: "qa"})
    {:ok, state} = Usage.observe(state, event("known", 100, 10))

    for payload <- [
          event("known", -1, 0),
          event("known", 100, 101),
          event("known", 99, 10),
          event("known", 100, 9),
          %{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => "known"}}
        ] do
      assert {:error, _} = Usage.observe(state, payload)
    end

    {:ok, state} = Usage.observe(state, event("known", 110, 100))
    assert {:ok, %{uncachedInputTokens: 90}} = Usage.snapshot(state)
  end
end
