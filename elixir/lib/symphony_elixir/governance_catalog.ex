defmodule SymphonyElixir.GovernanceCatalog do
  @moduledoc "Loads role definitions from an exact canonical Git object, never mutable checkout files."
  @commit "ea1d38867fb8096991312d77fd7643e2810ee72e"
  @digest "2a3932de1ce0c2f868030891366815a7cdda7c0c464058fca959cc2abd7ff7cc"
  def commit, do: @commit

  def load(path) when is_binary(path) do
    with {bytes, 0} <- System.cmd("git", ["-C", path, "show", "#{@commit}:catalog.json"], stderr_to_stdout: true),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @digest,
         {:ok, %{"schemaVersion" => 1, "roles" => roles} = catalog} <- Jason.decode(bytes),
         true <- length(roles) == 12,
         committee <- Enum.filter(roles, &(&1["kind"] in ["specialist", "challenger"])),
         true <- length(committee) == 10 do
      {:ok, Map.put(catalog, "committee", committee)}
    else
      _ -> {:error, :governance_catalog_unverified}
    end
  rescue
    _ -> {:error, :governance_catalog_unverified}
  end

  def load(_), do: {:error, :governance_catalog_unconfigured}
end
