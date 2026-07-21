defmodule SymphonyElixir.GameApiAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GameApi.Adapter
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.GameApi.RateLimit

  setup do
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)
    :ok
  end

  test "shares one rate-limit circuit across all game-api callers" do
    assert :ok = RateLimit.check()
    assert RateLimit.block_for(60_000) > 0
    assert {:error, {:game_api_rate_limited, remaining_ms}} = RateLimit.check()
    assert remaining_ms > 0

    assert RateLimit.block_for(120_000) >= remaining_ms
    assert {:error, {:game_api_rate_limited, extended_ms}} = RateLimit.check()
    assert extended_ms > remaining_ms
  end

  test "honors retry-after and uses a conservative fallback" do
    retry_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => ["3"]}})
    assert retry_ms >= 3_000
    assert retry_ms <= 8_000

    RateLimit.reset()
    fallback_ms = RateLimit.block(%Req.Response{status: 429, headers: %{}})
    assert fallback_ms >= 120_000
    assert fallback_ms <= 125_000
  end

  test "honors reset timestamps and tolerates scalar or invalid headers" do
    reset_epoch = System.system_time(:second) + 10

    reset_ms =
      RateLimit.block(%Req.Response{
        status: 429,
        headers: %{"x-ratelimit-reset" => [Integer.to_string(reset_epoch)]}
      })

    assert reset_ms >= 9_000
    assert reset_ms <= 15_000

    RateLimit.reset()
    scalar_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => "3"}})
    assert scalar_ms >= 3_000
    assert scalar_ms <= 8_000

    RateLimit.reset()
    fallback_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => "invalid"}})
    assert fallback_ms >= 120_000
    assert fallback_ms <= 125_000
  end

  defmodule FakeClient do
    @spec validate_config(map()) :: :ok
    def validate_config(_settings), do: :ok

    @spec fetch_ready_issues() :: {:ok, [map()]}
    def fetch_ready_issues do
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

  test "preserves audit chain conflict identity for outbox recovery" do
    assert Client.http_error(409, %{
             "detail" => %{"error" => "audit_chain_conflict", "message" => "stale"}
           }) == {:game_api_http_error, 409, "audit_chain_conflict"}

    assert Client.http_error(422, %{
             "detail" => %{"error" => "audit_event_hash_invalid", "message" => "mismatch"}
           }) == {:game_api_http_error, 422, "audit_event_hash_invalid"}

    assert Client.http_error(404, %{"error" => "delivery_run_not_found"}) ==
             {:game_api_http_error, 404}
  end
end
