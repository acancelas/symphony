defmodule SymphonyElixir.GameApiAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GameApi.Adapter
  alias SymphonyElixir.GameApi.Client
  alias SymphonyElixir.GameApi.RateLimit

  setup do
    if is_nil(Process.whereis(RateLimit)), do: start_supervised!(RateLimit)
    RateLimit.reset()
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

  test "treats an expired reset timestamp as unusable" do
    expired_epoch = System.system_time(:second) - 10

    fallback_ms =
      RateLimit.block(%Req.Response{
        status: 429,
        headers: %{"x-ratelimit-reset" => [Integer.to_string(expired_epoch)]}
      })

    assert fallback_ms >= 120_000
    assert fallback_ms <= 125_000
  end

  test "concurrent rate limits cannot shorten the longest deadline" do
    tasks =
      for retry_ms <- [15_000, 120_000, 30_000, 60_000] do
        Task.async(fn -> RateLimit.block_for(retry_ms) end)
      end

    Enum.each(tasks, &Task.await/1)
    assert {:error, {:game_api_rate_limited, remaining_ms}} = RateLimit.check()
    assert remaining_ms >= 119_000
  end

  test "allows one half-open probe and rejects stale success permits" do
    {:ok, stale_permit} = RateLimit.acquire()
    RateLimit.block_for(1_000)
    :ok = RateLimit.succeed(stale_permit)
    assert {:error, {:game_api_rate_limited, _remaining_ms}} = RateLimit.check()

    expire_circuit()
    assert {:ok, probe_permit} = RateLimit.acquire()
    assert {:error, {:game_api_rate_limited, 1_000}} = RateLimit.acquire()
    assert {:error, {:game_api_rate_limited, 1_000}} = RateLimit.check()

    assert :ok = RateLimit.succeed(probe_permit)
    assert {:ok, _permit} = RateLimit.acquire()
  end

  test "releases a half-open probe when its caller dies" do
    RateLimit.block_for(1_000)
    expire_circuit()

    task = Task.async(fn -> RateLimit.acquire() end)
    assert {:ok, _abandoned_permit} = Task.await(task)
    Process.sleep(5)
    assert {:ok, _replacement_permit} = RateLimit.acquire()

    send(Process.whereis(RateLimit), {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(5)
    assert Process.alive?(Process.whereis(RateLimit))
  end

  test "times out an abandoned half-open probe inside the breaker" do
    RateLimit.block_for(1_000)
    expire_circuit()
    assert {:ok, permit} = RateLimit.acquire()

    send(Process.whereis(RateLimit), {:probe_timeout, permit})
    Process.sleep(5)
    assert {:error, {:game_api_rate_limited, remaining_ms}} = RateLimit.check()
    assert remaining_ms >= 29_000

    send(Process.whereis(RateLimit), {:probe_timeout, permit})
    Process.sleep(5)
    assert Process.alive?(Process.whereis(RateLimit))
  end

  test "supports Retry-After HTTP dates and caps hostile deadlines" do
    http_date =
      DateTime.utc_now()
      |> DateTime.add(5, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    retry_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => [http_date]}})
    assert retry_ms >= 4_000
    assert retry_ms <= 10_000

    RateLimit.reset()
    capped_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => ["99999999"]}})
    assert capped_ms >= 899_000
    assert capped_ms <= 900_000
  end

  test "classifies normalized rate limits and transient gateway failures" do
    assert RateLimit.rate_limited_response?(%Req.Response{status: 429, headers: %{}})

    assert RateLimit.rate_limited_response?(%Req.Response{
             status: 503,
             headers: %{"retry-after" => ["30"]}
           })

    assert RateLimit.rate_limited_response?(%Req.Response{
             status: 403,
             headers: %{"x-ratelimit-remaining" => ["0"]}
           })

    refute RateLimit.rate_limited_response?(%Req.Response{status: 403, headers: %{}})
    refute RateLimit.rate_limited_response?(%Req.Response{status: 401, headers: %{}})
    assert RateLimit.authentication_response?(%Req.Response{status: 403, headers: %{}})
    assert RateLimit.authentication_response?(%Req.Response{status: 401, headers: %{}})
    assert RateLimit.transient_response?(%Req.Response{status: 500})
    assert RateLimit.transient_response?(%Req.Response{status: 502})
    assert RateLimit.transient_response?(%Req.Response{status: 503})
    assert RateLimit.transient_response?(%Req.Response{status: 504})
    refute RateLimit.transient_response?(%Req.Response{status: 499})

    transient_ms = RateLimit.block_transient(%Req.Response{status: 503, headers: %{}})
    assert transient_ms >= 30_000
    assert transient_ms <= 35_000
  end

  test "starts named circuit owners and treats past HTTP dates as unusable" do
    name = :"rate_limit_test_#{System.unique_integer([:positive])}"
    assert {:ok, pid} = RateLimit.start_link(name: name)
    assert Process.alive?(pid)
    GenServer.stop(pid)

    past_date =
      DateTime.utc_now()
      |> DateTime.add(-5, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    fallback_ms = RateLimit.block(%Req.Response{status: 429, headers: %{"retry-after" => [past_date]}})
    assert fallback_ms >= 120_000
    assert fallback_ms <= 125_000

    RateLimit.reset()

    invalid_date_ms =
      RateLimit.block(%Req.Response{
        status: 429,
        headers: %{"retry-after" => ["Tue, 21 Xxx 2026 12:00:00 GMT"]}
      })

    assert invalid_date_ms >= 120_000
  end

  test "restores an open circuit after its owner restarts" do
    path = Path.join(System.tmp_dir!(), "rate-limit-state-#{System.unique_integer([:positive])}.json")
    name = :"rate_limit_restore_#{System.unique_integer([:positive])}"
    assert {:ok, pid} = RateLimit.start_link(name: name, state_path: path)
    assert GenServer.call(pid, {:block_for, 60_000}) >= 59_000
    GenServer.stop(pid)

    assert {:ok, restored} = RateLimit.start_link(name: name, state_path: path)
    assert {:error, {:game_api_rate_limited, remaining_ms}} = GenServer.call(restored, :check)
    assert remaining_ms >= 59_000
    assert :ok = GenServer.call(restored, :reset)
    GenServer.stop(restored)
    refute File.exists?(path)
  end

  test "falls back durably when the primary cooldown write fails" do
    unique = System.unique_integer([:positive])
    primary = "/proc/symphony-rate-limit-#{unique}/state.json"
    fallback = Path.join(System.tmp_dir!(), "rate-limit-fallback-#{unique}.json")
    name = :"rate_limit_fallback_#{unique}"

    assert {:ok, owner} =
             RateLimit.start_link(name: name, state_path: primary, fallback_state_path: fallback)

    assert GenServer.call(owner, {:block_for, 60_000}) >= 59_000
    assert File.exists?(fallback)
    GenServer.stop(owner)

    assert {:ok, restored} =
             RateLimit.start_link(name: name, state_path: primary, fallback_state_path: fallback)

    assert {:error, {:game_api_rate_limited, remaining_ms}} = GenServer.call(restored, :check)
    assert remaining_ms >= 59_000
    assert :ok = GenServer.call(restored, :reset)
    GenServer.stop(restored)
    refute File.exists?(fallback)
  end

  test "restores the newest deadline when primary and fallback both exist" do
    unique = System.unique_integer([:positive])
    primary = Path.join(System.tmp_dir!(), "rate-limit-primary-#{unique}.json")
    fallback = Path.join(System.tmp_dir!(), "rate-limit-newer-fallback-#{unique}.json")
    now = System.system_time(:millisecond)

    File.write!(primary, Jason.encode!(%{"blockedUntilEpochMs" => now + 30_000, "generation" => 1}))
    File.write!(fallback, Jason.encode!(%{"blockedUntilEpochMs" => now + 60_000, "generation" => 2}))

    name = :"rate_limit_newest_#{unique}"

    assert {:ok, owner} =
             RateLimit.start_link(name: name, state_path: primary, fallback_state_path: fallback)

    assert {:error, {:game_api_rate_limited, remaining_ms}} = GenServer.call(owner, :check)
    assert remaining_ms >= 59_000
    assert :ok = GenServer.call(owner, :reset)
    GenServer.stop(owner)
  end

  test "ignores an expired copy when the other persisted cooldown is active" do
    now = System.system_time(:millisecond)

    for active_copy <- [:primary, :fallback] do
      unique = System.unique_integer([:positive])
      primary = Path.join(System.tmp_dir!(), "rate-limit-copy-primary-#{unique}.json")
      fallback = Path.join(System.tmp_dir!(), "rate-limit-copy-fallback-#{unique}.json")

      primary_deadline = if active_copy == :primary, do: now + 60_000, else: now - 1_000
      fallback_deadline = if active_copy == :fallback, do: now + 60_000, else: now - 1_000

      File.write!(primary, Jason.encode!(%{"blockedUntilEpochMs" => primary_deadline, "generation" => 1}))
      File.write!(fallback, Jason.encode!(%{"blockedUntilEpochMs" => fallback_deadline, "generation" => 2}))

      name = :"rate_limit_active_copy_#{unique}"

      assert {:ok, owner} =
               RateLimit.start_link(name: name, state_path: primary, fallback_state_path: fallback)

      assert {:error, {:game_api_rate_limited, remaining_ms}} = GenServer.call(owner, :check)
      assert remaining_ms >= 59_000
      assert :ok = GenServer.call(owner, :reset)
      GenServer.stop(owner)
    end
  end

  test "stays conservatively closed in memory when both durable writes fail" do
    unique = System.unique_integer([:positive])
    primary = "/proc/symphony-rate-limit-primary-#{unique}/state.json"
    fallback = "/proc/symphony-rate-limit-fallback-#{unique}/state.json"
    name = :"rate_limit_no_durable_path_#{unique}"

    assert {:ok, owner} =
             RateLimit.start_link(name: name, state_path: primary, fallback_state_path: fallback)

    assert GenServer.call(owner, {:block_for, 60_000}) >= 899_000
    assert {:error, {:game_api_rate_limited, remaining_ms}} = GenServer.call(owner, :check)
    assert remaining_ms >= 899_000
    GenServer.stop(owner)
  end

  test "restores an expired valid cooldown as open state" do
    path = Path.join(System.tmp_dir!(), "rate-limit-expired-#{System.unique_integer([:positive])}.json")
    fallback = path <> ".fallback"

    File.write!(
      path,
      Jason.encode!(%{
        "blockedUntilEpochMs" => System.system_time(:millisecond) - 1_000,
        "generation" => 7
      })
    )

    name = :"rate_limit_expired_#{System.unique_integer([:positive])}"

    assert {:ok, owner} =
             RateLimit.start_link(name: name, state_path: path, fallback_state_path: fallback)

    assert :ok = GenServer.call(owner, :check)
    assert :ok = GenServer.call(owner, :reset)
    GenServer.stop(owner)
  end

  test "fails closed when persisted circuit state is corrupt or unusable" do
    corrupt = Path.join(System.tmp_dir!(), "rate-limit-corrupt-#{System.unique_integer([:positive])}.json")

    File.write!(
      corrupt,
      Jason.encode!(%{
        "blockedUntilEpochMs" => System.system_time(:millisecond) + 60_000,
        "generation" => -1
      })
    )

    corrupt_name = :"rate_limit_corrupt_#{System.unique_integer([:positive])}"
    assert {:ok, corrupt_owner} = RateLimit.start_link(name: corrupt_name, state_path: corrupt)
    assert {:error, {:game_api_rate_limited, corrupt_remaining}} = GenServer.call(corrupt_owner, :check)
    assert corrupt_remaining >= 899_000
    GenServer.stop(corrupt_owner)

    parent = Path.join(System.tmp_dir!(), "rate-limit-parent-#{System.unique_integer([:positive])}")
    File.write!(parent, "not-a-directory")
    invalid_path = Path.join(parent, "state.json")
    invalid_fallback = Path.join(System.tmp_dir!(), "rate-limit-invalid-fallback-#{System.unique_integer([:positive])}.json")
    invalid_name = :"rate_limit_invalid_#{System.unique_integer([:positive])}"

    assert {:ok, invalid_owner} =
             RateLimit.start_link(
               name: invalid_name,
               state_path: invalid_path,
               fallback_state_path: invalid_fallback
             )

    assert {:error, {:game_api_rate_limited, invalid_remaining}} = GenServer.call(invalid_owner, :check)
    assert invalid_remaining >= 899_000
    assert GenServer.call(invalid_owner, {:block_for, 60_000}) >= 899_000
    GenServer.stop(invalid_owner)

    File.rm(corrupt)
    File.rm(parent)
    File.rm(invalid_fallback)
  end

  test "client responses open the circuit before another request can acquire a permit" do
    assert {:ok, permit} = RateLimit.acquire()

    assert {:error, {:game_api_rate_limited, retry_ms}} =
             Client.handle_result(
               {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}}},
               permit
             )

    assert retry_ms >= 30_000
    assert {:error, {:game_api_rate_limited, _remaining_ms}} = RateLimit.acquire()

    RateLimit.reset()
    assert {:ok, permit} = RateLimit.acquire()

    assert {:error, {:game_api_temporarily_unavailable, 502, transient_ms}} =
             Client.handle_result({:ok, %Req.Response{status: 502, headers: %{}}}, permit)

    assert transient_ms >= 30_000

    RateLimit.reset()
    assert {:ok, permit} = RateLimit.acquire()
    assert {:ok, %{"ok" => true}} = Client.handle_result({:ok, %Req.Response{status: 200, body: %{"ok" => true}}}, permit)
    assert :ok = RateLimit.check()

    assert {:ok, permit} = RateLimit.acquire()

    assert {:error, {:game_api_authentication_failed, 401, auth_remaining_ms}} =
             Client.handle_result({:ok, %Req.Response{status: 401, body: %{"error" => "unauthorized"}}}, permit)

    assert auth_remaining_ms >= 899_000
    RateLimit.reset()

    assert {:ok, permit} = RateLimit.acquire()
    assert {:error, {:game_api_request_failed, :timeout}} = Client.handle_result({:error, :timeout}, permit)
    assert {:error, {:game_api_rate_limited, _remaining_ms}} = RateLimit.acquire()
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

  defp expire_circuit do
    :sys.replace_state(RateLimit, fn state ->
      %{state | deadline: System.monotonic_time(:millisecond) - 1}
    end)

    :ok
  end
end
