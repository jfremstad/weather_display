defmodule NameBadge.Weather do
  @moduledoc """
  Weather service that fetches current weather data using location from
  NameBadge.TimezoneService and the OpenMeteo API.
  Provides fault-tolerant weather updates with caching.
  """

  use GenServer
  require Logger

  defstruct [
    :weather_data,
    :last_updated,
    :timer,
    :failure_count,
    :circuit_breaker_state
  ]

  # Configuration
  # Respect API rate limits
  @update_interval :timer.minutes(10)
  @max_failures 3
  @circuit_breaker_timeout :timer.minutes(5)
  @call_timeout 5_000

  # API URLs
  @yr_next90 "https://www.yr.no/api/v0/locations/1-2258827/forecast/now?language=nb"
  @yr_now "https://www.yr.no/api/v0/locations/1-2258827/forecast/currenthour"
  @yr_forecast "https://www.yr.no/api/v0/locations/1-2258827/forecast"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Get current weather data. Returns nil if not available.
  """
  def get_current_weather do
    try do
      GenServer.call(__MODULE__, :get_current_weather, @call_timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Weather service call timed out")
        nil

      :exit, {:noproc, _} ->
        Logger.warning("Weather service not available")
        nil
    end
  end

  @doc """
  Force a weather update (useful for refresh button)
  """
  def refresh_weather do
    GenServer.cast(__MODULE__, :refresh_weather)
  end

  # Server Callbacks

  @impl GenServer
  def init(state) do
    Logger.info("Initializing weather service...")

    # Start with circuit breaker closed
    initial_state = %{
      state
      | circuit_breaker_state: :closed,
        failure_count: 0
    }

    send(self(), :initialize)
    {:ok, initial_state}
  end

  @impl GenServer
  def handle_call(:get_current_weather, _from, state) do
    {:reply, state.weather_data, state}
  end

  @impl GenServer
  def handle_cast(:refresh_weather, state) do
    new_state = update_weather(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:initialize, state) do
    # Schedule periodic updates
    case :timer.send_interval(@update_interval, :update_weather) do
      {:ok, timer} ->
        # Do initial weather fetch
        updated_state = update_weather(%{state | timer: timer})
        {:noreply, updated_state}

      {:error, reason} ->
        Logger.error("Failed to start weather update timer: #{inspect(reason)}")
        # Continue without timer - weather can still be refreshed manually
        updated_state = update_weather(state)
        {:noreply, updated_state}
    end
  end

  @impl GenServer
  def handle_info(:update_weather, state) do
    new_state = update_weather(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:retry_after_circuit_breaker, state) do
    Logger.debug("Retrying weather service after circuit breaker timeout")
    new_state = %{state | circuit_breaker_state: :half_open}
    updated_state = update_weather(new_state)
    {:noreply, updated_state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer, do: :timer.cancel(state.timer)
    :ok
  end

  defp update_weather(%{circuit_breaker_state: :open} = state), do: state

  defp update_weather(state) do
    with {:ok, current_weather} <- fetch_weather(),
         {:ok, next90} <- featch_weather_next90(),
         {:ok, forecast} <- fetch_forecast(:short) do
      Logger.debug("Weather updated successfully")

      weather_data = %{current: current_weather, next90: next90, forecast_short: forecast}

      %{
        state
        | weather_data: weather_data,
          last_updated: DateTime.utc_now(),
          failure_count: 0,
          circuit_breaker_state: :closed
      }
    else
      {:error, reason} ->
        Logger.warning("Weather update failed: #{inspect(reason)}")
        record_failure(state, reason)
    end
  end

  defp raw_forecast_to_state(data) do
    %{
      "temperature" => %{"value" => temp},
      "feelsLike" => %{"value" => temp_feels_like},
      "dewPoint" => %{"value" => dewpoint},
      "precipitation" => %{
        "min" => precip_min,
        "max" => precip_max,
        "probability" => _probability
      },
      "wind" => %{"speed" => wind_speed, "gust" => wind_gust},
      "start" => timestamp,
      "uvIndex" => %{"value" => uv}
    } =
      data

    # data = %{
    #   "cloudCover" => %{"fog" => 0, "high" => 0, "low" => 64, "middle" => 0, "value" => 64},
    #   "dewPoint" => %{"value" => 8},
    #   "start" => "2026-07-12T07:00:00+02:00",
    #   "end" => "2026-07-12T08:00:00+02:00",
    #   "feelsLike" => %{"value" => 9},
    #   "humidity" => %{"value" => 88.4},
    #   "precipitation" => %{"max" => 0, "min" => 0, "pop" => 0, "probability" => 0, "value" => 0},
    #   "pressure" => %{"value" => 1031},
    #   "symbol" => %{"clouds" => 2, "n" => 3, "precip" => 0, "sunup" => false, "var" => "Sun"},
    #   "symbolCode" => %{
    #     "next12Hours" => "fair_day",
    #     "next1Hour" => "partlycloudy_day",
    #     "next6Hours" => "fair_day"
    #   },
    #   "temperature" => %{
    #     "probability" => %{"ninetyPercentile" => 11.2, "tenPercentile" => 9.1},
    #     "value" => 10
    #   },
    #   "uvIndex" => %{"value" => 0.6},
    #   "wind" => %{
    #     "direction" => 194,
    #     "gust" => 4.5,
    #     "probability" => %{"ninetyPercentile" => 1.9, "tenPercentile" => 1.3},
    #     "speed" => 1.8
    #   }
    # }

    weather = %{
      temperature: temp,
      feels_like: temp_feels_like,
      wind_speed: wind_speed,
      wind_gust: wind_gust,
      dewpoint: dewpoint,
      timestamp: timestamp,
      precipitation: %{min: precip_min, max: precip_max},
      uv: uv,
      temperature_unit: "°C",
      wind_speed_unit: "m/s"
    }
  end

  defp raw_weather_data_to_state(data) do
    %{
      "temperature" => %{"value" => temp, "feelsLike" => temp_feels_like},
      "wind" => %{"speed" => wind_speed, "gust" => wind_gust},
      "created" => timestamp,
      "uvIndex" => %{"value" => uv}
    } =
      data

    weather = %{
      temperature: temp,
      feels_like: temp_feels_like,
      wind_speed: wind_speed,
      wind_gust: wind_gust,
      timestamp: timestamp,
      uv: uv,
      temperature_unit: "°C",
      wind_speed_unit: "m/s"
    }
  end

  defp fetch_weather() do
    case Req.get(@yr_now, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: data}} ->
        weather = raw_weather_data_to_state(data)
        {:ok, weather}

      {:ok, %{status: status_code}} ->
        Logger.error("Yr API returned #{status_code}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("Yr API call failed: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  defp fetch_forecast(type) do
    type =
      case type do
        :short -> "shortIntervals"
        :long -> "longIntervals"
        :day -> "dayIntervals"
      end

    case Req.get(@yr_forecast, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: %{"created" => timestamp, ^type => data}}} ->
        weather = Enum.map(data, &raw_forecast_to_state/1)
        {:ok, weather}

      {:ok, %{status: status_code}} ->
        Logger.error("Yr API returned #{status_code}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("Yr API call failed: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  defp featch_weather_next90() do
    case Req.get(@yr_next90, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: data}} ->
        %{
          "precipitationForecastDescription" => description,
          "points" => points,
          "created" => timestamp
        } = data

        weather = %{
          description: description,
          points: points,
          timestamp: timestamp
        }

        {:ok, weather}

      {:ok, %{status: status_code}} ->
        Logger.error("Yr API returned #{status_code}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("Yr API call failed: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  defp record_failure(state, _reason) do
    new_failure_count = state.failure_count + 1

    new_state = %{
      state
      | failure_count: new_failure_count
    }

    if new_failure_count >= @max_failures do
      Logger.warning("Circuit breaker opened after #{new_failure_count} failures")
      :timer.send_after(@circuit_breaker_timeout, :retry_after_circuit_breaker)
      %{new_state | circuit_breaker_state: :open}
    else
      new_state
    end
  end
end
