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
    # Per-device suffix appended to the BEAM node name to keep concurrent
    # devices distinguishable in Mac's EPMD. Auto-derived from the device
    # serial (Android) or short UDID hex (iOS) by default; the `mix
    # mob.deploy --node-suffix X` flag overrides for scripted scenarios
    # (multiple builds on one sim, custom naming schemes). Sanitised
    # (lowercase a-z0-9_) before being applied at launch time.
    :node_suffix,
    # Device IP for physical iOS: USB link-local (169.254.x.x), WiFi LAN, or Tailscale
    :host_ip,
    # :discovered | :unauthorized | :tunneled | :connected | :error
    :status,
    # error message string if status == :error
    :error,
    # Android: "arm64-v8a" | "armeabi-v7a" | "x86_64" | "x86"
    # iOS: nil — Apple devices are arm64 across the supported floor (iOS 13+)
    #      and the simulator picks arch from the host. Captured via
    #      MobDev.SupportMatrix derivation, not adb getprop.
    :abi,
    # Android API level (29 = Android 10, 33 = Android 13, etc.)
    # iOS major version as integer (17 from "iOS 17.4.1")
    :sdk_level
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

  - Android (emulator/physical): `<app>_android_<serial-stub>@127.0.0.1`
    (unique per device — Mac's EPMD is shared via adb-reverse so the suffix
    is required to avoid collisions when two phones run the same app)
  - iOS simulator: `<app>_ios_<8-char-udid>@127.0.0.1` (unique per simulator,
    matches the name mob_beam.m builds using SIMULATOR_UDID)
  - iOS physical: `<app>_ios@<device-ip>` (mob_beam.m finds IP: USB > WiFi/LAN > Tailscale)
  """
  @spec node_name(t()) :: atom()
  def node_name(%__MODULE__{platform: :android, serial: serial}) when is_binary(serial) do
    suffix = MobDev.Discovery.Android.node_suffix_for(serial)
    :"#{app_name()}_android_#{suffix}@127.0.0.1"
  end

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
  True for devices that aren't a development emulator/simulator.

  Used as a safety predicate by destructive Mix tasks (`mix
  mob.uninstall --all-devices`) so that the broad-sweep flags only
  hit dev-disposable targets by default. Sweeping a personal
  iPhone or shared physical Android is opt-in via `--all-physical`
  or `--device <id>`.

      iex> MobDev.Device.physical?(%MobDev.Device{type: :physical})
      true

      iex> MobDev.Device.physical?(%MobDev.Device{type: :emulator})
      false

      iex> MobDev.Device.physical?(%MobDev.Device{type: :simulator})
      false
  """
  @spec physical?(t()) :: boolean()
  def physical?(%__MODULE__{type: :physical}), do: true
  def physical?(%__MODULE__{}), do: false

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
