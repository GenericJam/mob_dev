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
      _ -> do_list_simulators()
    end
  end

  @doc """
  Returns connected physical iOS devices.

  Always runs both USB discovery (`ideviceinfo`) and a LAN EPMD scan in
  parallel. The LAN scan finds the device's actual node IP (which is WiFi-first
  since mob_beam.m prefers a stable LAN address). The USB scan provides the
  UDID and device name. Results are merged: one device with the correct WiFi IP
  and full USB metadata.

  If only one path finds the device, that result is used directly — so this
  works on USB-only setups and WiFi-only setups equally.
  """
  @spec list_physical() :: [Device.t()]
  def list_physical do
    lan = scan_lan_for_physical()
    usb = if System.find_executable("ideviceinfo"), do: do_list_physical(), else: []

    case {lan, usb} do
      # Both found a single device — merge WiFi IP with USB name/serial.
      {[lan_dev], [usb_dev]} ->
        [%{lan_dev | serial: usb_dev.serial, name: usb_dev.name, version: usb_dev.version}]

      # LAN found devices, USB didn't (or multiple — can't safely correlate).
      {[_ | _], _} ->
        lan

      # USB found devices, LAN didn't (USB-only, no WiFi).
      {[], [_ | _]} ->
        usb

      {[], []} ->
        []
    end
  end

  @doc "Returns all iOS devices (simulators + physical)."
  @spec list_devices() :: [Device.t()]
  def list_devices do
    list_simulators() ++ list_physical()
  end

  @doc """
  Queries EPMD at a specific IP for any `*_ios` node and returns a Device, or
  nil if no iOS BEAM node is reachable there. Used for direct connection when
  the IP is already known (e.g. from xcrun devicectl) and ARP may not be warm.
  """
  @spec find_physical_at(String.t()) :: Device.t() | nil
  def find_physical_at(ip) do
    case query_ios_epmd(ip) do
      {:ok, short_name, dist_port} ->
        %Device{
          platform: :ios,
          type: :physical,
          serial: ip,
          name: "iPhone (#{ip})",
          host_ip: ip,
          dist_port: dist_port,
          status: :discovered,
          node: :"#{short_name}@#{ip}"
        }

      _ ->
        nil
    end
  end

  defp do_list_simulators do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted", "--json"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_simctl_json(output)
      _ -> []
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
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted"], stderr_to_stdout: true) do
      {output, 0} -> parse_simctl_text(output)
      _ -> []
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
          serial: udid,
          name: name,
          type: :simulator,
          status: :booted
        }

        [%{d | node: Device.node_name(d)}]

      _ ->
        []
    end
  end

  defp sim_to_device(%{"udid" => udid, "name" => name, "state" => "Booted"}, version) do
    d = %Device{
      platform: :ios,
      serial: udid,
      name: name,
      version: version,
      type: :simulator,
      status: :booted
    }

    %{d | node: Device.node_name(d)}
  end

  defp sim_to_device(_, _), do: nil

  @doc "Parses a CoreSimulator runtime key into a human-readable version string. Exposed for testing."
  @spec parse_runtime_version(String.t()) :: String.t()
  def parse_runtime_version(runtime) do
    case Regex.run(~r/iOS-(\d+)-(\d+)/, runtime) do
      [_, major, minor] ->
        "iOS #{major}.#{minor}"

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
          serial: udid,
          name: name,
          version: "iOS #{version}",
          type: :physical,
          status: :discovered
        }

        [%{d | node: Device.node_name(d)}]

      _ ->
        []
    end
  end

  defp ideviceinfo(_udid, key) do
    case System.cmd("ideviceinfo", ["-k", key], stderr_to_stdout: true) do
      {val, 0} -> String.trim(val)
      _ -> nil
    end
  end

  # Scan the local ARP table for any host running an iOS EPMD node (*_ios).
  # Builds a Device using the node name and IP directly from the EPMD response,
  # so the app name in the Mix project running mob_dev is irrelevant.
  defp scan_lan_for_physical do
    lan_ips =
      case System.cmd("arp", ["-a"], stderr_to_stdout: true) do
        {out, 0} ->
          out
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/\((\d+\.\d+\.\d+\.\d+)\) at [0-9a-f]{2}:[0-9a-f]{2}/, line) do
              [_, ip] -> if String.starts_with?(ip, "169.254."), do: [], else: [ip]
              _ -> []
            end
          end)

        _ ->
          []
      end

    Enum.flat_map(lan_ips, fn ip ->
      case query_ios_epmd(ip) do
        {:ok, short_name, dist_port} ->
          node = :"#{short_name}@#{ip}"

          d = %Device{
            platform: :ios,
            type: :physical,
            serial: ip,
            name: "iPhone (#{ip})",
            host_ip: ip,
            dist_port: dist_port,
            status: :discovered,
            node: node
          }

          [d]

        _ ->
          []
      end
    end)
  end

  # Query EPMD at ip:4369 for any *_ios node.
  # Returns {:ok, short_name, dist_port} using the actual name from EPMD,
  # so the result is independent of which Mix project is running mob_dev.
  defp query_ios_epmd(ip) do
    host = String.to_charlist(ip)

    case :gen_tcp.connect(host, 4369, [:binary, active: false], 1000) do
      {:ok, s} ->
        :gen_tcp.send(s, <<0, 1, ?n>>)

        result =
          case :gen_tcp.recv(s, 0, 1000) do
            {:ok, <<_::32, names::binary>>} ->
              names
              |> String.split("\n")
              |> Enum.find_value(fn line ->
                case Regex.run(~r/name ([a-z0-9_]+_ios[^\s]*) at port (\d+)/i, line) do
                  [_, short_name, port] -> {:ok, short_name, String.to_integer(port)}
                  _ -> nil
                end
              end)
              |> case do
                nil -> {:error, :not_ios_node}
                found -> found
              end

            _ ->
              {:error, :recv_failed}
          end

        :gen_tcp.close(s)
        result

      {:error, reason} ->
        {:error, reason}
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
      env: [{"SIMCTL_CHILD_MOB_DIST_PORT", to_string(dist_port)}]
    )
  end

  @spec terminate_app(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def terminate_app(udid, bundle_id) do
    System.cmd("xcrun", ["simctl", "terminate", udid, bundle_id], stderr_to_stdout: true)
  end

  @doc """
  Restarts the app on a physical iOS device via xcrun devicectl.
  Kills any other user-installed app first (they all share EPMD port 4369 and
  only one can run at a time), then launches the target app fresh.
  """
  @spec restart_app_physical(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def restart_app_physical(udid, bundle_id) do
    kill_other_user_apps_physical(udid, bundle_id)

    # --terminate-existing kills any remaining instance of *this* app atomically.
    System.cmd(
      "xcrun",
      [
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        udid,
        "--terminate-existing",
        bundle_id
      ], stderr_to_stdout: true)
  end

  # Kill any user-installed app that is not `except_bundle`.
  # User apps run from /private/var/containers/Bundle/Application/.
  # All physical-device Mob apps share in-process EPMD on port 4369, so only
  # one can run at a time. We kill the others before launching to avoid the
  # EADDRINUSE crash that would otherwise prevent BEAM from starting.
  defp kill_other_user_apps_physical(udid, except_bundle) do
    {out, 0} =
      System.cmd("xcrun", ["devicectl", "device", "info", "processes", "--device", udid],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(\d+)\s+(.+Bundle\/Application\/.+\.app\/.+)$/, line) do
        [_, pid_str, _path] -> [String.to_integer(pid_str)]
        _ -> []
      end
    end)
    |> Enum.each(fn pid ->
      System.cmd(
        "xcrun",
        [
          "devicectl",
          "device",
          "process",
          "terminate",
          "--device",
          udid,
          "--pid",
          to_string(pid),
          "--kill"
        ], stderr_to_stdout: true)
    end)

    _ = except_bundle
    :ok
  rescue
    _ -> :ok
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
    System.cmd(
      "xcrun",
      [
        "simctl",
        "spawn",
        udid,
        "defaults",
        "write",
        "com.apple.Accessibility",
        "VoiceOverTouchEnabled",
        "-bool",
        "YES"
      ], stderr_to_stdout: true)

    System.cmd(
      "xcrun",
      [
        "simctl",
        "spawn",
        udid,
        "notifyutil",
        "-p",
        "com.apple.accessibility.voiceover.status.changed"
      ], stderr_to_stdout: true)

    :ok
  end
end
