defmodule MobDev.Discovery.IOS do
  @moduledoc """
  Discovers iOS simulators via xcrun simctl.

  Physical iOS device support requires libimobiledevice (ideviceinfo, iproxy).
  Best-effort: works if tools are installed, degrades gracefully if not.
  """

  alias MobDev.Device

  @doc "Returns booted iOS simulators."
  @spec list_simulators() :: [Device.t()]
  def list_simulators do
    case System.find_executable("xcrun") do
      nil -> []
      _   -> do_list_simulators()
    end
  end

  @doc "Returns connected physical iOS devices (requires libimobiledevice)."
  @spec list_physical() :: [Device.t()]
  def list_physical do
    case System.find_executable("ideviceinfo") do
      nil -> []
      _   -> do_list_physical()
    end
  end

  @doc "Returns all iOS devices (simulators + physical)."
  @spec list_devices() :: [Device.t()]
  def list_devices do
    list_simulators() ++ list_physical()
  end

  defp do_list_simulators do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted", "--json"],
                    stderr_to_stdout: true) do
      {output, 0} -> parse_simctl_json(output)
      _           -> []
    end
  rescue
    # Jason not available — fall back to simpler text parsing
    _ -> list_simulators_text()
  end

  @doc """
  Parses the JSON output of `xcrun simctl list devices booted --json`.
  Exposed for testing.
  """
  @spec parse_simctl_json(String.t()) :: [Device.t()]
  def parse_simctl_json(json_string) do
    json_string
    |> Jason.decode!()
    |> Map.get("devices", %{})
    |> Enum.flat_map(fn {runtime, devices} ->
      version = parse_runtime_version(runtime)
      Enum.map(devices, &sim_to_device(&1, version))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp list_simulators_text do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted"],
                    stderr_to_stdout: true) do
      {output, 0} -> parse_simctl_text(output)
      _           -> []
    end
  end

  @doc """
  Parses the plain-text output of `xcrun simctl list devices booted`.
  Exposed for testing.
  """
  @spec parse_simctl_text(String.t()) :: [Device.t()]
  def parse_simctl_text(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(&parse_simctl_text_line/1)
  end

  # Parse lines like:
  #   iPhone 17 (78354490-EF38-44D7-A437-DD941C20524D) (Booted)
  defp parse_simctl_text_line(line) do
    case Regex.run(~r/^\s+(.+?) \(([0-9A-F-]{36})\) \(Booted\)/i, line) do
      [_, name, udid] ->
        d = %Device{
          platform: :ios,
          serial:   udid,
          name:     name,
          type:     :simulator,
          status:   :booted,
        }
        [%{d | node: Device.node_name(d)}]
      _ -> []
    end
  end

  defp sim_to_device(%{"udid" => udid, "name" => name, "state" => "Booted"}, version) do
    d = %Device{
      platform: :ios,
      serial:   udid,
      name:     name,
      version:  version,
      type:     :simulator,
      status:   :booted,
    }
    %{d | node: Device.node_name(d)}
  end
  defp sim_to_device(_, _), do: nil

  @doc "Parses a CoreSimulator runtime key into a human-readable version string. Exposed for testing."
  @spec parse_runtime_version(String.t()) :: String.t()
  def parse_runtime_version(runtime) do
    case Regex.run(~r/iOS-(\d+)-(\d+)/, runtime) do
      [_, major, minor] -> "iOS #{major}.#{minor}"
      _ ->
        # "com.apple.CoreSimulator.SimRuntime.iOS-18-0" style
        runtime |> String.split(".") |> List.last() |> String.replace("-", ".")
    end
  end

  defp do_list_physical do
    case System.cmd("ideviceinfo", ["-k", "UniqueDeviceID"], stderr_to_stdout: true) do
      {udid, 0} ->
        udid = String.trim(udid)
        name = ideviceinfo(udid, "DeviceName")
        version = ideviceinfo(udid, "ProductVersion")
        d = %Device{
          platform: :ios,
          serial:   udid,
          name:     name,
          version:  "iOS #{version}",
          type:     :physical,
          status:   :discovered,
        }
        [%{d | node: Device.node_name(d)}]
      _ -> []
    end
  end

  defp ideviceinfo(_udid, key) do
    case System.cmd("ideviceinfo", ["-k", key], stderr_to_stdout: true) do
      {val, 0} -> String.trim(val)
      _        -> nil
    end
  end

  @doc """
  Launches the app on a booted simulator.
  Passes MOB_DIST_PORT as an environment variable (xcrun simctl launch supports this).
  """
  @spec launch_app(String.t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def launch_app(udid, bundle_id, opts \\ []) do
    dist_port = Keyword.get(opts, :dist_port, 9100)
    # xcrun simctl passes SIMCTL_CHILD_* env vars to the launched app (prefix stripped).
    System.cmd("xcrun", ["simctl", "launch", udid, bundle_id],
               stderr_to_stdout: true,
               env: [{"SIMCTL_CHILD_MOB_DIST_PORT", to_string(dist_port)}])
  end

  @spec terminate_app(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def terminate_app(udid, bundle_id) do
    System.cmd("xcrun", ["simctl", "terminate", udid, bundle_id], stderr_to_stdout: true)
  end

  @doc """
  Enables the iOS accessibility system for the given simulator (or "booted").

  SwiftUI lazily populates its accessibility tree only when an accessibility
  service is active. `pegleg_nif:ui_tree/0` requires this to be called once
  per simulator session before it can return elements. Writes the VoiceOver
  preference into the simulator's preference store and posts the Darwin
  notification that UIKit listens to.

  Safe to call repeatedly — idempotent.
  """
  @spec enable_accessibility(String.t()) :: :ok
  def enable_accessibility(udid) do
    System.cmd("xcrun", ["simctl", "spawn", udid, "defaults", "write",
                         "com.apple.Accessibility", "VoiceOverTouchEnabled", "-bool", "YES"],
               stderr_to_stdout: true)
    System.cmd("xcrun", ["simctl", "spawn", udid, "notifyutil",
                         "-p", "com.apple.accessibility.voiceover.status.changed"],
               stderr_to_stdout: true)
    :ok
  end
end
