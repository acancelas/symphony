defmodule SymphonyElixir.Codex.CommandPolicy do
  @moduledoc """
  Enforces the BOS integration boundary before Codex shell commands are approved.

  Git transport remains local runtime work. GitHub product and Delivery operations
  must use bos-mcp, so `gh` and direct GitHub API/GraphQL traffic are rejected.
  """

  @github_api_pattern ~r/(?:api\.github\.com|github\.com\/graphql)(?:[\/:?\s]|$)/i
  @shell_wrapper_pattern ~r/(?:^|\s)(?:bash|sh|zsh)(?:\s+[^\s]+)*\s+-[A-Za-z]*c\s+(["'])(.*?)\1/is
  @prefixes ~w(command exec sudo)

  @type violation :: %{
          code: String.t(),
          reason: String.t(),
          replacement: String.t(),
          command_summary: String.t()
        }

  @spec inspect_command(term()) :: :ok | {:error, violation()}
  def inspect_command(command) do
    normalized = normalize_command(command)

    cond do
      github_api_target?(normalized) ->
        {:error,
         violation(
           "direct_github_api_blocked",
           "Direct GitHub REST/GraphQL access is forbidden inside a BOS AgentRun.",
           normalized
         )}

      gh_invocation?(normalized) ->
        {:error,
         violation(
           "direct_gh_blocked",
           "The GitHub CLI is forbidden inside a BOS AgentRun.",
           normalized
         )}

      true ->
        :ok
    end
  end

  @doc false
  @spec safe_summary(term()) :: String.t()
  def safe_summary(command) do
    command
    |> normalize_command()
    |> bounded_summary()
  end

  defp github_api_target?(command), do: Regex.match?(@github_api_pattern, command)

  defp gh_invocation?(command) do
    command
    |> command_segments()
    |> Enum.any?(fn segment ->
      gh_executable?(segment) or wrapped_gh_invocation?(segment)
    end)
  end

  defp command_segments(command) do
    String.split(command, ~r/(?:&&|\|\||[;|\n])/u, trim: true)
  end

  defp wrapped_gh_invocation?(segment) do
    case Regex.run(@shell_wrapper_pattern, segment, capture: :all_but_first) do
      [_quote, nested_command] -> gh_invocation?(nested_command)
      _ -> false
    end
  end

  defp gh_executable?(segment) do
    segment
    |> String.trim()
    |> shell_words()
    |> drop_command_prefixes()
    |> case do
      [executable | _arguments] -> Path.basename(executable) in ["gh", "gh.exe"]
      [] -> false
    end
  end

  defp shell_words(segment) do
    Regex.scan(~r/(?:[^\s"']+|"[^"]*"|'[^']*')+/u, segment)
    |> List.flatten()
    |> Enum.map(&String.trim(&1, "\"'"))
  end

  defp drop_command_prefixes(["env" | rest]), do: drop_environment_assignments(rest)
  defp drop_command_prefixes([prefix | rest]) when prefix in @prefixes, do: drop_command_prefixes(rest)

  defp drop_command_prefixes([assignment | rest]) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/u, assignment) do
      drop_command_prefixes(rest)
    else
      [assignment | rest]
    end
  end

  defp drop_command_prefixes([]), do: []

  defp drop_environment_assignments([assignment | rest]) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/u, assignment) do
      drop_environment_assignments(rest)
    else
      drop_command_prefixes([assignment | rest])
    end
  end

  defp drop_environment_assignments([]), do: []

  defp normalize_command(command) when is_binary(command), do: String.trim(command)
  defp normalize_command(command) when is_list(command), do: Enum.map_join(command, " ", &to_string/1)
  defp normalize_command(_command), do: ""

  defp violation(code, reason, command) do
    %{
      code: code,
      reason: reason,
      replacement: "Use the corresponding bos-mcp domain tool.",
      command_summary: bounded_summary(command)
    }
  end

  defp bounded_summary(command) do
    command
    |> String.replace(~r/(?:token|authorization|password|secret)=?\s*[^\s]+/iu, "[REDACTED]")
    |> String.slice(0, 500)
  end
end
