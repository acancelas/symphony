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
    assert 60_000 = ProviderCircuit.rate_limited()
    assert {:error, {:game_api_rate_limited, remaining}} = ProviderCircuit.before_request()
    assert remaining > 0

    assert second_remaining = ProviderCircuit.rate_limited()
    assert second_remaining <= 60_000
    assert ProviderCircuit.state_for_test().attempt == 1
  end

  test "success outside a half-open probe does not erase an active circuit" do
    ProviderCircuit.rate_limited()
    assert :ok = ProviderCircuit.succeeded()
    assert %{attempt: 1, half_open: false} = ProviderCircuit.state_for_test()
  end

  test "provider retry guidance extends the shared cooldown" do
    assert 300_000 = ProviderCircuit.rate_limited(300_000)
    assert {:error, {:game_api_rate_limited, remaining}} = ProviderCircuit.before_request()
    assert remaining > 299_000
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
