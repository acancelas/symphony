defmodule SymphonyElixir.GovernanceCLI do
  @moduledoc "One-shot governed phase entrypoint; starts no scheduler and opens no implementation Attempt."
  alias SymphonyElixir.Config
  alias SymphonyElixir.GovernanceAppServerBroker
  alias SymphonyElixir.GovernanceCatalog
  alias SymphonyElixir.GovernanceCoordinator
  alias SymphonyElixir.GovernanceHostConfig
  alias SymphonyElixir.GovernanceMcpContextClient
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @switches [
    host_config: :string,
    phase: :string,
    workspace: :string,
    repository: :string,
    issue: :integer,
    run: :string
  ]

  @spec evaluate([String.t()]) :: {:ok, map()} | {:error, term()}
  def evaluate(arguments) do
    with {options, [workflow], []} <- OptionParser.parse(arguments, strict: @switches),
         true <- length(options) == 6 and length(Enum.uniq(Keyword.keys(options))) == 6,
         phase when phase in ["planning", "implementation"] <- options[:phase],
         number when is_integer(number) and number > 0 <- options[:issue],
         run when is_binary(run) and byte_size(run) > 0 <- options[:run],
         {:ok, configuration} <- GovernanceHostConfig.load(options[:host_config]),
         {:ok, repository} <- Map.fetch(configuration.repositories, options[:repository]),
         {:ok, workspace} <- allowed_workspace(configuration, options[:repository], options[:workspace]),
         {:ok, loaded} <- Workflow.load(Path.expand(workflow)),
         {:ok, settings} <- Config.Schema.parse(loaded.config),
         :ok <- install(configuration, settings, workflow) do
      context = %{
        workspace: workspace,
        phase: phase,
        issue: %Issue{
          id: "#{options[:repository]}##{number}",
          native_ref: %{"repositoryId" => options[:repository], "issueNumber" => number, "runId" => run}
        }
      }

      execute(context, repository)
    else
      _ -> {:error, :governance_entrypoint_configuration_rejected}
    end
  rescue
    _ -> {:error, :governance_entrypoint_failed}
  after
    GovernanceMcpContextClient.clear()
    Process.delete(:symphony_governance_runtime_settings)
  end

  defp install(configuration, settings, workflow) do
    Application.put_env(:symphony_elixir, :governance,
      broker: configuration,
      session_broker: GovernanceAppServerBroker,
      catalog_path: configuration.catalog_path
    )

    Process.put(:symphony_governance_runtime_settings, settings)
    Workflow.set_workflow_file_path(Path.expand(workflow))
    :ok
  end

  defp execute(context, repository) do
    with {:ok, recorded} <-
           GovernanceAppServerBroker.host_read(context, "bos_get_delivery_run", %{
             "runId" => context.issue.native_ref["runId"]
           }),
         :ok <- GovernanceAppServerBroker.reserve_existing_run(context, recorded),
         {:ok, source} <-
           GovernanceAppServerBroker.host_read(context, "bos_get_issue", %{
             "issueNumber" => context.issue.native_ref["issueNumber"]
           }),
         {:ok, issue} <- confirmed_issue(Map.put(source, "run", recorded), context, repository) do
      context = %{context | issue: issue}
      GovernanceMcpContextClient.bind(context)
      phase = if context.phase == "planning", do: :planning, else: :implementation

      options = [
        candidate_head_module: SymphonyElixir.GovernanceCandidateHead,
        governance_enabled: true,
        game_api_client_module: GovernanceMcpContextClient,
        governance_session_broker: GovernanceAppServerBroker,
        governance_require_ready: "bos:goal" not in issue.labels
      ]

      case GovernanceCoordinator.run(phase, context.workspace, issue, nil, options, nil) do
        :ok ->
          with :ok <- continue_after_planning(phase, context, options) do
            {:ok,
             %{
               status: if(phase == :planning and "bos:goal" not in issue.labels, do: "local-verified", else: "phase-passed"),
               phase: context.phase,
               issueNumber: issue.native_ref["issueNumber"],
               runId: issue.native_ref["runId"],
               catalogCommitSha: GovernanceCatalog.commit(),
               implementationStarted: phase == :planning and "bos:goal" not in issue.labels
             }}
          end

        {:error, _} = error ->
          error
      end
    end
  after
    GovernanceAppServerBroker.release(context, "task-orchestrator")
  end

  defp continue_after_planning(:planning, context, options) do
    if "bos:goal" in context.issue.labels do
      :ok
    else
      SymphonyElixir.AgentRunner.run_governed_implementation(context.workspace, context.issue, nil, options, nil)
    end
  end

  defp continue_after_planning(_, _, _), do: :ok

  defp confirmed_issue(source, context, repository) do
    run = context.issue.native_ref["runId"]
    claim = source["claim"] || %{}
    recorded = source["run"] || %{}

    with true <- source["number"] == context.issue.native_ref["issueNumber"] and claim["runId"] == run,
         true <-
           recorded["runId"] == run and is_binary(recorded["branch"]) and recorded["branch"] not in ["main", "master"],
         {branch, 0} <-
           System.cmd("/usr/bin/git", ["-C", context.workspace, "symbolic-ref", "--short", "HEAD"], stderr_to_stdout: true),
         true <- String.trim(branch) == recorded["branch"],
         labels when is_list(labels) <- source["labels"] do
      native =
        Map.merge(context.issue.native_ref, %{
          "repositoryOwner" => repository["owner"],
          "repositoryName" => repository["repo"],
          "governance" => source["governance"]
        })

      %Issue{} = issue = context.issue

      {:ok,
       %{
         issue
         | native_ref: native,
           identifier: context.issue.id,
           title: source["title"],
           description: source["body"],
           branch_name: recorded["branch"],
           labels: labels,
           url: source["url"]
       }}
    else
      _ -> {:error, :governance_existing_run_or_branch_unverified}
    end
  end

  defp allowed_workspace(configuration, repository, path) do
    with {:ok, actual} <- PathSafety.canonicalize(path),
         allowed when is_list(allowed) <- configuration.workspaces[repository],
         true <- actual in allowed,
         {:ok, %{type: :regular}} <- File.lstat(Path.join(actual, ".git")),
         {inventory, 0} <-
           System.cmd("/usr/bin/git", ["-C", actual, "worktree", "list", "--porcelain"], stderr_to_stdout: true),
         true <- ("worktree " <> actual) in String.split(inventory, "\n") do
      {:ok, actual}
    else
      _ -> {:error, :governance_registered_workspace_required}
    end
  end
end
