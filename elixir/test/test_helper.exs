ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

# Loading the shared support modules can unload the application in local Mix
# runs. Restore the runtime explicitly so tests never depend on CI-only startup
# state or a tracker credential being present in the shell.
{:ok, _started} = Application.ensure_all_started(:symphony_elixir)
