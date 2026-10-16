defmodule SymphonyElixir.GovernancePolicyMaterialTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.PromptBuilder

  setup do
    root = Path.join(System.tmp_dir!(), "bos-policy-material-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "repository")
    auth = Path.join(root, "auth")
    File.mkdir_p!(Path.join(workspace, "elixir/lib/nested"))
    File.mkdir_p!(auth)
    File.write!(Path.join(auth, "AGENTS.md"), "global original\n")
    File.write!(Path.join(workspace, "AGENTS.md"), "repository original\n")
    File.write!(Path.join(workspace, "elixir/AGENTS.md"), "elixir original\n")
    File.write!(Path.join(workspace, "elixir/lib/nested/AGENTS.md"), "nested original\n")
    git(workspace, ["init", "-q"])
    git(workspace, ["add", "."])
    git(workspace, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "policies"])
    {sha, 0} = git(workspace, ["rev-parse", "HEAD"])
    context = %{workspace: workspace, sha: String.trim(sha)}
    configuration = %{auth_home: auth, policy_sources: [pin(Path.join(auth, "AGENTS.md"))], policy_fallback_filenames: []}

    on_exit(fn ->
      true = String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/bos-policy-material-")
      File.rm_rf!(root)
    end)

    {:ok, root: root, context: context, configuration: configuration}
  end

  test "original bytes and all candidate scopes are retained in ordered pinned material", ctx do
    assert {:ok, material} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
    assert Enum.map(material.manifest, & &1["scope"]) == ["GLOBAL", ".", "elixir", "elixir/lib/nested"]

    for text <- ["global original\n", "repository original\n", "elixir original\n", "nested original\n"] do
      assert String.contains?(material.prompt, text)
    end

    assert material.digest =~ ~r/^[a-f0-9]{64}$/
    assert {:ok, ^material} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
  end

  test "global drift, an unpinned ancestor and source policy drift fail closed", ctx do
    path = Path.join(ctx.configuration.auth_home, "AGENTS.md")
    File.write!(path, "changed")
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
    File.write!(path, "global original\n")
    File.write!(Path.join(ctx.root, "AGENTS.md"), "ancestor")
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
    File.rm!(Path.join(ctx.root, "AGENTS.md"))
    File.write!(Path.join(ctx.context.workspace, "elixir/AGENTS.md"), "changed")
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
  end

  test "an unexpected global override cannot bypass the selected policy pin", ctx do
    File.write!(Path.join(ctx.configuration.auth_home, "AGENTS.override.md"), "override")
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, Map.delete(ctx.configuration, :policy_sources))
  end

  test "external symlink aliases are rejected even when content matches the pin", ctx do
    path = Path.join(ctx.configuration.auth_home, "AGENTS.md")
    File.rename!(path, path <> ".original")
    File.ln_s!(path <> ".original", path)
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
  end

  test "a new untracked policy within writable source cannot enter the instruction chain", ctx do
    File.write!(Path.join(ctx.context.workspace, "elixir/lib/AGENTS.override.md"), "untracked")
    assert {:error, _} = PromptBuilder.governed_policy_material(ctx.context, ctx.configuration)
  end

  test "committed override precedence and empty override fallback retain original bytes", ctx do
    workspace = ctx.context.workspace
    File.write!(Path.join(workspace, "elixir/AGENTS.override.md"), "override original\n")
    File.write!(Path.join(workspace, "AGENTS.override.md"), "")
    git(workspace, ["add", "."])
    git(workspace, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "override"])
    {sha, 0} = git(workspace, ["rev-parse", "HEAD"])
    assert {:ok, material} = PromptBuilder.governed_policy_material(%{ctx.context | sha: String.trim(sha)}, ctx.configuration)
    assert String.contains?(material.prompt, "repository original\n")
    assert String.contains?(material.prompt, "override original\n")
    refute String.contains?(material.prompt, "elixir original\n")
  end

  test "global scope covers the source workspace while conflicting siblings remain separate", ctx do
    workspace = ctx.context.workspace
    File.mkdir_p!(Path.join(workspace, "elixir/test"))
    File.write!(Path.join(workspace, "elixir/test/AGENTS.md"), "TEST ONLY: use test-rule\n")
    File.write!(Path.join(workspace, "elixir/lib/AGENTS.md"), "LIB ONLY: use lib-rule\n")
    git(workspace, ["add", "."])
    git(workspace, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "siblings"])
    {sha, 0} = git(workspace, ["rev-parse", "HEAD"])
    assert {:ok, material} = PromptBuilder.governed_policy_material(%{ctx.context | sha: String.trim(sha)}, ctx.configuration)
    global = hd(material.manifest)
    assert global["scope"] == "GLOBAL"
    assert global["scopeKind"] == "global"
    assert global["path"] == Path.join(ctx.configuration.auth_home, "AGENTS.md")
    assert Enum.any?(material.manifest, &(&1["scope"] == "elixir/lib" and &1["scopeKind"] == "repository-subtree"))
    assert Enum.any?(material.manifest, &(&1["scope"] == "elixir/test" and &1["scopeKind"] == "repository-subtree"))
    assert String.contains?(material.prompt, "GLOBAL applies to every operation")
    assert String.contains?(material.prompt, "a sibling subtree policy never applies globally")
    assert String.contains?(material.prompt, "TEST ONLY: use test-rule\n")
    assert String.contains?(material.prompt, "LIB ONLY: use lib-rule\n")
    assert String.contains?(material.prompt, workspace)
  end

  defp pin(path), do: %{"path" => path, "sha256" => Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)}
  defp git(workspace, args), do: System.cmd("/usr/bin/git", args, cd: workspace, stderr_to_stdout: true)
end
