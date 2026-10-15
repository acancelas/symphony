defmodule SymphonyElixir.GovernanceSession do
  @moduledoc """
  Host-owned role-session boundary. A broker must provision independently authenticated
  M2M subjects and enforce the tool allowlist before starting a fresh session. Merely
  setting BOS_MCP_ACTOR or adding instructions never satisfies this contract.
  """
  @callback run(map(), String.t(), String.t(), map()) :: :ok | {:error, term()}

  def available?(%{broker: broker}) when is_atom(broker) and not is_nil(broker) do
    if Code.ensure_loaded?(broker) and function_exported?(broker, :run, 4),
      do: :ok,
      else: {:error, :governance_m2m_broker_unavailable}
  end

  def available?(_), do: {:error, :governance_m2m_broker_unavailable}

  def run(context, role, prompt, policy) do
    with :ok <- available?(context), do: context.broker.run(context, role, prompt, policy)
  end
end
