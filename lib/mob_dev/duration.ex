defmodule MobDev.Duration do
  @moduledoc false

  @doc """
  Format a microsecond duration as a human-readable string.

      iex> MobDev.Duration.format_us(42)
      "42μs"

      iex> MobDev.Duration.format_us(4_200)
      "4.2ms"

      iex> MobDev.Duration.format_us(4_200_000)
      "4.2s"
  """
  @spec format_us(number()) :: String.t()
  def format_us(us) when us < 1_000, do: "#{us}μs"
  def format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
