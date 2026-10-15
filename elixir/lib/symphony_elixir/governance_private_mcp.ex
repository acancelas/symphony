defmodule SymphonyElixir.GovernancePrivateMcp do
  @moduledoc "Private host MCP process. Role credentials never enter the Codex process or tool output."
  use GenServer
  @limit 2_000_000

  def open(options), do: GenServer.start_link(__MODULE__, options)
  def request(client, method, params), do: GenServer.call(client, {:request, method, params}, 50_000)
  def call(client, tool, arguments), do: request(client, "tools/call", %{"name" => tool, "arguments" => arguments})

  def close(client) when is_pid(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal, 5_000), else: :ok
  catch
    :exit, _ -> :ok
  end

  def init(options) do
    Process.flag(:trap_exit, true)

    with true <- Path.type(options.executable) == :absolute,
         {:ok, receipt} <- SymphonyElixir.GovernanceBuildReceipt.verify(options.build_root, options.receipt_path, options.receipt_sha256),
         relative_entrypoint = Path.relative_to(options.entrypoint, options.build_root),
         true <- Map.has_key?(receipt["files"], relative_entrypoint),
         true <- SymphonyElixir.GovernanceBuildReceipt.file_digest(options.executable) == options.executable_sha256,
         true <- File.regular?(options.entrypoint) do
      environment = System.get_env() |> Map.keys() |> Enum.map(&{String.to_charlist(&1), false})
      environment = environment ++ Enum.map(options.environment, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(options.executable)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          line: @limit,
          cd: String.to_charlist(options.workspace),
          env: environment,
          args: Enum.map(options.arguments, &String.to_charlist/1)
        ])

      state = %{port: port, sequence: 0, timeout: Map.get(options, :timeout_ms, 40_000)}

      case invoke(state, "initialize", %{"protocolVersion" => "2024-11-05", "capabilities" => %{}, "clientInfo" => %{"name" => "bos-private-governance", "version" => "1"}}) do
        {{:ok, _}, next} ->
          Port.command(port, Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) <> "\n")
          {:ok, next}

        {_, _} ->
          Port.close(port)
          {:stop, :governance_mcp_initialization_failed}
      end
    else
      _ -> {:stop, :governance_mcp_unverified_entrypoint}
    end
  rescue
    _ -> {:stop, :governance_mcp_start_failed}
  end

  def handle_call({:request, method, params}, _from, state) do
    {reply, next} = invoke(state, method, params)
    {:reply, reply, next}
  end

  def handle_info({_port, {:exit_status, _}}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}
  def terminate(_, %{port: port}), do: SymphonyElixir.GovernanceProcess.stop(port)

  defp invoke(state, method, params) do
    sequence = state.sequence + 1
    Port.command(state.port, Jason.encode!(%{"jsonrpc" => "2.0", "id" => sequence, "method" => method, "params" => params}) <> "\n")
    result = await(state.port, sequence, "", System.monotonic_time(:millisecond) + state.timeout)
    {result, %{state | sequence: sequence}}
  rescue
    _ -> {{:error, :governance_mcp_transport_closed}, state}
  end

  defp await(port, id, buffer, deadline) do
    timeout = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:noeol, chunk}}} when byte_size(buffer) + byte_size(chunk) < @limit ->
        await(port, id, buffer <> chunk, deadline)

      {^port, {:data, {:eol, chunk}}} ->
        case Jason.decode(buffer <> chunk) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            {:ok, result}

          {:ok, %{"id" => ^id, "error" => _}} ->
            {:error, :governance_mcp_request_rejected}

          {:ok, %{"id" => incoming, "method" => _}} ->
            Port.command(port, Jason.encode!(%{"jsonrpc" => "2.0", "id" => incoming, "error" => %{"code" => -32601, "message" => "Host requests disabled"}}) <> "\n")
            await(port, id, "", deadline)

          _ ->
            await(port, id, "", deadline)
        end

      {^port, {:exit_status, _}} ->
        {:error, :governance_mcp_transport_closed}
    after
      timeout -> {:error, :governance_mcp_timeout}
    end
  end
end
