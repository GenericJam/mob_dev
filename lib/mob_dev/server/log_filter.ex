defmodule MobDev.Server.LogFilter do
  @moduledoc """
  Pure filter functions for the log stream. Extracted here so they can be
  unit-tested without mounting a LiveView.
  """

  @doc """
  Filters a list of log lines by device/category filter, then by text.

  `filter` is `:all`, `:app`, or a device serial string.
  `text` is a comma-separated list of search terms (empty string = no filter).
  Lines newest-first; order is preserved.
  """
  @type line :: map()
  @type filter :: :all | :app | String.t()

  @spec apply([line()], filter(), String.t()) :: [line()]
  def apply(lines, filter, text) do
    lines
    |> by_device(filter)
    |> by_text(text)
  end

  @doc "Returns true if the line passes both the device filter and the text filter."
  @spec matches?(line(), filter(), String.t()) :: boolean()
  def matches?(line, filter, text) do
    by_device?(line, filter) and by_text?(line, text)
  end

  # ── Device filter ─────────────────────────────────────────────────────────────

  @spec by_device([line()], filter()) :: [line()]
  def by_device(lines, :all), do: lines
  def by_device(lines, :app), do: Enum.filter(lines, & &1.mob)
  def by_device(lines, serial), do: Enum.filter(lines, &(&1.serial == serial))

  @spec by_device?(line(), filter()) :: boolean()
  def by_device?(_, :all), do: true
  def by_device?(line, :app), do: line.mob
  def by_device?(line, serial), do: line.serial == serial

  # ── Text filter ───────────────────────────────────────────────────────────────

  @spec by_text([line()], String.t()) :: [line()]
  def by_text(lines, ""), do: lines
  def by_text(lines, text), do: Enum.filter(lines, &by_text?(&1, text))

  @spec by_text?(line(), String.t()) :: boolean()
  def by_text?(_, ""), do: true

  def by_text?(line, text) do
    terms = text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case terms do
      [] ->
        true

      _ ->
        haystack = String.downcase((line.message || "") <> " " <> (line.raw || ""))
        Enum.any?(terms, &String.contains?(haystack, String.downcase(&1)))
    end
  end
end
