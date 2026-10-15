defmodule SymphonyElixir.GovernanceBootstrapTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GovernanceDossier
  alias SymphonyElixir.GameApi.{Client, ProviderCircuit}

  defmodule Catalog do
    def load(_),
      do: {:ok, %{"committee" => Enum.map(~w(business-challenger product cro seo ux legal security architecture qa operations), &%{"id" => &1}), "roles" => [%{"id" => "governance-arbiter"}]}}
  end

  defmodule Candidate do
    def confirm(workspace, _, _) do
      {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      {:ok, %{head_sha: String.trim(sha), branch: "issue/69"}}
    end
  end

  defmodule WorkspaceFixture do
    def create_for_issue(_, _), do: {:ok, Process.get(:bootstrap_workspace)}
    def run_before_run_hook(_, _, _), do: :ok
    def run_after_run_hook(_, _, _), do: :ok
  end

  def trace(event), do: Process.put(:bootstrap_trace, Process.get(:bootstrap_trace, []) ++ [event])

  defmodule Http do
    import ExUnit.Assertions

    def request(options) do
      assert {"authorization", "Bearer fixture-signed-coordinator"} in options[:headers]
      refute Enum.any?(options[:headers], fn {k, _} -> k == "x-internal-token" end)
      path = URI.parse(options[:url]).path
      state = Process.get(:bootstrap_state)

      cond do
        String.ends_with?(path, "/goals/planning") ->
          proposal = Process.get(:bootstrap_goal_proposal)
          hash = if is_map(proposal), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(SymphonyElixir.Audit.CanonicalJson.encode(proposal))), case: :lower)
          reply(200, %{"proposal" => proposal, "review" => nil, "goalBreakdownHash" => hash})

        String.ends_with?(path, "/goals/execution") ->
          reply(200, %{"proposal" => Process.get(:bootstrap_goal_execution), "approval" => nil})

        String.ends_with?(path, "/goals/breakdown-approval-requests") ->
          assert get_in(state, ["phases", "planning", "verdict", "status"]) == "passed"
          assert state["readiness"] == nil
          SymphonyElixir.GovernanceBootstrapTest.trace(:goal_approval_queue)
          reply(200, %{"status" => "completed"})

        String.ends_with?(path, "/issues/claim") ->
          SymphonyElixir.GovernanceBootstrapTest.trace(:lease)
          reply(200, %{"status" => "completed", "claim" => %{"runId" => "fresh_run", "runnerId" => "x1"}, "issue" => %{"labels" => ["agent:running"]}})

        String.ends_with?(path, "/issues/69") ->
          digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, Process.get(:bootstrap_issue_body)), case: :lower)
          reply(200, %{"governance" => state, "definitionDigest" => digest})

        String.ends_with?(path, "/artifacts/attempts") ->
          reply(200, %{"artifacts" => Process.get(:bootstrap_attempts, [])})

        String.ends_with?(path, "/runs/fresh_run") ->
          if run = Process.get(:bootstrap_run), do: reply(200, run), else: reply(404, %{})

        String.ends_with?(path, "/artifacts") ->
          body = options[:json]
          refute Map.has_key?(body, "auditBatch")
          artifact = body["artifact"]

          case body["kind"] do
            "run" ->
              SymphonyElixir.GovernanceBootstrapTest.trace(:run)
              Process.put(:bootstrap_run, artifact)
              reply(200, %{"status" => "completed"})

            "attempt_started" ->
              if get_in(state, ["readiness", "state"]) == "READY" do
                SymphonyElixir.GovernanceBootstrapTest.trace(:implementation_attempt)
                Process.put(:bootstrap_attempts, [artifact])
                reply(200, %{"status" => "completed"})
              else
                reply(422, %{"error" => "governance_readiness_required"})
              end
          end

        true ->
          flunk("Unexpected normalized backend path #{path}")
      end
    end

    defp reply(status, body), do: {:ok, %Req.Response{status: status, body: body}}
  end

  defmodule Broker do
    def capabilities(_, _), do: {:ok, %{read_only: :enforced, tool_allowlist: :enforced, minimal_environment: :enforced, read_roots: :enforced, private_mcp_credentials: :enforced}}

    import ExUnit.Assertions
    alias SymphonyElixir.GovernanceBootstrapTest, as: Test
    def identity(context, role), do: {:ok, %{machine_id: "machine-subject-" <> role, role: role, repository_id: context.issue.native_ref["repositoryId"]}}

    def draft(_context, _prompt, policy) do
      assert policy.sandbox["type"] == "readOnly"
      assert policy.native_operations == [:read]
      assert Process.get(:bootstrap_run) != nil
      assert Process.get(:bootstrap_attempts, []) == []
      Test.trace(:draft)
      if Process.get(:change_definition_during_draft), do: Process.put(:bootstrap_issue_body, "Concurrent change\n" <> Process.get(:bootstrap_issue_body))
      {:ok, %{"plan" => "# Original authorized task plan\n", "manifest" => %{"scope" => ["product"], "acceptanceCriteria" => ["product works"], "requirements" => ["product-1"]}}}
    end

    def run(context, role, prompt, policy) do
      assert context.principal.machine_id == "machine-subject-" <> role
      assert String.contains?(prompt, "Effective public M2M machineId: machine-subject-" <> role)

      if policy[:execution_scope] == :implementation do
        assert get_in(Process.get(:bootstrap_state), ["readiness", "state"]) == "READY"
        assert length(Process.get(:bootstrap_attempts)) == 1
        Test.trace(:product_session)
        :ok
      else
        if String.contains?(prompt, "bos_propose_goal_breakdown") do
          Process.put(:bootstrap_goal_proposal, %{"rationale" => "Original Goal", "capabilities" => [%{"key" => "product"}], "dependencies" => [], "risks" => []})
          Process.put(:bootstrap_goal_execution, %{"version" => 1})
          Test.trace(:goal_proposals)
          :ok
        else
          case Regex.run(~r/Required artifact base: (.*)\. Add a concise/, prompt) do
            [_, json] ->
              record(context, role, Jason.decode!(json), policy)

            nil ->
              Test.trace(:scoped_finalizer)
              :ok
          end
        end
      end
    end

    defp record(context, role, artifact, policy) do
      assert policy.sandbox["type"] == "readOnly"
      state = Process.get(:bootstrap_state)
      phase = artifact["phase"]
      event = artifact["event"]
      identity = %{"type" => "agent", "subjectId" => context.principal.machine_id}

      state =
        case event do
          "candidate" ->
            put_in(state, ["phases", phase], Map.merge(artifact, %{"votes" => %{}, "verdict" => nil, "exception" => nil}))

          "round_started" ->
            state |> put_in(["counters", phase], artifact["round"]) |> put_in(["phases", phase, "round"], artifact["round"])

          "applicability" ->
            applicable = role == "qa"

            if applicable do
              review = %{"reviewId" => "review_#{phase}_qa", "actor" => identity, "status" => "passed", "commitSha" => artifact["candidateCommitSha"]}
              assert review["actor"]["subjectId"] == "machine-subject-qa"
              refute review["actor"]["subjectId"] == "qa"
              Process.put(:bootstrap_reviews, [review | Process.get(:bootstrap_reviews, [])])
            end

            vote = Map.merge(artifact, %{"actor" => identity, "applicable" => applicable, "status" => "passed"})
            put_in(state, ["phases", phase, "votes", role], vote)

          "verdict" ->
            assert map_size(get_in(state, ["phases", phase, "votes"])) == 10
            assert Enum.any?(Process.get(:bootstrap_reviews), &(&1["commitSha"] == artifact["candidateCommitSha"]))
            put_in(state, ["phases", phase, "verdict"], Map.merge(artifact, %{"actor" => identity, "status" => "passed", "verdict" => "APPROVED"}))

          "readiness" ->
            assert get_in(state, ["phases", "planning", "verdict", "status"]) == "passed"
            {_, 0} = System.cmd("git", ["--version"])

            Process.put(:bootstrap_environment_evidence, %{
              "phase" => "readiness",
              "commitSha" => artifact["candidateCommitSha"],
              "checks" => [%{"id" => "environment", "verified" => true, "status" => "passed"}]
            })

            Test.trace(:ready)
            Map.put(state, "readiness", Map.merge(artifact, %{"state" => "READY", "status" => "passed"}))
        end

      Process.put(:bootstrap_state, state)
      :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "governance-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    owner = "governance-bootstrap-#{System.unique_integer([:positive])}"
    register_process_cleanup!(owner)
    old_owner = System.get_env("SYMPHONY_TEST_PROCESS_OWNER")
    System.put_env("SYMPHONY_TEST_PROCESS_OWNER", owner)
    env = owned_process_environment(owner)

    for args <- [["init", "-b", "issue/69"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"]] do
      {_, 0} = System.cmd("git", args, cd: root, env: env)
    end

    File.write!(Path.join(root, "product.txt"), "original product\n")
    {_, 0} = System.cmd("git", ["add", "product.txt"], cd: root, env: env)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial fixture"], cd: root, env: env)
    Process.put(:bootstrap_workspace, root)
    Process.put(:bootstrap_issue_body, "Visible original requirement\n<!-- original unchanged marker -->")
    Process.put(:bootstrap_state, %{"phases" => %{}, "counters" => %{"planning" => 0, "implementation" => 0, "technical" => 0, "transport" => 0}, "readiness" => nil})
    previous = for key <- [:governance, :game_api_http_client_module, :game_api_client_module], into: %{}, do: {key, Application.get_env(:symphony_elixir, key)}
    old_target = System.get_env("BOS_API_TARGET_PROJECT_ID")
    System.put_env("BOS_API_TARGET_PROJECT_ID", "fixture-control-plane")
    old_token = System.get_env("BOS_TEST_COORDINATOR_JWT")
    System.put_env("BOS_TEST_COORDINATOR_JWT", "fixture-signed-coordinator")
    Application.put_env(:symphony_elixir, :governance, session_broker: Broker, coordinator_repositories: %{"bos-front" => %{token_env: "BOS_TEST_COORDINATOR_JWT"}})
    Application.put_env(:symphony_elixir, :game_api_http_client_module, Http)
    Application.put_env(:symphony_elixir, :game_api_client_module, Client)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "game_api",
      tracker_endpoint: "https://game-api.test",
      tracker_provider: %{"repositories" => [%{"repository_id" => "bos-front", "owner" => "acancelas", "repo" => "bos-front"}]}
    )

    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    assert Config.settings!().tracker.kind == "game_api"
    ProviderCircuit.reset_for_test()

    on_exit(fn ->
      for {key, value} <- previous, do: if(value == nil, do: Application.delete_env(:symphony_elixir, key), else: Application.put_env(:symphony_elixir, key, value))
      restore_env("BOS_TEST_COORDINATOR_JWT", old_token)
      restore_env("SYMPHONY_TEST_PROCESS_OWNER", old_owner)
      restore_env("BOS_API_TARGET_PROJECT_ID", old_target)
      ProviderCircuit.reset_for_test()
      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "bos-front#69",
      identifier: "bos-front-69",
      title: "Fresh authorized task",
      labels: ["bos:issue"],
      branch_name: "issue/69",
      native_ref: %{"repositoryId" => "bos-front", "issueNumber" => 69, "governance" => Process.get(:bootstrap_state)}
    }

    %{
      root: root,
      issue: issue,
      opts: [workspace_module: WorkspaceFixture, candidate_head_module: Candidate, governance_catalog_module: Catalog, governance_session_broker: Broker, game_api_client_module: Client]
    }
  end

  test "fresh Issue reserves and plans before first implementation Attempt/session", %{issue: issue, opts: opts, root: root} do
    refute File.exists?(Path.join(root, "docs"))
    assert get_in(Process.get(:bootstrap_state), ["phases"]) == %{}
    assert {:ok, claimed} = Tracker.claim_issue(issue)
    assert :ok = AgentRunner.run_on_worker_host_for_test(claimed, opts)
    trace = Process.get(:bootstrap_trace)
    position = fn event -> Enum.find_index(trace, &(&1 == event)) end
    assert position.(:lease) < position.(:run)
    assert position.(:run) < position.(:draft)
    assert position.(:draft) < position.(:ready)
    assert position.(:ready) < position.(:implementation_attempt)
    assert position.(:implementation_attempt) < position.(:product_session)
    assert List.last(trace) == :scoped_finalizer
    assert File.read!(Path.join(root, "product.txt")) == "original product\n"
    assert Process.get(:bootstrap_environment_evidence)["phase"] == "readiness"
    assert length(Process.get(:bootstrap_reviews)) == 2
  end

  test "missing coordinator credential prevents even claim", %{issue: issue} do
    System.delete_env("BOS_TEST_COORDINATOR_JWT")
    assert {:error, :governance_coordinator_credential_missing} = Tracker.claim_issue(issue)
    assert Process.get(:bootstrap_trace, []) == []
  end

  test "Attempt cannot begin without server READY", %{issue: issue} do
    assert {:ok, claimed} = Tracker.claim_issue(issue)
    assert {:ok, ^claimed} = Client.start_coordination(claimed)
    assert {:error, {:game_api_http_error, 422}} = Client.start_execution(claimed, 1)
    assert Process.get(:bootstrap_attempts, []) == []
  end

  test "draft output cannot request a product edit", %{issue: issue, root: root} do
    draft = %{"plan" => "plan", "manifest" => %{"scope" => [], "acceptanceCriteria" => [], "requirements" => []}, "files" => %{"product.txt" => "changed"}}
    assert {:error, :governance_dossier_write_rejected} = GovernanceDossier.commit(root, issue, draft)
    assert File.read!(Path.join(root, "product.txt")) == "original product\n"
    refute File.exists?(Path.join(root, "docs"))
  end

  test "dossier refuses symlink destinations", %{issue: issue, root: root} do
    File.ln_s!(root, Path.join(root, "docs"))
    draft = %{"plan" => "plan", "manifest" => %{"scope" => [], "acceptanceCriteria" => [], "requirements" => []}}
    assert {:error, :governance_dossier_write_rejected} = GovernanceDossier.commit(root, issue, draft)
    refute File.exists?(Path.join(root, "issues"))
  end

  test "visible body edit with unchanged marker blocks existing plan without rewrite", %{issue: issue, opts: opts, root: root} do
    assert {:ok, claimed} = Tracker.claim_issue(issue)
    assert :ok = AgentRunner.run_on_worker_host_for_test(claimed, opts)
    {before_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    body = Process.get(:bootstrap_issue_body)
    marker = "<!-- original unchanged marker -->"
    assert String.contains?(body, marker)
    Process.put(:bootstrap_issue_body, "New manual visible requirement\n" <> marker)
    Process.put(:bootstrap_trace, [])
    assert {:error, :governance_definition_conflict} = SymphonyElixir.GovernanceCoordinator.run(:planning, root, claimed, nil, opts, nil)
    refute :draft in Process.get(:bootstrap_trace)
    assert {^before_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
  end

  test "concurrent visible definition edit during readOnly draft prevents dossier write", %{issue: issue, opts: opts, root: root} do
    Process.put(:change_definition_during_draft, true)
    assert {:ok, claimed} = Tracker.claim_issue(issue)
    assert {:error, :governance_definition_conflict} = AgentRunner.run_on_worker_host_for_test(claimed, opts)
    refute File.exists?(Path.join(root, "docs"))
    refute :implementation_attempt in Process.get(:bootstrap_trace)
    assert File.read!(Path.join(root, "product.txt")) == "original product\n"
  end

  test "new Goal reaches single approval queue through canonical committee without READY or product Attempt", %{issue: issue, opts: opts, root: root} do
    issue = %{issue | labels: ["bos:goal"]}
    assert Process.get(:bootstrap_goal_proposal) == nil
    assert {:ok, claimed} = Tracker.claim_issue(issue)
    assert :ok = AgentRunner.run_on_worker_host_for_test(claimed, opts)
    trace = Process.get(:bootstrap_trace)
    assert :goal_proposals in trace
    assert List.last(trace) == :goal_approval_queue
    refute :ready in trace
    refute :implementation_attempt in trace
    refute :product_session in trace
    manifest = File.read!(Path.join(root, "docs/issues/69/manifest.json")) |> Jason.decode!()
    assert String.starts_with?(manifest["goalBreakdownHash"], "sha256:")
    Process.put(:bootstrap_goal_proposal, %{Process.get(:bootstrap_goal_proposal) | "capabilities" => [%{"key" => "different"}]})
    assert {:error, :governance_definition_conflict} = SymphonyElixir.GovernanceCoordinator.run(:planning, root, claimed, nil, Keyword.put(opts, :governance_require_ready, false), nil)
  end
end
