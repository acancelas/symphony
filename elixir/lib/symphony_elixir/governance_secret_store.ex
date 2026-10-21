defmodule SymphonyElixir.GovernanceSecretStore do
  @moduledoc false
  import Bitwise
  # Reads the existing host registry in memory. Never sources a shell, copies a
  # credential file, returns secrets to a model tool, or writes the registry.
  @spec service_secret(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def service_secret(path, subject) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and (stat.mode &&& 0o077) == 0,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) < 100_000,
         [_, encoded] <- Regex.run(~r/^BOS_AGENT_SECRETS_JSON=(.*)$/m, bytes),
         {:ok, registry} <- decode(String.trim(encoded)),
         secret when is_binary(secret) and byte_size(secret) >= 32 <- registry[subject] do
      {:ok, secret}
    else
      _ -> {:error, :governance_host_secret_unavailable}
    end
  rescue
    _ -> {:error, :governance_host_secret_unavailable}
  end

  defp decode("'" <> rest) do
    if String.ends_with?(rest, "'"),
      do: Jason.decode(String.slice(rest, 0, byte_size(rest) - 1)),
      else: {:error, :invalid_registry}
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, nested} when is_binary(nested) -> Jason.decode(nested)
      other -> other
    end
  end
end
