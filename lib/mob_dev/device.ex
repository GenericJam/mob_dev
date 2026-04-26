defmodule MobDev.Device do
  @moduledoc """
  Represents a connected or available device (physical or emulator/simulator).
  """

  @type t :: %__MODULE__{}

  @enforce_keys [:platform, :serial]
  defstruct [
    # :android | :ios
    :platform,
    # "emulator-5554" | "R5CW3089HVB" | "78354490-EF38-..."
    :serial,
    # "Pixel 8" | "iPhone 17"
    :name,
    # "Android 15" | "iOS 18"
    :version,
    # :emulator | :simulator | :physical
    :type,
    # :"mob_demo_android@127.0.0.1"
    :node,
    # 9100
    :dist_port,
    # Device IP for physical iOS: USB link-local (169.254.x.x), WiFi LAN, or Tailscale
    :host_ip,
    # :discovered | :unauthorized | :tunneled | :connected | :error
    :status,
    # error message string if status == :error
    :error
  ]

  @doc """
  Derives a short identifier from a serial for use in node names.

    iex> MobDev.Device.short_id("emulator-5554")
    "5554"

    iex> MobDev.Device.short_id("R5CW3089HVB")
    "HVBA"  # last 4 chars, uppercased

    iex> MobDev.Device.short_id("78354490-EF38-44D7-A437-DD941C20524D")
    "524D"
  """
  @spec short_id(String.t()) :: String.t()
  def short_id(serial) do
    serial
    |> String.replace("-", "")
    |> String.slice(-4..-1)
    |> String.upcase()
  end

  @doc """
  Returns the Erlang node name atom for a device.

  - Android (emulator/physical): `<app>_android@127.0.0.1`
  - iOS simulator: `<app>_ios_<8-char-udid>@127.0.0.1` (unique per simulator,
    matches the name mob_beam.m builds using SIMULATOR_UDID)
  - iOS physical: `<app>_ios@<device-ip>` (mob_beam.m finds IP: USB > WiFi/LAN > Tailscale)
  """
  @spec node_name(t()) :: atom()
  def node_name(%__MODULE__{platform: :android}) do
    :"#{app_name()}_android@127.0.0.1"
  end

  def node_name(%__MODULE__{platform: :ios, host_ip: ip}) when is_binary(ip) do
    :"#{app_name()}_ios@#{ip}"
  end

  def node_name(%__MODULE__{platform: :ios, type: :simulator, serial: serial}) do
    # SIMULATOR_UDID has the same value as the UDID we discover from simctl.
    # mob_beam.m takes the first 8 hex chars (lowercase) for the unique suffix.
    short = serial |> String.replace("-", "") |> String.slice(0, 8) |> String.downcase()
    :"#{app_name()}_ios_#{short}@127.0.0.1"
  end

  def node_name(%__MODULE__{platform: :ios}) do
    :"#{app_name()}_ios@127.0.0.1"
  end

  defp app_name, do: Mix.Project.config()[:app]

  @doc """
  Returns the short ID shown in `mix mob.devices` and accepted by `--device`.

  - Android: the serial as-is (`emulator-5554`, `R5CW3089HVB`)
  - iOS simulator: first 8 hex chars of the UDID, lowercased (`78354490`) —
    same prefix used in the node name
  - iOS physical: full UDID
  """
  @spec display_id(t()) :: String.t()
  def display_id(%__MODULE__{platform: :android, serial: serial}), do: serial

  def display_id(%__MODULE__{platform: :ios, type: :simulator, serial: serial}) do
    serial |> String.replace("-", "") |> String.slice(0, 8) |> String.downcase()
  end

  def display_id(%__MODULE__{platform: :ios, serial: serial}), do: serial

  @doc """
  Returns true if `input` identifies this device.

  Matches `display_id/1` or the full serial, case-insensitively. Used by
  `mix mob.deploy --device <id>` to target a specific device.
  """
  @spec match_id?(t(), String.t()) :: boolean()
  def match_id?(%__MODULE__{} = device, input) when is_binary(input) do
    normalized = String.downcase(input)

    String.downcase(display_id(device)) == normalized or
      String.downcase(device.serial) == normalized
  end

  @doc "Human-readable one-line summary."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = d) do
    type_label =
      case d.type do
        :emulator -> "emulator"
        :simulator -> "simulator"
        :physical -> "physical"
        nil -> "device"
      end

    status_icon =
      case d.status do
        :connected -> "✓"
        :tunneled -> "⟳"
        :discovered -> "·"
        :unauthorized -> "✗"
        :error -> "!"
        _ -> "?"
      end

    name = d.name || d.serial
    version = if d.version, do: " (#{d.version})", else: ""
    "#{status_icon} #{name}#{version}  [#{type_label}]  #{d.serial}"
  end
end
