defmodule NameBadge.CityBike do
  @moduledoc """
  Periodically fetches citybike updates
  """

  @base "https://gbfs.urbansharing.com/trondheimbysykkel.no"
  @headers [{"Client-Identifier", "elixir-crontab v1.0.0"}]
  @call_timeout to_timeout(second: 5)
  @update_interval to_timeout(minute: 10)

  use GenServer
  require Logger

  defstruct [:station_info, :station_status, :timer, :last_updated]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    state = Map.merge(state, %{station_info: nil, station_status: nil, last_updated: nil})
    refresh_station_info()
    send(self(), :initialize)
    {:ok, state}
  end

  def refresh_station_info() do
    GenServer.cast(__MODULE__, :refresh_station_info)
  end

  def get_state() do
    GenServer.call(__MODULE__, :get_state, @call_timeout)
  end

  def refresh_station_status() do
    GenServer.cast(__MODULE__, :refresh_station_status)
  end

  def get_station_status(station_name) do
    GenServer.call(__MODULE__, {:station_query, station_name}, @call_timeout)
  end

  @impl GenServer
  def handle_cast(:refresh_station_info, state) do
    station_info = fetch_station_info()
    {:noreply, %{state | station_info: station_info, last_updated: DateTime.utc_now()}}
  end

  @impl GenServer
  def handle_info(:initialize, state) do
    case :timer.send_interval(@update_interval, :refresh_station_status) do
      {:ok, timer} ->
        updated_state = update_status(%{state | timer: timer})
        {:noreply, updated_state}

      {:error, reason} ->
        Logger.error("Failed to start CityBike update timer: #{inspect(reason)}")
        updated_state = update_status(state)
        {:noreply, updated_state}
    end
  end

  @impl GenServer
  def handle_info(:refresh_station_status, state) do
    {:noreply, update_status(state)}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call({:station_query, name}, _from, state) do
    reply =
      with {:ok, station_id} <- Map.fetch(state.station_info, name),
           {:ok, station_data} <- Map.fetch(state.station_status, station_id) do
        %{"num_bikes_available" => _bikes, "num_docks_available" => _docks} = station_data
      else
        e -> Logger.error("#{e}")
      end

    {:reply, reply, state}
  end

  def update_status(state) do
    station_status = fetch_station_status()
    %{state | station_status: station_status, last_updated: DateTime.utc_now()}
  end

  # Returns %{ station_name => station_id }
  defp fetch_station_info() do
    Logger.debug("Refreshing station info")

    %{body: %{"data" => %{"stations" => stations}}} =
      Req.get!(@base <> "/station_information.json", headers: @headers)

    Logger.info("Refreshed station info")
    Map.new(stations, fn %{"name" => name, "station_id" => id} -> {name, id} end)
  end

  # Returns %{ station_id => station_map }
  defp fetch_station_status() do
    Logger.debug("Refreshing station status")

    %{body: %{"data" => %{"stations" => stations}}} =
      Req.get!(@base <> "/station_status.json", headers: @headers)

    Logger.info("Refreshed station status")
    Map.new(stations, fn s -> {s["station_id"], s} end)
  end
end
