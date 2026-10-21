defmodule SymphonyElixir.GovernanceCoordinatorTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceCatalog
  alias SymphonyElixir.GovernanceCoordinator
  alias SymphonyElixir.GovernanceSession
  alias SymphonyElixir.Tracker.Issue

  defmodule Client do
    def fetch_issue(_, _), do: {:ok, %{"governance" => Process.get(:gov_state)}}
  end

  defmodule Broker do
    def capabilities(_, _),
      do:
        {:ok,
         %{
           read_only: :enforced,
           tool_allowlist: :enforced,
           minimal_environment: :enforced,
           read_roots: :enforced,
           private_mcp_credentials: :enforced
         }}

    @behaviour GovernanceSession
    def identity(context, role),
      do: {:ok, %{machine_id: "verified-" <> role, role: role, repository_id: context.issue.native_ref["repositoryId"]}}

    def run(context, role, prompt, policy) do
      [_, json] = Regex.run(~r/Required artifact base: (.*)\. Add a concise/, prompt)
      artifact = Jason.decode!(json)
      event = artifact["event"]
      calls = Process.get(:gov_calls, [])
      Process.put(:gov_calls, calls ++ [{role, event, artifact, policy}])

      cond do
        Process.get(:gov_failure) == {role, event} ->
          {:error, :transport_interrupted}

        Process.get(:gov_missing) == event ->
          :ok

        true ->
          state = Process.get(:gov_state)
          phase = get_in(state, ["phases", context.phase])

          state = apply_event(state, event, context, artifact, role)

          Process.put(:gov_state, state)
          assert phase == nil or is_map(phase)
          :ok
      end
    end

    defp apply_event(state, event, context, artifact, role) do
      case event do
        "candidate" ->
          put_in(
            state,
            ["phases", context.phase],
            Map.merge(artifact, %{"votes" => %{}, "verdict" => nil, "exception" => nil})
          )

        "round_started" ->
          state
          |> put_in(["phases", context.phase, "round"], artifact["round"])
          |> put_in(["counters", context.phase], artifact["round"])

        "applicability" ->
          put_in(
            state,
            ["phases", context.phase, "votes", role],
            Map.merge(artifact, %{"applicable" => false, "summary" => "No affected flow"})
          )

        "verdict" ->
          put_in(
            state,
            ["phases", context.phase, "verdict"],
            Map.merge(artifact, %{"status" => "passed", "verdict" => "APPROVED"})
          )

        "exception" ->
          put_in(
            state,
            ["phases", context.phase, "exception"],
            Map.put(artifact, "summary", "Independent evidence justifies one final review")
          )

        "readiness" ->
          Map.put(state, "readiness", Map.merge(artifact, %{"status" => "passed", "state" => "READY"}))
      end
    end
  end

  defmodule UnisolatedBroker do
    def identity(context, role), do: Broker.identity(context, role)
    def capabilities(_, _), do: {:ok, %{read_only: :enforced}}
    def run(_, _, _, _), do: raise("must never start an unisolated agent")
  end

  setup do
    roles =
      Enum.map(
        ~w(business-challenger product cro seo ux legal security architecture qa operations),
        &%{"id" => &1, "kind" => "specialist"}
      )

    issue = %Issue{
      id: "symphony#69",
      native_ref: %{"repositoryId" => "symphony", "issueNumber" => 69, "runId" => "run_69"}
    }

    context = %{
      workspace: "/unused",
      issue: issue,
      recipient: nil,
      worker_host: nil,
      phase: "planning",
      client: Client,
      broker: Broker,
      catalog: %{"committee" => roles, "roles" => roles ++ [%{"id" => "governance-arbiter"}]},
      manifest: %{"planHash" => "sha256:" <> String.duplicate("a", 64)},
      sha: String.duplicate("b", 40)
    }

    state = %{
      "counters" => %{"planning" => 0, "implementation" => 0, "technical" => 8, "transport" => 5},
      "phases" => %{},
      "readiness" => nil
    }

    Process.put(:gov_state, state)
    %{context: context, state: state}
  end

  test "all ten roles and independent arbiter precede automatic READY", %{context: c, state: s} do
    assert :ok = GovernanceCoordinator.resume(c, s)
    calls = Process.get(:gov_calls)
    assert Enum.count(calls, fn {_, e, _, _} -> e == "applicability" end) == 10
    assert {"governance-arbiter", "verdict", _, _} = Enum.at(calls, -2)
    assert {"task-orchestrator", "readiness", _, _} = List.last(calls)
    assert get_in(Process.get(:gov_state), ["counters", "planning"]) == 1
    assert get_in(Process.get(:gov_state), ["counters", "technical"]) == 8
    assert get_in(Process.get(:gov_state), ["counters", "transport"]) == 5

    for {_, _, _, policy} <- calls do
      assert policy.sandbox["type"] == "readOnly"
      assert policy.verified_m2m and policy.fresh_session
      refute "bos_transition_issue" in policy.tools
      refute "bos_finalize_run" in policy.tools
    end
  end

  test "restart reuses votes and does not spend another round", %{context: c, state: s} do
    Process.put(:gov_failure, {"seo", "applicability"})
    assert {:error, :transport_interrupted} = GovernanceCoordinator.resume(c, s)
    partial = Process.get(:gov_state)
    assert map_size(get_in(partial, ["phases", "planning", "votes"])) == 3
    Process.delete(:gov_failure)
    Process.put(:gov_calls, [])
    assert :ok = GovernanceCoordinator.resume(c, partial)
    calls = Process.get(:gov_calls)
    refute Enum.any?(calls, fn {_, e, _, _} -> e in ["candidate", "round_started"] end)
    refute Enum.any?(calls, fn {r, _, _, _} -> r in ~w(business-challenger product cro) end)
    assert get_in(Process.get(:gov_state), ["counters", "planning"]) == 1
  end

  test "a confirmed completed committee has no new sessions", %{context: c, state: s} do
    assert :ok = GovernanceCoordinator.resume(c, s)
    Process.put(:gov_calls, [])
    assert :ok = GovernanceCoordinator.resume(c, Process.get(:gov_state))
    assert Process.get(:gov_calls) == []
  end

  test "model success without durable receipt cannot advance", %{context: c, state: s} do
    Process.put(:gov_missing, "candidate")

    assert {:error, {:governance_receipt_missing, "candidate", "task-orchestrator", _}} =
             GovernanceCoordinator.resume(c, s)

    assert get_in(Process.get(:gov_state), ["counters", "planning"]) == 0
  end

  test "third round requires persisted arbiter exception first", %{context: c, state: s} do
    s = put_in(s, ["counters", "planning"], 2)
    Process.put(:gov_state, s)
    assert :ok = GovernanceCoordinator.resume(c, s)
    calls = Process.get(:gov_calls)
    exception = Enum.find_index(calls, fn {_, e, _, _} -> e == "exception" end)
    start = Enum.find_index(calls, fn {_, e, _, _} -> e == "round_started" end)
    assert exception < start
    assert get_in(Process.get(:gov_state), ["counters", "planning"]) == 3
  end

  test "absence of exception cannot silently open round three", %{context: c, state: s} do
    s = put_in(s, ["counters", "planning"], 2)
    Process.put(:gov_state, s)
    Process.put(:gov_missing, "exception")

    assert {:error, {:governance_receipt_missing, "exception", "governance-arbiter", _}} =
             GovernanceCoordinator.resume(c, s)

    assert get_in(Process.get(:gov_state), ["counters", "planning"]) == 2
  end

  test "committee exhaustion cannot replenish through a new candidate", %{context: c, state: s} do
    s = put_in(s, ["counters", "planning"], 3)
    Process.put(:gov_state, s)
    assert {:error, :governance_committee_exhausted} = GovernanceCoordinator.resume(c, s)
    refute Enum.any?(Process.get(:gov_calls), fn {_, e, _, _} -> e == "round_started" end)
  end

  test "implementation has no readiness grant", %{context: c, state: s} do
    c = %{c | phase: "implementation"}
    assert :ok = GovernanceCoordinator.resume(c, s)
    refute Enum.any?(Process.get(:gov_calls), fn {_, e, _, _} -> e == "readiness" end)
  end

  test "legacy is opt in; projection cannot be disabled by option", %{context: c} do
    refute GovernanceCoordinator.enabled?(c.issue, [])
    assert :ok = GovernanceCoordinator.run(:planning, "/missing", c.issue, nil, [], nil)
    issue = %{c.issue | native_ref: Map.put(c.issue.native_ref, "governance", %{})}
    assert GovernanceCoordinator.enabled?(issue, governance_enabled: false)
  end

  test "shared actor routing is not an authentication fallback", %{context: c} do
    assert {:error, :governance_m2m_broker_unavailable} =
             GovernanceSession.run(%{c | broker: nil}, "security", "review", %{})
  end

  test "missing broker stops before Git candidate publication", %{context: c} do
    assert {:error, :governance_m2m_broker_unavailable} =
             GovernanceCoordinator.run(
               :planning,
               "/must-not-touch",
               c.issue,
               nil,
               [governance_enabled: true, governance_session_broker: nil],
               nil
             )
  end

  test "catalog fails closed without exact pinned Git object" do
    assert {:error, :governance_catalog_unconfigured} = GovernanceCatalog.load(nil)
    assert {:error, :governance_catalog_unverified} = GovernanceCatalog.load(System.tmp_dir!())
    assert String.length(GovernanceCatalog.commit()) == 40
  end

  test "readOnly without secret and read-root isolation cannot start a reviewer", %{context: c} do
    assert {:error, :governance_isolation_unavailable} =
             GovernanceSession.run(%{c | broker: UnisolatedBroker}, "security", "review", %{
               sandbox: %{"type" => "readOnly"}
             })
  end
end
