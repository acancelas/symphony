defmodule SymphonyElixir.GovernanceTransport do
  @moduledoc "Host-configured coordinator M2M transport; authorization remains server verified."
  def secret_environment_names do
    config() |> Map.values() |> Enum.map(& &1[:token_env]) |> Enum.filter(&is_binary/1)
  end

  def configured?(repository_id), do: Map.has_key?(config(), repository_id)

  def require_repository(repository_id) do
    case headers(repository_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def headers(repository_id) do
    case config()[repository_id] do
      %{token_env: name} when is_binary(name) ->
        case System.get_env(name) do
          token when is_binary(token) and byte_size(token) > 0 -> {:ok, [{"authorization", "Bearer " <> token}]}
          _ -> {:error, :governance_coordinator_credential_missing}
        end

      _ ->
        {:error, :governance_coordinator_credential_missing}
    end
  end

  def for_request(options, legacy) do
    repository_id =
      get_in(options[:json] || %{}, ["repository", "repositoryId"]) ||
        Enum.find_value(options[:params] || [], fn {key, value} -> if key == "repositoryId", do: value end)

    if configured?(repository_id) do
      with {:ok, auth} <- headers(repository_id) do
        {:ok, auth ++ Enum.reject(legacy, fn {key, _} -> key in ["x-internal-token", "x-bos-actor-type", "x-bos-actor-id", "x-bos-authenticated-by"] end)}
      end
    else
      {:ok, legacy}
    end
  end

  defp config, do: Application.get_env(:symphony_elixir, :governance, [])[:coordinator_repositories] || %{}
end
