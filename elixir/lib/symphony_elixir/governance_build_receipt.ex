defmodule SymphonyElixir.GovernanceBuildReceipt do
  @moduledoc "Verifies a host-pinned full build receipt and its files before launching privileged code."
  alias SymphonyElixir.PathSafety

  def verify(root, path, expected_sha256) do
    with {:ok, root} <- PathSafety.canonicalize(root),
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == expected_sha256,
         {:ok, %{"files" => files} = receipt} when is_map(files) and map_size(files) > 0 <- Jason.decode(bytes),
         true <- valid_files?(root, files),
         true <- Enum.all?(receipt["sealedDirectories"] || [], &sealed?(root, &1, Map.keys(files))) do
      {:ok, receipt}
    else
      _ -> {:error, :governance_build_receipt_rejected}
    end
  rescue
    _ -> {:error, :governance_build_receipt_rejected}
  catch
    _ -> {:error, :governance_build_receipt_rejected}
  end

  def file_digest(path) do
    path |> File.stream!([], 65_536) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1)) |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp relative?(path), do: is_binary(path) and Path.type(path) == :relative and ".." not in Path.split(path)

  defp valid_files?(root, files) do
    Enum.reduce_while(files, %{root => root}, fn {relative, expected}, cache ->
      with true <- relative?(relative),
           {:ok, resolved, next} <- resolve_entry(root, Path.join(root, relative), cache),
           true <- File.regular?(resolved),
           true <- file_digest(resolved) == expected do
        {:cont, next}
      else
        _ -> {:halt, false}
      end
    end) != false
  end

  # Memoize directory resolution only within this single verification. Every launch
  # still hashes every pinned file and inventories sealed import directories.
  defp resolve_entry(root, path, cache) do
    case Map.fetch(cache, path) do
      {:ok, resolved} ->
        {:ok, resolved, cache}

      :error ->
        with {:ok, parent, cache} <- resolve_entry(root, Path.dirname(path), cache),
             candidate = Path.join(parent, Path.basename(path)),
             {:ok, stat} <- File.lstat(candidate),
             {:ok, resolved} <- if(stat.type == :symlink, do: PathSafety.canonicalize(candidate), else: {:ok, candidate}),
             true <- String.starts_with?(resolved, root <> "/") do
          {:ok, resolved, Map.put(cache, path, resolved)}
        else
          _ -> {:error, :receipt_path_rejected}
        end
    end
  end

  defp sealed?(root, relative, included) do
    relative?(relative) and Enum.sort(inventory(root, relative)) == Enum.sort(Enum.filter(included, &String.starts_with?(&1, String.trim_trailing(relative, "/") <> "/")))
  end

  defp inventory(root, relative) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> File.ls!(path) |> Enum.flat_map(&inventory(root, Path.join(relative, &1)))
      {:ok, %{type: type}} when type in [:regular, :symlink] -> [relative]
      _ -> throw(:invalid_inventory)
    end
  end
end
