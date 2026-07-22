defmodule SymphonyElixir.RunnerIdentity do
  @moduledoc """
  Resolves the canonical local runner identity shared by orchestration and gateway calls.
  """

  @spec id() :: String.t()
  def id do
    case System.get_env("BOS_RUNNER_ID") do
      value when is_binary(value) -> normalize(value)
      _ -> "x1"
    end
  end

  defp normalize(value) do
    case String.trim(value) do
      "" -> "x1"
      normalized -> normalized
    end
  end
end
