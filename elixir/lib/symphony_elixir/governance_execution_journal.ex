defmodule SymphonyElixir.GovernanceExecutionJournal do
  @moduledoc "Single-use local launch journal, subordinate to server admission and authority."
  alias SymphonyElixir.Audit.CanonicalJson
  alias SymphonyElixir.GovernanceHostStore
  alias SymphonyElixir.GovernanceProcess
  @binding ~w(repositoryId issueNumber runId attemptId reservationId hostInvocationId workerId authorityGeneration)

  @spec binding(map(), map()) :: map()
  def binding(context, admission) do
    native = context.issue.native_ref

    %{
      "repositoryId" => native["repositoryId"],
      "issueNumber" => native["issueNumber"],
      "runId" => native["runId"],
      "attemptId" => admission["attemptId"],
      "reservationId" => admission["reservationId"],
      "hostInvocationId" => context.principal.invocation_id,
      "workerId" => admission["workerId"],
      "authorityGeneration" => admission["authorityGeneration"]
    }
  end

  @spec transition(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def transition(configuration, binding, command, extra \\ %{}) do
    if Enum.sort(Map.keys(binding)) == Enum.sort(@binding) do
      id = identity(binding)

      GovernanceHostStore.request(
        configuration,
        Map.merge(%{"kind" => "execution", "id" => id, "command" => command, "binding" => binding}, extra)
      )
    else
      {:error, :governance_execution_binding_rejected}
    end
  end

  @spec identity(map()) :: String.t()
  def identity(binding) do
    value = Map.take(binding, ~w(repositoryId issueNumber runId attemptId reservationId))
    Base.encode16(:crypto.hash(:sha256, CanonicalJson.encode(value)), case: :lower)
  end

  @spec spawn_once(map(), map()) :: {:ok, map()} | {:error, atom()}
  def spawn_once(configuration, binding) do
    with {:ok, lease} <- GovernanceHostStore.hold(configuration, identity(binding)) do
      case begin_spawn(configuration, binding) do
        :ok ->
          {:ok, %{marker: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower), lease: lease, generation: 1}}

        error ->
          GovernanceHostStore.release(lease)
          error
      end
    end
  end

  defp begin_spawn(configuration, binding) do
    with {:ok, _} <- transition(configuration, binding, "claim"),
         {:ok, %{"transitioned" => true, "record" => %{"state" => "SPAWN_INTENT"}}} <-
           transition(configuration, binding, "spawn_intent") do
      :ok
    else
      _ -> {:error, :governance_execution_already_claimed_or_uncertain}
    end
  end

  @spec attach(map(), map(), port(), map()) :: {:ok, map()} | {:error, atom()}
  def attach(configuration, binding, port, %{marker: marker, lease: lease}) do
    with true <- GovernanceHostStore.held?(lease),
         {:os_pid, pid} <- Port.info(port, :os_pid),
         {:ok, witness} <- GovernanceProcess.witness(pid, marker),
         {:ok, %{"transitioned" => true, "record" => %{"state" => "ATTACHED"}}} <-
           transition(configuration, binding, "attach", %{"witness" => witness}) do
      {:ok, witness}
    else
      _ -> {:error, :governance_execution_attach_rejected}
    end
  end
end
