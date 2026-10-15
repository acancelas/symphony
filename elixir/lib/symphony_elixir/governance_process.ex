defmodule SymphonyElixir.GovernanceProcess do
  @moduledoc false
  # Capture exact Linux child identities before closing their control port. The
  # start-time check prevents a recycled PID from ever selecting unrelated work.
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
        |> Enum.flat_map(fn text ->
          case Integer.parse(text) do
            {pid, ""} -> descendants(pid) ++ [identity(pid)]
            _ -> []
          end
        end)

      _ ->
        []
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
