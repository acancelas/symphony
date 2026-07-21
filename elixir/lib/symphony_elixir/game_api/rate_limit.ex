defmodule SymphonyElixir.GameApi.RateLimit do
  @moduledoc """
  Process-wide circuit breaker for `game-api` rate limiting.

  One OTP process owns the deadline and half-open probe. Concurrent responses
  cannot shorten an existing backoff, and only one caller may test an upstream
  service after the deadline expires.
  """

  use GenServer
  require Logger

  @default_retry_ms 120_000
  @transient_retry_ms 30_000
  @max_retry_ms 900_000
  @max_jitter_ms 5_000
  @half_open_wait_ms 1_000
  @probe_timeout_ms 30_000
  @http_months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @type permit :: non_neg_integer()
  @type state :: %{
          deadline: integer() | nil,
          probe_in_flight?: boolean(),
          probe_ref: reference() | nil,
          probe_timer_ref: reference() | nil,
          generation: non_neg_integer(),
          state_path: Path.t(),
          fallback_state_path: Path.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec acquire() :: {:ok, permit()} | {:error, {:game_api_rate_limited, pos_integer()}}
  def acquire, do: GenServer.call(__MODULE__, :acquire)

  @spec check() :: :ok | {:error, {:game_api_rate_limited, pos_integer()}}
  def check, do: GenServer.call(__MODULE__, :check)

  @spec block(Req.Response.t()) :: pos_integer()
  def block(%Req.Response{} = response) do
    GenServer.call(__MODULE__, {:block_for, bounded_retry_ms(rate_limit_retry_ms(response) + jitter_ms())})
  end

  @spec block_transient(Req.Response.t() | nil) :: pos_integer()
  def block_transient(response \\ nil) do
    retry_ms =
      case response do
        %Req.Response{} -> retry_header_ms(response) || @transient_retry_ms
        nil -> @transient_retry_ms
      end

    GenServer.call(__MODULE__, {:block_for, bounded_retry_ms(retry_ms + jitter_ms())})
  end

  @spec rate_limited_response?(Req.Response.t()) :: boolean()
  def rate_limited_response?(%Req.Response{status: 429}), do: true

  def rate_limited_response?(%Req.Response{status: 503} = response),
    do: not is_nil(retry_header_ms(response))

  def rate_limited_response?(%Req.Response{status: 403} = response) do
    not is_nil(retry_header_ms(response)) or header(response, "x-ratelimit-remaining") == "0"
  end

  def rate_limited_response?(%Req.Response{}), do: false

  @spec authentication_response?(Req.Response.t()) :: boolean()
  def authentication_response?(%Req.Response{status: status}), do: status in [401, 403]

  @spec transient_response?(Req.Response.t()) :: boolean()
  def transient_response?(%Req.Response{status: status}), do: status in 500..599

  @spec succeed(permit()) :: :ok
  def succeed(permit) when is_integer(permit) and permit >= 0 do
    GenServer.call(__MODULE__, {:succeed, permit})
  end

  @doc false
  @spec block_for(pos_integer()) :: pos_integer()
  def block_for(retry_ms) when is_integer(retry_ms) and retry_ms > 0 do
    GenServer.call(__MODULE__, {:block_for, bounded_retry_ms(retry_ms)})
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(opts) do
    state_path = Keyword.get(opts, :state_path) || configured_state_path()
    fallback_state_path = Keyword.get(opts, :fallback_state_path) || configured_fallback_state_path()
    {:ok, restore_state(state_path, fallback_state_path)}
  end

  @impl true
  def handle_call(:acquire, from, state) do
    case remaining_ms(state.deadline) do
      remaining when is_integer(remaining) ->
        {:reply, {:error, {:game_api_rate_limited, remaining}}, state}

      nil when state.deadline != nil and state.probe_in_flight? ->
        {:reply, {:error, {:game_api_rate_limited, @half_open_wait_ms}}, state}

      nil when state.deadline != nil ->
        {caller, _tag} = from
        probe_ref = Process.monitor(caller)
        probe_timer_ref = Process.send_after(self(), {:probe_timeout, state.generation}, @probe_timeout_ms)

        next = %{
          state
          | probe_in_flight?: true,
            probe_ref: probe_ref,
            probe_timer_ref: probe_timer_ref
        }

        {:reply, {:ok, state.generation}, next}

      nil ->
        {:reply, {:ok, state.generation}, state}
    end
  end

  def handle_call(:check, _from, state) do
    case remaining_ms(state.deadline) do
      remaining when is_integer(remaining) ->
        {:reply, {:error, {:game_api_rate_limited, remaining}}, state}

      nil when state.deadline != nil and state.probe_in_flight? ->
        {:reply, {:error, {:game_api_rate_limited, @half_open_wait_ms}}, state}

      nil ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:block_for, retry_ms}, _from, state) do
    requested_deadline = monotonic_ms() + retry_ms
    deadline = max_deadline(state.deadline, requested_deadline)

    next =
      state
      |> clear_probe()
      |> then(fn state ->
        %{
          state
          | deadline: deadline,
            generation: state.generation + 1
        }
      end)

    final = persist_or_degrade(next)
    {:reply, remaining_ms(final.deadline) || 1, final}
  end

  def handle_call({:succeed, permit}, _from, %{generation: permit} = state) do
    next = state |> clear_probe() |> Map.put(:deadline, nil)
    clear_persisted_state(next)
    {:reply, :ok, next}
  end

  def handle_call({:succeed, _stale_permit}, _from, state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    clear_probe(state)
    clear_persisted_state(state)
    {:reply, :ok, initial_state(state.generation + 1, state.state_path, state.fallback_state_path)}
  end

  @impl true
  def handle_info({:DOWN, probe_ref, :process, _pid, _reason}, %{probe_ref: probe_ref} = state) do
    {:noreply, clear_probe(state, false)}
  end

  def handle_info({:probe_timeout, generation}, %{generation: generation, probe_in_flight?: true} = state) do
    next =
      state
      |> clear_probe()
      |> Map.put(:deadline, monotonic_ms() + @transient_retry_ms)
      |> Map.update!(:generation, &(&1 + 1))

    {:noreply, persist_or_degrade(next)}
  end

  def handle_info({:probe_timeout, _generation}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp rate_limit_retry_ms(response) do
    retry_header_ms(response) || reset_deadline_ms(response) || @default_retry_ms
  end

  defp retry_header_ms(response) do
    case header(response, "retry-after") do
      value when is_binary(value) -> parse_retry_after_ms(value)
      _ -> nil
    end
  end

  defp parse_retry_after_ms(value) do
    case parse_positive_integer(value) do
      seconds when is_integer(seconds) -> seconds * 1_000
      nil -> parse_http_date_ms(value)
    end
  end

  defp parse_http_date_ms(value) do
    pattern = ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/

    case Regex.run(pattern, String.trim(value)) do
      [_, day, month, year, hour, minute, second] ->
        with {day, ""} <- Integer.parse(day),
             month when is_integer(month) <- Map.get(@http_months, month),
             {year, ""} <- Integer.parse(year),
             {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {second, ""} <- Integer.parse(second),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour, minute, second) do
          http_date_remaining_ms(date, time)
        else
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp http_date_remaining_ms(date, time) do
    date
    |> DateTime.new!(time, "Etc/UTC")
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> positive_milliseconds()
  end

  defp positive_milliseconds(value) when value > 0, do: value
  defp positive_milliseconds(_value), do: nil

  defp reset_deadline_ms(response) do
    with epoch_seconds when is_integer(epoch_seconds) <-
           response |> header("x-ratelimit-reset") |> parse_positive_integer(),
         remaining when remaining > 0 <-
           epoch_seconds * 1_000 - System.system_time(:millisecond) do
      remaining
    else
      _ -> nil
    end
  end

  defp header(%Req.Response{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp remaining_ms(nil), do: nil

  defp remaining_ms(deadline) do
    case deadline - monotonic_ms() do
      remaining when remaining > 0 -> remaining
      _ -> nil
    end
  end

  defp initial_state(generation, state_path, fallback_state_path),
    do: %{
      deadline: nil,
      probe_in_flight?: false,
      probe_ref: nil,
      probe_timer_ref: nil,
      generation: generation,
      state_path: state_path,
      fallback_state_path: fallback_state_path
    }

  defp restore_state(path, fallback_path) do
    case {File.read(path), File.read(fallback_path)} do
      {{:ok, primary}, {:ok, fallback}} ->
        primary_state = restore_persisted_payload(path, fallback_path, primary)
        fallback_state = restore_persisted_payload(path, fallback_path, fallback)
        later_deadline_state(primary_state, fallback_state)

      {{:ok, contents}, {:error, :enoent}} ->
        restore_persisted_payload(path, fallback_path, contents)

      {{:error, :enoent}, {:ok, contents}} ->
        restore_persisted_payload(path, fallback_path, contents)

      {{:error, :enoent}, {:error, :enoent}} ->
        initial_state(0, path, fallback_path)

      {primary_result, fallback_result} ->
        conservative_restore(
          path,
          fallback_path,
          "read failed: primary=#{inspect(primary_result)} fallback=#{inspect(fallback_result)}"
        )
    end
  end

  defp restore_persisted_payload(path, fallback_path, contents) do
    case Jason.decode(contents) do
      {:ok, %{"blockedUntilEpochMs" => blocked_until, "generation" => generation}}
      when is_integer(blocked_until) and is_integer(generation) and generation >= 0 ->
        remaining = blocked_until - System.system_time(:millisecond)
        state = initial_state(generation + 1, path, fallback_path)
        if remaining > 0, do: %{state | deadline: monotonic_ms() + bounded_retry_ms(remaining)}, else: state

      _ ->
        conservative_restore(path, fallback_path, "invalid or corrupt state")
    end
  end

  defp conservative_restore(path, fallback_path, reason) do
    Logger.error("Unable to trust game-api rate-limit state; applying conservative cooldown: #{reason}")
    %{initial_state(1, path, fallback_path) | deadline: monotonic_ms() + @max_retry_ms}
  end

  defp later_deadline_state(%{deadline: nil}, fallback), do: fallback
  defp later_deadline_state(primary, %{deadline: nil}), do: primary

  defp later_deadline_state(primary, fallback) do
    if primary.deadline >= fallback.deadline, do: primary, else: fallback
  end

  defp persist_state(%{state_path: path} = state) do
    remaining = remaining_ms(state.deadline) || 1

    payload = %{
      "blockedUntilEpochMs" => System.system_time(:millisecond) + remaining,
      "generation" => state.generation
    }

    persist_primary_state(state, path, payload)
  end

  defp persist_primary_state(state, path, payload) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    File.write!(temporary, Jason.encode!(payload), [:binary, :sync])
    File.rename!(temporary, path)
    File.rm(state.fallback_state_path)
    :ok
  rescue
    error ->
      Logger.warning("Unable to persist game-api rate-limit state: #{Exception.message(error)}")
      persist_fallback_state(state, payload)
  end

  defp persist_fallback_state(state, payload) do
    path = state.fallback_state_path
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    File.write!(temporary, Jason.encode!(payload), [:binary, :sync])
    File.rename!(temporary, path)
    :ok
  rescue
    error ->
      Logger.error("Unable to persist fallback game-api rate-limit state: #{Exception.message(error)}")
      {:error, :rate_limit_state_not_durable}
  end

  defp persist_or_degrade(state) do
    case persist_state(state) do
      :ok -> state
      {:error, _reason} -> %{state | deadline: monotonic_ms() + @max_retry_ms, generation: state.generation + 1}
    end
  end

  defp clear_persisted_state(%{state_path: path, fallback_state_path: fallback_path}) do
    File.rm(path)
    File.rm(fallback_path)
    :ok
  end

  defp clear_probe(state, demonitor? \\ true) do
    if demonitor? and is_reference(state.probe_ref), do: Process.demonitor(state.probe_ref, [:flush])
    if is_reference(state.probe_timer_ref), do: Process.cancel_timer(state.probe_timer_ref)
    %{state | probe_in_flight?: false, probe_ref: nil, probe_timer_ref: nil}
  end

  defp configured_state_path do
    System.get_env("BOS_RATE_LIMIT_STATE_PATH") ||
      Path.join([System.user_home!(), ".bos", "rate-limit", "state.json"])
  end

  defp configured_fallback_state_path do
    System.get_env("BOS_RATE_LIMIT_FALLBACK_STATE_PATH") ||
      Path.join([System.user_home!(), ".bos", "outbox", "rate-limit-state.json"])
  end

  defp max_deadline(nil, requested), do: requested
  defp max_deadline(current, requested), do: max(current, requested)
  defp bounded_retry_ms(retry_ms), do: min(max(retry_ms, 1_000), @max_retry_ms)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp jitter_ms, do: :rand.uniform(@max_jitter_ms + 1) - 1
end
