defmodule SymphonyElixir.GovernanceBrokerLifecycleTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceAppServerBroker

  test "native preflight accepts serde empty hook arrays and disabled providers, rejects merged live entries" do
    config = %{"mcp_servers" => %{"bos-mcp" => %{"enabled" => false}, "codebase-memory" => %{"enabled" => false}}, "plugins" => %{}, "hooks" => %{"SessionStart" => [], "UserPromptSubmit" => []}}
    assert GovernanceAppServerBroker.native_providers_disabled?(config)
    refute GovernanceAppServerBroker.native_providers_disabled?(put_in(config, ["mcp_servers", "bos-mcp", "enabled"], true))
    refute GovernanceAppServerBroker.native_providers_disabled?(put_in(config, ["mcp_servers", "other"], %{}))
    refute GovernanceAppServerBroker.native_providers_disabled?(put_in(config, ["hooks", "SessionStart"], [%{"command" => "untrusted"}]))
  end

  defmodule PrivateTransport do
    use GenServer
    def init(owner), do: {:ok, owner}
    def terminate(_, owner), do: send(owner, {:private_transport_closed, self()})
  end

  test "release closes all versioned connections for this role and Run without touching another Run" do
    context = %{workspace: "/owned/task", issue: %{native_ref: %{"repositoryId" => "repo", "runId" => "run"}}}
    versions = [{"planning", nil, nil}, {"planning", "plan-one", "sha-one"}, {"implementation", "plan-one", "sha-two"}]

    clients =
      for {phase, plan, sha} <- versions do
        {:ok, client} = GenServer.start_link(PrivateTransport, self())
        Process.put({GovernanceAppServerBroker, "repo", "run", "/owned/task", "security", phase, plan, sha}, %{client: client})
        client
      end

    {:ok, other} = GenServer.start_link(PrivateTransport, self())
    other_key = {GovernanceAppServerBroker, "repo", "another-run", "/owned/task", "security", "planning", nil, nil}
    Process.put(other_key, %{client: other})
    assert :ok = GovernanceAppServerBroker.release(context, "security")

    for client <- clients do
      assert_receive {:private_transport_closed, ^client}
      refute Process.alive?(client)
    end

    assert Process.alive?(other)
    assert Process.get(other_key).client == other
    Process.delete(other_key)
    GenServer.stop(other)
  end
end
