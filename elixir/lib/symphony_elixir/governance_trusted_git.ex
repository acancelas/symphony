defmodule SymphonyElixir.GovernanceTrustedGit do
  @moduledoc "Prevent repository-configured executables before host Git inspects or publishes a candidate."
  @fixed [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.attributesFile=/dev/null",
    "--no-replace-objects"
  ]
  @spec run(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def run(workspace, arguments) do
    environment =
      Enum.flat_map(System.get_env(), fn {key, _} ->
        if String.starts_with?(key, "GIT_"), do: [{key, false}], else: []
      end)

    options = [cd: workspace, stderr_to_stdout: true, env: environment]

    with {:ok, root} <- SymphonyElixir.PathSafety.canonicalize(workspace),
         true <- root == Path.expand(workspace),
         {top, 0} <- System.cmd("/usr/bin/git", @fixed ++ ["rev-parse", "--show-toplevel"], options),
         true <- String.trim(top) == root,
         {_, 1} <-
           System.cmd(
             "/usr/bin/git",
             @fixed ++ ["config", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|smudge|process)$"],
             options
           ),
         {_, 1} <-
           System.cmd(
             "/usr/bin/git",
             @fixed ++
               [
                 "config",
                 "--local",
                 "--includes",
                 "--name-only",
                 "--get-regexp",
                 "^(credential\\.|url\\.|core\\.sshcommand$|remote\\..*\\.(uploadpack|receivepack)$|protocol\\.)"
               ],
             options
           ) do
      System.cmd("/usr/bin/git", @fixed ++ arguments, options)
    else
      _ -> {"Host Git configuration or workspace rejected", 128}
    end
  rescue
    _ -> {"Host Git unavailable", 128}
  end
end
