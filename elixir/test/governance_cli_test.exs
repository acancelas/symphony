defmodule SymphonyElixir.GovernanceCLITest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceCLI
  alias SymphonyElixir.GovernanceHostConfig

  test "one-shot parser fails closed before a host configuration, rejects duplicates and arbitrary phase" do
    scheduler_before = Process.whereis(SymphonyElixir.Orchestrator)

    for args <- [
          [],
          ["--phase", "planning"],
          ["--phase", "execute"],
          ["--phase", "planning", "--phase", "implementation"],
          ["--token", "not-allowed"]
        ] do
      assert {:error, _} = GovernanceCLI.evaluate(args)
      assert Process.get(:symphony_governance_runtime_settings) == nil
    end

    assert Process.whereis(SymphonyElixir.Orchestrator) == scheduler_before
  end

  test "candidate confirmation uses explicit canonical remote without changing shared origin" do
    sha = String.duplicate("a", 40)
    remote = "https://github.com/acancelas/symphony.git"

    runner = fn "/owned/task", nil, "git", arguments ->
      send(self(), {:git_arguments, arguments})

      output =
        case arguments do
          ["status" | _] -> ""
          ["rev-parse", "HEAD"] -> sha
          ["symbolic-ref", "--short", "HEAD"] -> "issue/69-agent-governance"
          ["ls-remote", "--heads", ^remote, _] -> sha <> "\trefs/heads/issue/69-agent-governance\n"
        end

      {:ok, {output, 0}}
    end

    issue = %SymphonyElixir.Tracker.Issue{branch_name: "issue/69-agent-governance"}

    assert {:ok, %{head_sha: ^sha}} =
             SymphonyElixir.CandidateHead.confirm("/owned/task", issue, nil, command_runner: runner, remote: remote)

    assert_received {:git_arguments, ["ls-remote", "--heads", ^remote, "refs/heads/issue/69-agent-governance"]}
    refute_received {:git_arguments, ["remote" | _]}
  end

  test "host configuration rejects unpinned shape, inline secrets, production and weak file modes" do
    path = Path.join(System.tmp_dir!(), "governance-config-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    mcp = Map.new(~w(executable executable_sha256 entrypoint build_root receipt_path receipt_sha256), &{&1, "host-pin"})

    runtime =
      Map.new(
        ~w(package_root receipt_path receipt_sha256 executable executable_sha256 proof_path proof_sha256 vendor_root auth_home worker_root native_config_sha256 disabled_mcp_servers),
        &{&1, "host-pin"}
      )

    base = %{
      "service_subject" => "one-service",
      "service_secret_file" => "/private/existing.env",
      "catalog_path" => "/catalog",
      "allowed_authenticated_by" => ["bos-host-hmac-v2"],
      "repositories" => %{"repo" => %{}},
      "workspaces" => %{"repo" => ["/owned/task"]},
      "api_base_url" => "http://127.0.0.1:8110",
      "target_project_id" => "project",
      "private_home" => "/private",
      "private_cache_root" => "/private/cache",
      "mcp" => mcp,
      "runtime" => runtime
    }

    File.write!(path, Jason.encode!(base))
    File.chmod!(path, 0o600)
    assert {:ok, _} = GovernanceHostConfig.load(path)

    for settings <- [
          nil,
          %{},
          %{"enabled" => false},
          %{"enabled" => true, "contract_path" => "/schema", "contract_sha256" => "pin", "provenance" => %{"epoch" => "preserved-string-key"}, "custody" => %{"directory" => "/private"}}
        ] do
      File.write!(path, Jason.encode!(Map.put(base, "observed_snapshot", settings)))
      assert {:ok, config} = GovernanceHostConfig.load(path)

      if settings && settings["enabled"] == true do
        assert config.observed_snapshot.provenance == %{"epoch" => "preserved-string-key"}
        assert config.observed_snapshot.custody == %{"directory" => "/private"}
      end
    end

    for settings <- [%{"enabled" => "true"}, %{"enabled" => true}, %{"enabled" => false, "unknown" => true}, "invalid"] do
      File.write!(path, Jason.encode!(Map.put(base, "observed_snapshot", settings)))
      assert {:error, _} = GovernanceHostConfig.load(path)
    end

    for changed <- [
          Map.put(base, "api_base_url", "https://api.production.example"),
          Map.put(base, "service_secret", "inline-forbidden"),
          put_in(base, ["mcp"], %{}),
          Map.put(base, "api_base_url", "http://user:password@127.0.0.1:8110")
        ] do
      File.write!(path, Jason.encode!(changed))
      assert {:error, _} = GovernanceHostConfig.load(path)
    end

    File.write!(path, Jason.encode!(base))
    File.chmod!(path, 0o644)
    assert {:error, _} = GovernanceHostConfig.load(path)
  end
end
