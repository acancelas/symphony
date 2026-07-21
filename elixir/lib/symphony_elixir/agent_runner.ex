defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.CommandPolicy

  alias SymphonyElixir.{
    Config,
    DeliveryCoordinator,
    GoalPlanningCoordinator,
    PostApprovalCoordinator,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Process.delete(:bos_last_completed_command)

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    attempt_number = normalize_attempt_number(Keyword.get(opts, :attempt))

    with {:ok, issue} <- Tracker.start_execution(issue, attempt_number),
         {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host) do
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
          cond do
            goal_planning_issue?(issue) ->
              GoalPlanningCoordinator.run(workspace, issue, codex_update_recipient, opts, worker_host)

            post_approval_issue?(issue) ->
              PostApprovalCoordinator.run(workspace, issue, codex_update_recipient, opts, worker_host)

            true ->
              run_implementation_or_resume_reviews(
                workspace,
                issue,
                codex_update_recipient,
                opts,
                worker_host
              )
          end
        end
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_implementation_or_resume_reviews(workspace, issue, recipient, opts, worker_host) do
    if bos_delivery_issue?(issue) do
      issue
      |> DeliveryCoordinator.review_stage_started?(opts)
      |> run_bos_delivery_stage(workspace, issue, recipient, opts, worker_host)
    else
      run_codex_turns(workspace, issue, recipient, opts, worker_host)
    end
  end

  defp run_bos_delivery_stage({:ok, true}, workspace, issue, recipient, opts, worker_host) do
    Logger.info("Resuming durable review stage without reopening implementation for #{issue_context(issue)}")

    DeliveryCoordinator.run(workspace, issue, recipient, delivery_context_opts(opts), worker_host)
  end

  defp run_bos_delivery_stage({:ok, false}, workspace, issue, recipient, opts, worker_host) do
    with :ok <- run_codex_turns(workspace, issue, recipient, opts, worker_host) do
      DeliveryCoordinator.run(workspace, issue, recipient, delivery_context_opts(opts), worker_host)
    end
  end

  defp run_bos_delivery_stage({:error, reason}, _workspace, _issue, _recipient, _opts, _worker_host) do
    {:error, {:review_stage_lookup_failed, reason}}
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      remember_completed_command(message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp remember_completed_command(%{event: :item_completed, payload: payload}) do
    item = get_in(payload || %{}, ["params", "item"]) || get_in(payload || %{}, ["item"])

    if is_map(item) and String.contains?(String.downcase(to_string(item["type"] || "")), "command") do
      Process.put(:bos_last_completed_command, %{
        command: CommandPolicy.safe_summary(item["command"] || item["parsedCmd"] || "[command unavailable]"),
        exit_code: item["exitCode"],
        status: item["status"]
      })
    end

    :ok
  end

  defp remember_completed_command(_message), do: :ok

  defp delivery_context_opts(opts),
    do: Keyword.put(opts, :prior_command_context, Process.get(:bos_last_completed_command))

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    # One implementation turn is a complete Codex task execution. Delivery
    # continuation is owned by the explicit review/repair coordinator below,
    # preventing an active tracker label from spawning dozens of blind turns.
    max_turns =
      if bos_delivery_issue?(issue) do
        Keyword.get(opts, :implementation_max_turns, 1)
      else
        Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
      end

    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_attempt_number(attempt) when is_integer(attempt) and attempt >= 0, do: attempt + 1
  defp normalize_attempt_number(_attempt), do: 1

  defp bos_delivery_issue?(%Issue{native_ref: native_ref}) when is_map(native_ref) do
    is_binary(native_ref["repositoryId"]) and is_binary(native_ref["runId"])
  end

  defp bos_delivery_issue?(_issue), do: false

  defp goal_planning_issue?(%Issue{labels: labels}) do
    "bos:goal" in labels
  end

  defp post_approval_issue?(%Issue{state: state}) when is_binary(state) do
    normalize_issue_state(state) == "agent:merging"
  end

  defp post_approval_issue?(_issue), do: false

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
