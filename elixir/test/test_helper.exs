ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

# All tests, including restarted applications, must remain outside the live outbox.
test_outbox_root = Path.join(System.tmp_dir!(), "symphony-test-outbox-#{System.unique_integer([:positive])}")
System.put_env("BOS_OUTBOX_ROOT", test_outbox_root)
ExUnit.after_suite(fn _result -> File.rm_rf!(test_outbox_root) end)

# Loading the shared support modules can unload the application in local Mix
# runs. Restore the runtime explicitly so tests never depend on CI-only startup
# state or a tracker credential being present in the shell.
{:ok, _started} = Application.ensure_all_started(:symphony_elixir)
