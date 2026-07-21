defmodule SymphonyElixir.CommandPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.CommandPolicy

  test "blocks gh across direct, absolute, env and shell-wrapper invocations" do
    commands = [
      "gh pr view 32",
      "/usr/local/bin/gh issue list",
      "env GH_HOST=github.com gh pr checks 32",
      "command /usr/bin/gh api repos/acancelas/symphony",
      "bash -lc 'gh pr merge 32'",
      "git status && /opt/tools/gh.exe pr view"
    ]

    Enum.each(commands, fn command ->
      assert {:error, %{code: "direct_gh_blocked", replacement: replacement}} =
               CommandPolicy.inspect_command(command)

      assert replacement =~ "bos-mcp"
    end)
  end

  test "blocks direct GitHub REST and GraphQL targets and redacts sensitive summaries" do
    assert {:error, %{code: "direct_github_api_blocked"}} =
             CommandPolicy.inspect_command("curl https://api.github.com/repos/acancelas/symphony")

    assert {:error, %{code: "direct_github_api_blocked", command_summary: summary}} =
             CommandPolicy.inspect_command("wget https://github.com/graphql authorization=should-not-survive")

    refute summary =~ "should-not-survive"
    assert summary =~ "[REDACTED]"
  end

  test "allows local git transport and unrelated commands" do
    assert :ok = CommandPolicy.inspect_command("git fetch origin --prune")
    assert :ok = CommandPolicy.inspect_command("git push origin HEAD:bos/issue-11")
    assert :ok = CommandPolicy.inspect_command("mix test")
    assert :ok = CommandPolicy.inspect_command(["git", "status", "--short"])
    assert :ok = CommandPolicy.inspect_command("FOO=bar git status")
    assert :ok = CommandPolicy.inspect_command("sudo")
    assert :ok = CommandPolicy.inspect_command("env")
    assert :ok = CommandPolicy.inspect_command(nil)
  end
end
