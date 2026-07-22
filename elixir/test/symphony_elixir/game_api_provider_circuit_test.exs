defmodule SymphonyElixir.GameApiProviderCircuitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GameApi.ProviderCircuit

  setup do
    ProviderCircuit.reset_for_test()
    on_exit(&ProviderCircuit.reset_for_test/0)
    :ok
  end

  test "one provider rate limit gates every caller without multiplying attempts" do
    assert :ok = ProviderCircuit.before_request()
    first_delay = ProviderCircuit.rate_limited()
    assert first_delay > 60_000
    assert first_delay <= 66_000
    assert {:error, {:game_api_rate_limited, remaining}} = ProviderCircuit.before_request()
    assert remaining > 0

    assert second_remaining = ProviderCircuit.rate_limited()
    assert second_remaining <= first_delay
    assert ProviderCircuit.state_for_test().attempt == 1
  end

  test "success outside a half-open probe does not erase an active circuit" do
    ProviderCircuit.rate_limited()
    assert :ok = ProviderCircuit.succeeded()
    assert %{attempt: 1, half_open: false} = ProviderCircuit.state_for_test()
  end

  test "provider retry guidance extends the shared cooldown" do
    delay = ProviderCircuit.rate_limited(300_000)
    assert delay > 300_000
    assert delay <= 330_000
    assert {:error, {:game_api_rate_limited, remaining}} = ProviderCircuit.before_request()
    assert remaining > 299_000
  end

  test "provider retry guidance is not truncated to the internal backoff ceiling" do
    assert 2_140_000 = ProviderCircuit.rate_limited_for_test(2_123_000, 17_000)

    assert %{attempt: 1, half_open: false, due_at_ms: due_at_ms} =
             ProviderCircuit.state_for_test()

    assert due_at_ms > System.monotonic_time(:millisecond) + 2_139_000
  end

  test "jitter is bounded and never weakens the provider minimum" do
    assert 330_000 = ProviderCircuit.rate_limited_for_test(300_000, 90_000)
    assert {:error, {:game_api_rate_limited, remaining}} = ProviderCircuit.before_request()
    assert remaining > 329_000
  end

  test "provider retry guidance has a defensive one-day ceiling" do
    assert 86_430_000 = ProviderCircuit.rate_limited_for_test(172_800_000, 30_000)
  end

  test "one probe closes an expired circuit only after success" do
    ProviderCircuit.rate_limited()
    ProviderCircuit.expire_for_test()

    assert :ok = ProviderCircuit.before_request()
    assert %{attempt: 1, half_open: true} = ProviderCircuit.state_for_test()
    assert {:error, {:game_api_rate_limited, 1_000}} = ProviderCircuit.before_request()
    assert :ok = ProviderCircuit.succeeded()
    assert ProviderCircuit.state_for_test() == nil
  end
end
