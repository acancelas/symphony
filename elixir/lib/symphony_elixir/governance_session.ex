defmodule SymphonyElixir.GovernanceSession do
  alias SymphonyElixir.Tracker.Issue

  @moduledoc """
  Host-owned role-session boundary. A broker must provision independently authenticated
  M2M subjects and enforce the tool allowlist before starting a fresh session. Merely
  setting BOS_MCP_ACTOR or adding instructions never satisfies this contract.
  """
  @callback run(map(), String.t(), String.t(), map()) :: :ok | {:error, term()}

  @doc "Shared fixed primary/repair policy: source reads and a structured proposal, with full execution admission."
  @spec implementation_policy() :: map()
  def implementation_policy do
    %{
      sandbox: %{"type" => "readOnly", "networkAccess" => false},
      tools: [],
      native_operations: [:read],
      verified_m2m: true,
      fresh_session: true,
      check_goal_authorization: true,
      execution_scope: :implementation,
      proposal_mode: :structured
    }
  end

  @spec context(String.t() | nil, Issue.t() | nil, pid() | nil, keyword(), String.t() | nil) ::
          map()
  def context(workspace, issue, recipient, opts, worker_host) do
    config = Application.get_env(:symphony_elixir, :governance, [])

    %{
      workspace: workspace,
      issue: issue,
      recipient: recipient,
      worker_host: worker_host,
      broker: Keyword.get(opts, :governance_session_broker, config[:session_broker])
    }
  end

  @spec available_for?(keyword()) :: :ok | {:error, atom()}
  def available_for?(opts), do: available?(context(nil, nil, nil, opts, nil))

  @spec draft(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def draft(context, prompt, policy) do
    with :ok <- available?(context),
         true <- function_exported?(context.broker, :draft, 3),
         {:ok, principal} <- principal(context, "task-orchestrator"),
         {:ok, policy} <- isolation(context, "task-orchestrator", policy) do
      context.broker.draft(Map.put(context, :principal, principal), prompt, policy)
    else
      false -> {:error, :governance_readonly_draft_unavailable}
      error -> error
    end
  after
    if is_atom(context.broker) and function_exported?(context.broker, :release, 2),
      do: context.broker.release(context, "task-orchestrator")
  end

  @spec available?(term()) :: :ok | {:error, atom()}
  def available?(%{broker: broker}) when is_atom(broker) and not is_nil(broker) do
    if Code.ensure_loaded?(broker) and function_exported?(broker, :run, 4),
      do: :ok,
      else: {:error, :governance_m2m_broker_unavailable}
  end

  def available?(_), do: {:error, :governance_m2m_broker_unavailable}

  defp isolation(context, role, policy) do
    required = [:tool_allowlist, :minimal_environment, :read_roots, :private_mcp_credentials]
    required = if policy.sandbox["type"] == "readOnly", do: [:read_only | required], else: required

    with true <- function_exported?(context.broker, :capabilities, 2),
         {:ok, capabilities} <- context.broker.capabilities(context, role),
         true <- Enum.all?(required, &(capabilities[&1] == :enforced)) do
      {:ok,
       Map.merge(policy, %{
         read_roots: [context.workspace],
         environment: :minimal_no_credentials,
         credential_delivery: :private_mcp_transport,
         strip_environment:
           ["BOS_API_INTERNAL_TOKEN", "BOS_RUNNER_ACTION_TOKEN", "BOS_API_HUMAN_TOKEN"] ++
             SymphonyElixir.GovernanceTransport.secret_environment_names()
       })}
    else
      _ -> {:error, :governance_isolation_unavailable}
    end
  end

  defp principal(context, role) do
    if function_exported?(context.broker, :identity, 2) do
      case context.broker.identity(context, role) do
        {:ok, %{subject_id: subject, service_id: service, role: ^role, repository_id: repository} = identity}
        when is_binary(subject) and subject != "" and is_binary(service) and service != "" ->
          principal_repository(context, repository, identity)

        {:ok, %{machine_id: id, role: ^role, repository_id: repository} = legacy}
        when is_binary(id) and id != "" ->
          principal_repository(context, repository, Map.merge(legacy, %{subject_id: id, service_id: id}))

        _ ->
          {:error, :governance_verified_principal_unavailable}
      end
    else
      {:error, :governance_verified_principal_unavailable}
    end
  end

  defp principal_repository(context, repository, identity) do
    if repository == context.issue.native_ref["repositoryId"],
      do: {:ok, identity},
      else: {:error, :governance_principal_repository_mismatch}
  end

  defp prepare_context(context, policy) do
    if function_exported?(context.broker, :prepare_context, 2),
      do: context.broker.prepare_context(context, policy),
      else: {:ok, context}
  end

  @spec run(map(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def run(context, role, prompt, policy) do
    with :ok <- available?(context),
         {:ok, context} <- prepare_context(context, policy),
         {:ok, identity} <- principal(context, role),
         {:ok, policy} <- isolation(context, role, policy) do
      prompt =
        "Effective verified BOS execution subject: #{identity.subject_id}; service identity: #{identity.service_id}. Review/Attempt actor must be type agent and subjectId exactly this execution subject; never the service id or a role name. Server verifies authority.\n" <>
          prompt

      context.broker.run(Map.put(context, :principal, identity), role, prompt, policy)
    end
  after
    if is_atom(context.broker) and function_exported?(context.broker, :release, 2),
      do: context.broker.release(context, role)
  end
end
