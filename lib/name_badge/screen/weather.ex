defmodule NameBadge.Screen.Weather do
  @moduledoc """
  Weather screen that displays current weather information.
  """

  use NameBadge.Screen

  require Logger

  @scenes [:now, :next90, :forecast]

  defp header(text) do
    """
    #show heading: set text(font: "Silkscreen", size: 36pt, weight: 400, tracking: -4pt)

    = #{text}

    #v(16pt)
    """
  end

  @impl NameBadge.Screen
  def render(%{weather: nil, loading: true}) do
    """
    #{header("Weather")}

    #align(center + horizon)[
      #text(size: 24pt)[Loading weather data...]
    ]
    """
  end

  def render(%{weather: nil, error: error}) do
    """
    #{header("Weather")}

    #place(center + horizon,
      stack(dir: ttb, spacing: 8pt,
        text(size: 20pt, fill: red)[Error],
        text(size: 16pt)[#{error}]
      )
    )
    """
  end

  def render(%{weather: %{current: current}, scene: :now}) do
    temp_display =
      format_temperature(current.temperature, current.temperature_unit)

    # condition = weather_condition_text(weather.weather_code, weather.is_day)
    wind_display =
      format_wind_speed(
        current.wind_speed,
        current.wind_gust,
        current.wind_speed_unit
      )

    """
    #align(center)[
      #stack(dir: ttb, spacing: 14pt,
        // Location
        // text(size: 16pt, style: "italic")[Trondheim],

        // Temperature (main display)
        text(size: 48pt, weight: 600)[#{temp_display}],

        // Wind speed
        text(size: 20pt)[Vind: #{wind_display}],

        // UV
        text(size: 20pt)[UV: #{current.uv}],

        // Last updated
        text(size: 16pt)[Sist oppdatert: #{format_timestamp(current.timestamp)}]
      )
    ]
    """
  end

  def render(%{weather: %{next90: next90}, scene: :next90}) do
    %{points: points, timestamp: timestamp, description: description} = next90
    scale = 3
    max_height = 3 * scale
    chart_values = Enum.map(points, fn %{"chartValue" => v} -> v end)
    scaled_chart_values = Enum.map(chart_values, fn v -> round(4 * v) end)

    stacks =
      Enum.map(scaled_chart_values, fn v ->
        stack =
          (List.duplicate(~s(histogram_dot[.]), max_height - v) ++
             List.duplicate("histogram_dot[\\#]", v))
          |> Enum.join(", ")

        "stack(dir: ttb, #{stack})"
      end)

    """
    #let histogram_dot(body) = context {
      let size = measure("#")
      box(height: size.height, width: size.width, text(body))
    }

    #align(center)[
      #rect(stack(dir:ltr, #{Enum.join(stacks, ", ")}))
    ]

    #align(center)[
      #stack(dir: ttb, spacing: 14pt,
        text(size: 20pt)[#{description}],

        text(size: 14pt)[Sist oppdatert: #{format_timestamp(timestamp)}],
      )
    ]
    """
  end

  def render(%{weather: %{forecast_short: forecast}, scene: :forecast}) do
    [now | _] = forecast

    next_8 = Enum.take(forecast, 8)

    times =
      Enum.map(next_8, fn forecast -> "[#{timestamp_hour(forecast.timestamp)}]" end)
      |> Enum.join(", ")

    temps =
      Enum.map(next_8, fn forecast -> "[#{round(forecast.temperature)}]" end) |> Enum.join(", ")

    dewpoints =
      Enum.map(next_8, fn forecast -> "[#{round(forecast.dewpoint)}]" end) |> Enum.join(", ")

    precips =
      Enum.map(next_8, fn forecast ->
        if forecast.precipitation.max == forecast.precipitation.min do
          "[#{forecast.precipitation.max}]"
        else
          "[#{forecast.precipitation.min} - #{forecast.precipitation.max}]"
        end
      end)
      |> Enum.join(", ")

    uvs = Enum.map(next_8, fn forecast -> "[#{round(forecast.uv)}]" end) |> Enum.join(", ")

    """
    #{header("Neste 8 timer")}

    #align(center + horizon)[
    #table(
      columns: #{length(next_8) + 1},
      
      [*Tid*], #{times},
      [*Temp*], #{temps},
      [*Dugg*], #{dewpoints},
      [*Regn*], #{precips},
      [*UV*], #{uvs}
    )
    ]
    """
  end

  @impl NameBadge.Screen
  def mount(_args, screen) do
    # Get initial weather data
    weather = NameBadge.Weather.get_current_weather()

    screen =
      case weather do
        nil ->
          screen
          |> assign(weather: nil, loading: true, scene: :now)
          |> assign(button_hints: %{a: "Refresh"})

        weather_data ->
          screen
          |> assign(weather: weather_data, loading: false, scene: :now)
          |> assign(button_hints: %{a: "Refresh", b: "Next"})
      end

    Process.send_after(self(), :check_weather_update, 2_000)

    {:ok, screen}
  end

  @impl NameBadge.Screen
  def handle_button(:button_1, :single_press, screen) do
    # Refresh weather data
    Logger.info("Refreshing weather data...")
    NameBadge.Weather.refresh_weather()

    # Show loading state
    screen =
      screen
      |> assign(weather: nil, loading: true, error: nil)

    # Schedule a check for updated data in 2 seconds
    Process.send_after(self(), :check_weather_update, 2_000)

    {:noreply, screen}
  end

  defp next_scene(:now), do: :next90
  defp next_scene(:next90), do: :forecast
  defp next_scene(:forecast), do: :now

  def handle_button(:button_2, :single_press, screen) do
    screen = screen |> assign(scene: next_scene(screen.assigns.scene))
    {:noreply, screen}
  end

  def handle_button(_, _, screen), do: {:noreply, screen}

  @impl NameBadge.Screen
  def handle_info(:check_weather_update, screen) do
    Process.send_after(self(), :check_weather_update, 10_000)

    weather = NameBadge.Weather.get_current_weather()

    screen =
      case weather do
        nil ->
          assign(screen,
            weather: nil,
            loading: false,
            error: "Unable to fetch weather data"
          )

          {:noreply, screen}

        weather_data ->
          screen = screen |> assign(weather: weather_data, loading: false, error: nil)
          {:noreply, screen}
      end
  end

  # Private helper functions

  defp format_temperature(temp, unit) when is_number(temp) and is_binary(unit) do
    "#{round(temp)}#{unit}"
  end

  defp format_temperature(temp, _unit) when is_number(temp) do
    "#{round(temp)}°C"
  end

  defp format_temperature(_, _), do: "N/A"

  defp format_wind_speed(speed, gust, unit)
       when is_number(speed) and is_number(gust) and is_binary(unit) do
    "#{round(speed)} (#{gust}) #{unit}"
  end

  defp timestamp_hour(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, dt} ->
        dt.hour

      _ ->
        "ERR"
    end
  end

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, dt} ->
        Calendar.strftime(dt, "%H:%M")

      _ ->
        "ERR"
    end
  end
end
