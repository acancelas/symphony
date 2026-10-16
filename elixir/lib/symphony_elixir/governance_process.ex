defmodule SymphonyElixir.GovernanceProcess do
  @moduledoc false
  # Capture exact Linux child identities before closing their control port. The
  # start-time check prevents a recycled PID from ever selecting unrelated work.
  @spec stop(port()) :: :ok
  def stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        owned = descendants(pid) ++ [identity(pid)]
        signal(owned, "TERM")
        if Enum.any?(owned, &alive?/1), do: Process.sleep(50)
        signal(owned, "KILL")
        close(port)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec witness(pos_integer(), String.t()) :: {:ok, map()} | {:error, atom()}
  def witness(pid, marker) when is_integer(pid) and pid > 1 and is_binary(marker) do
    with {^pid, ticks} <- identity(pid), {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, %{"pid" => pid, "startTicks" => ticks, "bootId" => String.trim(boot), "marker" => marker}}
    else
      _ -> {:error, :governance_process_witness_unavailable}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp descendants(parent) do
    case File.read("/proc/#{parent}/task/#{parent}/children") do
      {:ok, children} ->
        children
        |> String.split()
        |> Enum.flat_map(&descendant_identity/1)

      _ ->
        []
    end
  end

  defp descendant_identity(text) do
    case Integer.parse(text) do
      {pid, ""} -> descendants(pid) ++ [identity(pid)]
      _ -> []
    end
  end

  defp identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_name, tail] <- String.split(stat, ") ", parts: 2),
         start when is_binary(start) <- Enum.at(String.split(tail), 19) do
      {pid, start}
    else
      _ -> nil
    end
  end

  defp alive?({pid, started}), do: identity(pid) == {pid, started}
  defp alive?(_), do: false

  defp signal(owned, type) do
    for {pid, _} = item <- owned, alive?(item) do
      System.cmd("kill", ["-#{type}", "--", Integer.to_string(pid)], stderr_to_stdout: true)
    end
  end
end
