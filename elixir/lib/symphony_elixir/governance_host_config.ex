defmodule SymphonyElixir.GovernanceHostConfig do
  @moduledoc "Loads private host-owned JSON paths and pins, never inline credentials."
  @keys ~w(service_subject service_secret_file catalog_path allowed_authenticated_by repositories workspaces api_base_url target_project_id private_home private_cache_root mcp runtime)
  @mcp ~w(executable executable_sha256 entrypoint build_root receipt_path receipt_sha256 timeout_ms)
  @runtime ~w(package_root receipt_path receipt_sha256 executable executable_sha256 proof_path proof_sha256 vendor_root auth_home worker_root native_config_sha256 disabled_mcp_servers)
  @optional_runtime ~w(implementation_proof_path implementation_proof_sha256 dependency_receipts)
  @execution ~w(python_executable python_sha256 journal_root qa_executable qa_executable_sha256)
  @atoms Map.new(@keys ++ @mcp ++ @runtime ++ @optional_runtime ++ @execution ++ ["execution"], &{&1, String.to_atom(&1)})

  def load(path) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) < 100_000,
         {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(Map.delete(raw, "execution"))) == Enum.sort(@keys),
         {:ok, mcp} <- known(raw["mcp"], @mcp),
         {:ok, runtime} <- known_runtime(raw["runtime"]),
         {:ok, execution} <- execution(raw["execution"]),
         true <- is_map(raw["repositories"]) and map_size(raw["repositories"]) > 0,
         true <- is_map(raw["workspaces"]) and map_size(raw["workspaces"]) > 0,
         true <- raw["allowed_authenticated_by"] == ["bos-host-hmac-v2"],
         true <- loopback?(raw["api_base_url"]) do
      {:ok, raw |> Map.new(fn {k, v} -> {Map.fetch!(@atoms, k), v} end) |> Map.put(:mcp, mcp) |> Map.put(:runtime, runtime) |> Map.put(:execution, execution)}
    else
      _ -> {:error, :governance_host_configuration_rejected}
    end
  rescue
    _ -> {:error, :governance_host_configuration_rejected}
  end

  defp known_runtime(raw) when is_map(raw) do
    with {:ok, base} <- known(Map.drop(raw, @optional_runtime), @runtime),
         true <- Enum.all?(Map.keys(raw), &(&1 in (@runtime ++ @optional_runtime))) do
      {:ok, Enum.reduce(Map.take(raw, @optional_runtime), base, fn {k, v}, acc -> Map.put(acc, Map.fetch!(@atoms, k), v) end)}
    else
      _ -> {:error, :unknown_runtime_configuration_key}
    end
  end

  defp known_runtime(_), do: {:error, :invalid_runtime_configuration}
  defp execution(nil), do: {:ok, nil}
  defp execution(raw), do: known(raw, @execution)

  defp known(raw, keys) when is_map(raw) do
    if Enum.all?(Map.keys(raw), &(&1 in keys)) and Enum.all?(keys -- ["timeout_ms"], &Map.has_key?(raw, &1)),
      do: {:ok, Map.new(raw, fn {k, v} -> {Map.fetch!(@atoms, k), v} end)},
      else: {:error, :unknown_or_missing_host_configuration_key}
  end

  defp known(_, _), do: {:error, :invalid_host_configuration}

  defp loopback?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme in ["http", "https"] and uri.host in ["localhost", "127.0.0.1", "::1"] and is_nil(uri.userinfo)
  end

  defp loopback?(_), do: false
end
