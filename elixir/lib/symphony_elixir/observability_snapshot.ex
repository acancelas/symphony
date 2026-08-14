defmodule SymphonyElixir.ObservabilitySnapshot do
  @moduledoc """
  Maintains the latest orchestrator projection outside the scheduler mailbox.

  The scheduler writes snapshots directly to an ETS table. Observability readers
  can therefore keep serving the last valid state while a tracker poll or
  reconciliation call is in progress.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(term(), map()) :: :ok
  def put(key, snapshot) when is_map(snapshot) do
    if table_available?() do
      true = :ets.insert(@table, {key, snapshot})
    end

    :ok
  end

  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(key) do
    if table_available?() do
      case :ets.lookup(@table, key) do
        [{^key, snapshot}] when is_map(snapshot) -> {:ok, snapshot}
        _ -> :error
      end
    else
      :error
    end
  end

  @impl true
  def init(_opts) do
    _table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end

  defp table_available?, do: :ets.whereis(@table) != :undefined
end
