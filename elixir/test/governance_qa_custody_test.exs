defmodule SymphonyElixir.GovernanceQaCustodyTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceExecutionMonitor, as: Monitor
  alias SymphonyElixir.GovernanceProcess

  defp retired_primary do
    port = Port.open({:spawn_executable, ~c"/usr/bin/cat"}, [:binary, :exit_status])
    admission = %{"deadline" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 30)), "reservedDurationSeconds" => 30, "reservedUncachedInputTokens" => 1000}
    {:ok, monitor} = Monitor.start(port, admission, fn -> :ok end, fn _ -> :ok end, System.monotonic_time(:millisecond), "fixture-thread")

    Monitor.usage(monitor, %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{"threadId" => "fixture-thread", "turnId" => "turn-one", "tokenUsage" => %{"total" => %{"inputTokens" => 10, "cachedInputTokens" => 4}}}
    })

    assert :ok = Monitor.inference_finished(monitor)
    GovernanceProcess.stop(port)
    assert :ok = Monitor.worker_retired(monitor)
    monitor
  end

  test "monitor owns QA transport, forwards exact output and reaps it on finish" do
    monitor = retired_primary()
    assert {:ok, port} = Monitor.open_command(monitor, "/usr/bin/printf", [:binary, :exit_status, {:args, ["qa-forwarded"]}])
    assert_receive {^port, {:data, "qa-forwarded"}}, 2000
    assert_receive {^port, {:exit_status, 0}}, 2000
    assert {:ok, %{uncachedInputTokens: 6}} = Monitor.finish(monitor)
  end

  test "loss of the logical Run owner reaps QA even though the BEAM host stays alive" do
    parent = self()

    owner =
      spawn(fn ->
        monitor = retired_primary()
        {:ok, port} = Monitor.open_command(monitor, "/usr/bin/cat", [:binary, :exit_status])
        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:qa, monitor, pid})

        receive do
          :hold -> :ok
        end
      end)

    assert_receive {:qa, monitor, pid}, 3000
    Process.exit(owner, :kill)
    wait_absent(pid, System.monotonic_time(:millisecond) + 2000)
    refute Process.alive?(monitor)
    assert {:error, :enoent} = File.lstat("/proc/#{pid}")
  end

  defp wait_absent(pid, deadline) do
    if File.exists?("/proc/#{pid}") and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      wait_absent(pid, deadline)
    end
  end
end
