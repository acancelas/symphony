ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

test_outbox_root =
  Path.join(System.tmp_dir!(), "symphony-test-outbox-#{System.unique_integer([:positive])}")

test_rate_limit_state =
  Path.join(System.tmp_dir!(), "symphony-test-rate-limit-#{System.unique_integer([:positive])}.json")

test_rate_limit_fallback_state =
  Path.join(System.tmp_dir!(), "symphony-test-rate-limit-fallback-#{System.unique_integer([:positive])}.json")

System.put_env("BOS_OUTBOX_ROOT", test_outbox_root)
System.put_env("BOS_RATE_LIMIT_STATE_PATH", test_rate_limit_state)
System.put_env("BOS_RATE_LIMIT_FALLBACK_STATE_PATH", test_rate_limit_fallback_state)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(test_outbox_root)
  File.rm(test_rate_limit_state)
  File.rm(test_rate_limit_fallback_state)
end)

# Loading the shared support modules can unload the application in local Mix
# runs. Restore the runtime explicitly so tests never depend on CI-only startup
# state or a tracker credential being present in the shell.
{:ok, _started} = Application.ensure_all_started(:symphony_elixir)
