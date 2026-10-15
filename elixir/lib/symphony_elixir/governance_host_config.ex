defmodule SymphonyElixir.GovernanceHostConfig do
  @moduledoc "Loads private host-owned JSON paths and pins, never inline credentials."
  @keys ~w(service_subject service_secret_file catalog_path allowed_authenticated_by repositories workspaces api_base_url target_project_id private_home private_cache_root mcp runtime)
  @mcp ~w(executable executable_sha256 entrypoint build_root receipt_path receipt_sha256 timeout_ms)
  @runtime ~w(package_root receipt_path receipt_sha256 executable executable_sha256 proof_path proof_sha256 vendor_root auth_home worker_root native_config_sha256 disabled_mcp_servers)
  @atoms Map.new(@keys ++ @mcp ++ @runtime, &{&1, String.to_atom(&1)})

  def load(path) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) < 100_000,
         {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(raw)) == Enum.sort(@keys),
         {:ok, mcp} <- known(raw["mcp"], @mcp),
         {:ok, runtime} <- known(raw["runtime"], @runtime),
         true <- is_map(raw["repositories"]) and map_size(raw["repositories"]) > 0,
         true <- is_map(raw["workspaces"]) and map_size(raw["workspaces"]) > 0,
         true <- raw["allowed_authenticated_by"] == ["bos-host-hmac-v2"],
         true <- loopback?(raw["api_base_url"]) do
      {:ok, raw |> Map.new(fn {k, v} -> {Map.fetch!(@atoms, k), v} end) |> Map.put(:mcp, mcp) |> Map.put(:runtime, runtime)}
    else
      _ -> {:error, :governance_host_configuration_rejected}
    end
  rescue
    _ -> {:error, :governance_host_configuration_rejected}
  end

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
