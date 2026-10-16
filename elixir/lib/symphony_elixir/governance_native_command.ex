defmodule SymphonyElixir.GovernanceNativeCommand do
  @moduledoc "Fixed repository QA argv executed inside the same certified native profile, without a model."
  alias SymphonyElixir.{GovernanceRuntime, GovernanceBuildReceipt, GovernanceProcess, GovernanceWorkspaceProfile}

  def qa(context, configuration, guard) when is_function(guard, 0) do
    execution = configuration.execution

    with true <- context.issue.native_ref["repositoryId"] == "symphony",
         executable when is_binary(executable) <- execution[:qa_executable],
         true <- GovernanceBuildReceipt.file_digest(executable) == execution[:qa_executable_sha256],
         :ok <- guard.(),
         :ok <- GovernanceRuntime.validate(configuration.runtime),
         :ok <- GovernanceRuntime.validate_implementation(configuration.runtime),
         {:ok, dependencies} <- GovernanceRuntime.dependency_roots(configuration.runtime),
         {:ok, canonical_executable} <- SymphonyElixir.PathSafety.canonicalize(executable),
         true <- canonical_executable == executable,
         true <- Enum.any?(dependencies, &String.starts_with?(executable, &1 <> "/")),
         mix_home when is_binary(mix_home) <- Enum.find(dependencies, &(Path.basename(&1) == ".mix")),
         {:ok, profile} <- GovernanceWorkspaceProfile.build(context.workspace, configuration.runtime.vendor_root, dependencies) do
      id = Base.encode16(:crypto.hash(:sha256, context.issue.native_ref["runId"] <> context.sha), case: :lower)
      outbox = Path.join(context.workspace, "elixir/_build/governance-outbox-" <> id)
      path = Enum.map_join(dependencies, ":", &Path.join(&1, "bin")) <> ":/usr/bin:/bin"

      command = [
        "/usr/bin/env",
        "-i",
        "PATH=" <> path,
        "LANG=C.UTF-8",
        "MIX_HOME=" <> mix_home,
        "HEX_OFFLINE=1",
        "BOS_OUTBOX_ROOT=" <> outbox,
        "/usr/bin/env",
        "-C",
        Path.join(context.workspace, "elixir"),
        "/bin/sh",
        "-c",
        ~S(set -eu; umask 077; mkdir -p -- "$1/tmp" "$1/home"; export TMPDIR="$1/tmp" HOME="$1/home"; shift; MIX_ENV=dev "$@" build; MIX_ENV=dev "$@" format --check-formatted; MIX_ENV=dev "$@" lint; MIX_ENV=test "$@" test --cover; MIX_ENV=dev "$@" dialyzer --format short),
        "bos-qa",
        outbox,
        executable
      ]

      arguments =
        Enum.drop(GovernanceRuntime.startup_arguments(configuration.runtime), -1) ++
          GovernanceRuntime.permission_arguments(profile, "bos-implementation") ++ ["sandbox", "--permission-profile", "bos-implementation", "--cd", context.workspace, "--"] ++ command

      cleared = Enum.map(System.get_env(), fn {k, _} -> {String.to_charlist(k), false} end)

      env =
        cleared ++
          [
            {~c"PATH", ~c"/usr/bin:/bin"},
            {~c"HOME", String.to_charlist(Path.dirname(configuration.runtime.auth_home))},
            {~c"CODEX_HOME", String.to_charlist(configuration.runtime.auth_home)},
            {~c"LANG", ~c"C.UTF-8"}
          ]

      port =
        Port.open({:spawn_executable, String.to_charlist(configuration.runtime.executable)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, arguments},
          {:env, env},
          {:cd, context.workspace}
        ])

      try do
        started = System.monotonic_time(:millisecond)

        case collect(port, guard, "", started) do
          {:ok, output} ->
            {:ok,
             %{
               "kind" => "complete_qa_suite",
               "status" => "passed",
               "complete" => true,
               "environment" => "local",
               "commands" => [Enum.join(command, " ")],
               "outputSha256" => digest(output),
               "output" => SymphonyElixir.GovernanceToolBoundary.safe_output(output)
             }}

          error ->
            error
        end
      after
        GovernanceProcess.stop(port)
      end
    else
      _ -> {:error, :governance_sandbox_qa_unverified}
    end
  rescue
    _ -> {:error, :governance_sandbox_qa_failed}
  end

  defp collect(port, guard, output, started) do
    with :ok <- guard.(), true <- System.monotonic_time(:millisecond) - started < 900_000 do
      receive do
        {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= 1_000_000 -> collect(port, guard, output <> bytes, started)
        {^port, {:exit_status, 0}} -> with :ok <- guard.(), do: {:ok, output}
        {^port, _} -> {:error, :governance_sandbox_qa_failed}
      after
        100 -> collect(port, guard, output, started)
      end
    else
      _ -> {:error, :governance_sandbox_qa_cancelled}
    end
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
