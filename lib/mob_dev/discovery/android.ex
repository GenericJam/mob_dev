defmodule MobDev.Discovery.Android do
  @moduledoc "Discovers Android devices and emulators via adb."

  alias MobDev.Device

  @doc "Returns a list of %Device{} for all adb-visible Android devices."
  @spec list_devices() :: [Device.t()]
  def list_devices do
    case System.find_executable("adb") do
      nil -> []
      _   -> do_list()
    end
  end

  defp do_list do
    case run_adb(["devices", "-l"]) do
      {:ok, output} ->
        output
        |> parse_devices_output()
        |> Enum.map(&enrich/1)

      {:error, _} -> []
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
    |> Enum.drop(1)  # skip "List of devices attached" header
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
            %Device{platform: :android, serial: serial, status: :unauthorized,
                    error: "USB debugging not authorized — check device for prompt"}
          String.contains?(rest, "offline") ->
            nil
          String.starts_with?(rest, "device") or String.starts_with?(rest, "no permissions") ->
            type = if String.starts_with?(serial, "emulator"), do: :emulator, else: :physical
            %Device{platform: :android, serial: serial, type: type, status: :discovered}
          true ->
            nil
        end
      _ -> nil
    end
  end

  defp enrich(%Device{status: :unauthorized} = d), do: d
  defp enrich(%Device{serial: serial} = d) do
    name    = getprop(serial, "ro.product.model")
    version = getprop(serial, "ro.build.version.release")
    node    = Device.node_name(d)
    %{d | name: name, version: "Android #{version}", node: node}
  end

  defp getprop(serial, prop) do
    case run_adb(["-s", serial, "shell", "getprop", prop]) do
      {:ok, val} -> String.trim(val)
      _ -> nil
    end
  end

  @doc """
  Check if developer mode is enabled on the device.
  Returns :enabled | :disabled | :unknown.
  """
  @spec developer_mode(String.t()) :: :enabled | :disabled | :unknown
  def developer_mode(serial) do
    case run_adb(["-s", serial, "shell", "settings", "get", "global",
                  "development_settings_enabled"]) do
      {:ok, "1\n"} -> :enabled
      {:ok, "0\n"} -> :disabled
      _            -> :unknown
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
    app_data  = "/data/data/#{package}/files"
    app_cache = "/data/data/#{package}/cache"
    run_adb(["-s", serial, "shell", "am", "force-stop", package])
    # Read MCS label from cache/ (has full s0:cXXX,cYYY) not files/ (bare s0 on Android 15).
    run_adb(["-s", serial, "shell",
             "chcon -hR $(stat -c %C #{app_cache}) #{app_data}/otp"])
    :timer.sleep(300)
    run_adb(["-s", serial, "shell", "am", "start",
             "-n", "#{package}/#{activity}",
             "--ei", "mob_dist_port", to_string(dist_port)])
  end

  defp run_adb(args) do
    cmd = Enum.join(["adb" | args], " ")
    case System.cmd("sh", ["-c", "timeout 8 #{cmd}"], stderr_to_stdout: true) do
      {output, 0}   -> {:ok, output}
      {_output, 124} -> {:error, "adb timed out"}
      {output, _}   -> {:error, output}
    end
  end
end
