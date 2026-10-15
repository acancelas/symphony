defmodule SymphonyElixir.GovernanceMcpContextClient do
  @moduledoc "Coordinator read adapter over the same private, server-bound MCP transport."
  alias SymphonyElixir.GovernanceAppServerBroker
  @key {__MODULE__, :context}
  def bind(context), do: Process.put(@key, context)
  def clear, do: Process.delete(@key)
  def fetch_issue(repository, number), do: read(repository, number, "bos_get_issue")
  def fetch_goal_planning(repository, number), do: read(repository, number, "bos_get_goal_planning")
  def fetch_goal_execution(repository, number), do: read(repository, number, "bos_get_goal_execution")

  defp read(repository, number, tool) do
    case Process.get(@key) do
      %{issue: %{native_ref: %{"repositoryId" => ^repository, "issueNumber" => ^number}}} = context ->
        GovernanceAppServerBroker.host_read(context, tool, %{"issueNumber" => number})

      _ ->
        {:error, :governance_controller_read_scope_missing}
    end
  end
end
