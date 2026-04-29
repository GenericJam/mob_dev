defmodule MobDev.Discovery.Android do
  @moduledoc "Discovers Android devices and emulators via adb."

  alias MobDev.Device

  @doc "Returns a list of %Device{} for all adb-visible Android devices."
  @spec list_devices() :: [Device.t()]
  def list_devices do
    case System.find_executable("adb") do
      nil -> []
      _ -> do_list()
    end
  end

  defp do_list do
    case run_adb(["devices", "-l"]) do
      {:ok, output} ->
        output
        |> parse_devices_output()
        |> Enum.map(&enrich/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Parses the raw output of `adb devices -l` into a list of `%Device{}`.
  Does not perform enrichment (no adb calls for name/version).
  Exposed for testing.
  """
  @spec parse_devices_output(String.t()) :: [Device.t()]
  def parse_devices_output(output) do
    output
    |> String.split("\n")
    # skip "List of devices attached" header
    |> Enum.drop(1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&parse_device_line/1)
    |> Enum.reject(&is_nil/1)
  end

  # Parse lines like:
  #   emulator-5554          device product:sdk_gphone64_arm64 ...
  #   R5CW3089HVB            unauthorized
  #   192.168.1.5:5555       device
  defp parse_device_line(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [serial, rest] ->
        cond do
          String.contains?(rest, "unauthorized") ->
            %Device{
              platform: :android,
              serial: serial,
              status: :unauthorized,
              error: "USB debugging not authorized — check device for prompt"
            }

          String.contains?(rest, "offline") ->
            nil

          String.starts_with?(rest, "device") or String.starts_with?(rest, "no permissions") ->
            type = if String.starts_with?(serial, "emulator"), do: :emulator, else: :physical
            %Device{platform: :android, serial: serial, type: type, status: :discovered}

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp enrich(%Device{status: :unauthorized} = d), do: d

  defp enrich(%Device{serial: serial} = d) do
    name = getprop(serial, "ro.product.model")
    version = getprop(serial, "ro.build.version.release")

    # Compute the node name from the device's stable hardware serial
    # (`ro.serialno`) rather than the adb id we used to talk to it, so the
    # node atom is the same whether we connected over USB or WiFi-adb.
    # Falls back to Device.node_name/1 (pure, sanitizes Device.serial) if
    # getprop fails — keeps a deterministic answer even on quirky devices.
    node =
      case getprop(serial, "ro.serialno") do
        hw when is_binary(hw) and hw != "" ->
          app = Mix.Project.config()[:app]
          :"#{app}_android_#{node_suffix_for(hw)}@127.0.0.1"

        _ ->
          Device.node_name(d)
      end

    # Skip IP discovery for emulators — `ip route get` returns the
    # emulator's internal NAT subnet (10.0.2.x) which isn't reachable
    # from the host and just creates confusion in the devices listing.
    host_ip = if d.type == :emulator, do: nil, else: device_ip(serial)
    %{d | name: name, version: "Android #{version}", node: node, host_ip: host_ip}
  end

  defp getprop(serial, prop) do
    case run_adb(["-s", serial, "shell", "getprop", prop]) do
      {:ok, val} -> String.trim(val)
      _ -> nil
    end
  end

  # Returns the device's WiFi IPv4 address, or nil if unavailable.
  # WiFi-adb-connected devices have IP:port as their serial — extract from there.
  # USB-connected devices need a shell call: `ip route get 1` returns a line
  # whose 7th token is the device's WiFi IP for outbound traffic.
  defp device_ip(serial) do
    case extract_ip_from_serial(serial) do
      nil -> shell_ip(serial)
      ip -> ip
    end
  end

  defp extract_ip_from_serial(serial) do
    case Regex.run(~r/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):\d+$/, serial) do
      [_, ip] -> ip
      _ -> nil
    end
  end

  # Try `ip route get 1.1.1.1` — returns the source IP used for outbound
  # traffic. More portable than parsing `ip addr show wlan0` since the
  # interface name varies (wlan0, rmnet_data*, etc.).
  defp shell_ip(serial) do
    case run_adb(["-s", serial, "shell", "ip", "route", "get", "1.1.1.1"]) do
      {:ok, out} ->
        case Regex.run(~r/\bsrc\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/, out) do
          [_, ip] -> ip
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Check if developer mode is enabled on the device.
  Returns :enabled | :disabled | :unknown.
  """
  @spec developer_mode(String.t()) :: :enabled | :disabled | :unknown
  def developer_mode(serial) do
    case run_adb([
           "-s",
           serial,
           "shell",
           "settings",
           "get",
           "global",
           "development_settings_enabled"
         ]) do
      {:ok, "1\n"} -> :enabled
      {:ok, "0\n"} -> :disabled
      _ -> :unknown
    end
  end

  @doc """
  Restarts the app on the device, optionally passing a dist_port intent extra.

  Runs `chcon` before `am start` to heal any SELinux MCS category mismatch on OTP
  files. This mismatch happens when the APK is reinstalled and Android assigns a new
  MCS category to the package — files pushed via `adb push` retain the old label and
  the BEAM can't access them.

  The label is copied from the app's `cache/` directory, not `files/`. On Android 15
  the `files/` directory itself lacks MCS categories (`s0` only), whereas `cache/`
  always carries the full `s0:cXXX,cYYY` label that installd assigns to the package.

  The `chcon` requires root (`adb root`) — it's silently skipped on non-rooted devices
  where the OTP files were pushed with the correct label to begin with.
  """
  @spec restart_app(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def restart_app(serial, package, activity, opts \\ []) do
    dist_port = Keyword.get(opts, :dist_port, 9100)
    node_suffix = Keyword.get(opts, :node_suffix) || device_node_suffix(serial)

    app_data = "/data/data/#{package}/files"
    app_cache = "/data/data/#{package}/cache"
    run_adb(["-s", serial, "shell", "am", "force-stop", package])
    # Read MCS label from cache/ (has full s0:cXXX,cYYY) not files/ (bare s0 on Android 15).
    run_adb(["-s", serial, "shell", "chcon -hR $(stat -c %C #{app_cache}) #{app_data}/otp"])
    :timer.sleep(300)

    run_adb(
      [
        "-s",
        serial,
        "shell",
        "am",
        "start",
        "-n",
        "#{package}/#{activity}",
        "--ei",
        "mob_dist_port",
        to_string(dist_port),
        "--es",
        "mob_node_suffix",
        node_suffix
      ]
    )
  end

  @doc """
  Sanitizes a string into a Mob node-name suffix. Pure — no adb calls.

      node_suffix_for("ZY22CRLMWK")        → "zy22crlmwk"
      node_suffix_for("10.0.0.82:5555")    → "10_0_0_82"
      node_suffix_for("emulator-5554")     → "emulator_5554"

  Used as the final transformation step by `device_node_suffix/1` (which
  asks the device for a stable hardware serial and runs it through here).
  Tests use it directly to verify the sanitization rules.
  """
  @spec node_suffix_for(String.t()) :: String.t()
  def node_suffix_for(serial) when is_binary(serial) do
    # Strip the :port (WiFi-adb form), then sanitize: lowercase, replace any
    # non-alphanumeric run with a single underscore, trim leading/trailing.
    serial
    |> String.split(":", parts: 2)
    |> hd()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  @doc """
  Returns the Mob node-name suffix for the device reachable via the given
  adb identifier. The suffix is derived from the device's hardware serial
  (`ro.serialno`), which is stable across USB and WiFi-adb identifiers for
  the same physical phone — so a deploy that targets `ZY22K6BSJM` (USB)
  and a bench that targets `10.0.0.17:5555` (WiFi) both end up using the
  same node name.

  Falls back to sanitizing the adb identifier itself when `getprop` fails
  (e.g. unrooted device, missing executable, dead transport). The
  fallback is the legacy behaviour, kept so a bench against a
  pre-suffix-aware deploy still converges on *some* deterministic name.

  Single adb shell call (~100–300 ms). Suitable for once-per-launch use
  by the deployer and bench.
  """
  @spec device_node_suffix(String.t()) :: String.t()
  def device_node_suffix(adb_id) when is_binary(adb_id) do
    case System.cmd("adb", ["-s", adb_id, "shell", "getprop", "ro.serialno"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        hardware_serial = String.trim(output)

        if hardware_serial == "",
          do: node_suffix_for(adb_id),
          else: node_suffix_for(hardware_serial)

      _ ->
        node_suffix_for(adb_id)
    end
  end

  defp run_adb(args) do
    cmd = Enum.join(["adb" | args], " ")

    case System.cmd("sh", ["-c", "timeout 8 #{cmd}"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 124} -> {:error, "adb timed out"}
      {output, _} -> {:error, output}
    end
  end
end
