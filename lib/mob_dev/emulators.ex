defmodule MobDev.Emulators do
  @moduledoc """
  List, start, and stop Android emulators (AVDs) and iOS simulators.

  Backs `mix mob.emulators`. Pure-ish — each function shells out to `emulator`,
  `adb`, or `xcrun simctl` exactly once and returns a parsed result. UI-shape
  decisions (formatting, colors, exit codes) live in the Mix task.

  ## Naming

  Android calls them "emulators", iOS calls them "simulators". This module
  uses "emulator" for the cross-platform concept (configured-but-runnable
  virtual device) and reserves "simulator" for iOS-specific descriptions in
  the help text. The struct's `:platform` field disambiguates.
  """

  defstruct [:platform, :name, :id, :running, :serial, :runtime]

  @type t :: %__MODULE__{
          platform: :android | :ios,
          name: String.t(),
          # Android: AVD name (same as `:name`). iOS: UDID.
          id: String.t(),
          running: boolean(),
          # Android: adb serial (e.g. "emulator-5554") when running, else nil.
          # iOS: same as `:id` (sims have stable UDIDs whether booted or not).
          serial: String.t() | nil,
          # iOS only — e.g. "iOS 26.4".
          runtime: String.t() | nil
        }

  # ── Listing ─────────────────────────────────────────────────────────────────

  @doc """
  Returns all configured Android AVDs, including whether each is currently
  running. Returns `{:error, reason}` when the Android SDK isn't reachable.
  """
  @spec list_android() :: {:ok, [t()]} | {:error, String.t()}
  def list_android do
    with {:ok, emulator_bin} <- find_emulator_binary(),
         {avds_out, 0} <- run_cmd(emulator_bin, ["-list-avds"]),
         running <- running_android_serials() do
      avds =
        avds_out
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "INFO"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn avd_name ->
          serial = Map.get(running, avd_name)

          %__MODULE__{
            platform: :android,
            name: avd_name,
            id: avd_name,
            running: serial != nil,
            serial: serial,
            runtime: nil
          }
        end)

      {:ok, avds}
    else
      {:error, reason} -> {:error, reason}
      {output, _exit} -> {:error, "emulator command failed: #{String.trim(output)}"}
    end
  end

  @doc """
  Returns all installed iOS simulators (across runtimes) marked with their
  current state. Returns `{:error, reason}` on a non-macOS host or when
  xcrun isn't available.
  """
  @spec list_ios() :: {:ok, [t()]} | {:error, String.t()}
  def list_ios do
    cond do
      not macos?() ->
        {:error, "iOS simulators require macOS"}

      System.find_executable("xcrun") == nil ->
        {:error, "xcrun not found — install Xcode command-line tools"}

      true ->
        case run_cmd("xcrun", ["simctl", "list", "devices", "--json"]) do
          {output, 0} -> {:ok, parse_simctl_json(output)}
          {output, _} -> {:error, "simctl failed: #{String.trim(output)}"}
        end
    end
  end

  # ── Starting ────────────────────────────────────────────────────────────────

  @doc """
  Starts an Android AVD by name. Returns `:ok` once the emulator process is
  spawned (it boots in the background; `adb wait-for-device` is the caller's
  responsibility if they need to know when it's ready).
  """
  @spec start_android(String.t()) :: :ok | {:error, String.t()}
  def start_android(avd_name) when is_binary(avd_name) do
    case find_emulator_binary() do
      {:ok, emulator_bin} ->
        # Detach: emulator runs in background; we don't wait. stdin/out/err
        # are pointed at /dev/null so this Mix process can exit cleanly.
        port =
          Port.open({:spawn_executable, emulator_bin}, [
            :binary,
            :exit_status,
            args: ["-avd", avd_name],
            env: [{~c"DYLD_FALLBACK_LIBRARY_PATH", false}]
          ])

        # Detach the port so the emulator survives our exit.
        Port.close(port)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Boots an iOS simulator by UDID and brings the Simulator.app to focus.
  No-op-with-success if the sim is already booted.
  """
  @spec start_ios(String.t()) :: :ok | {:error, String.t()}
  def start_ios(udid) when is_binary(udid) do
    case run_cmd("xcrun", ["simctl", "boot", udid]) do
      {_, 0} ->
        # Open Simulator.app so the user can see it. `-a Simulator` is a no-op
        # if it's already open. Errors here are non-fatal.
        run_cmd("open", ["-a", "Simulator"])
        :ok

      {output, _} ->
        # `simctl boot` returns non-zero when already booted — treat that as ok.
        if String.contains?(output, "Booted") or String.contains?(output, "current state") do
          :ok
        else
          {:error, "simctl boot failed: #{String.trim(output)}"}
        end
    end
  end

  # ── Stopping ────────────────────────────────────────────────────────────────

  @doc """
  Shuts down a running Android emulator by adb serial (e.g. "emulator-5554").
  """
  @spec stop_android(String.t()) :: :ok | {:error, String.t()}
  def stop_android(serial) when is_binary(serial) do
    case run_cmd("adb", ["-s", serial, "emu", "kill"]) do
      {_, 0} -> :ok
      {output, _} -> {:error, "adb emu kill failed: #{String.trim(output)}"}
    end
  end

  @doc """
  Shuts down a booted iOS simulator by UDID. Pass the literal string `"all"`
  to shut down every booted simulator at once (`xcrun simctl shutdown all`).
  """
  @spec stop_ios(String.t()) :: :ok | {:error, String.t()}
  def stop_ios(udid_or_all) when is_binary(udid_or_all) do
    case run_cmd("xcrun", ["simctl", "shutdown", udid_or_all]) do
      {_, 0} -> :ok
      {output, _} -> {:error, "simctl shutdown failed: #{String.trim(output)}"}
    end
  end

  # ── Locate the Android `emulator` binary ────────────────────────────────────
  #
  # Resolution order, picking the first that exists:
  #   1. `<project>/android/local.properties` `sdk.dir` + /emulator/emulator
  #      (matches what mix mob.doctor / mix mob.deploy already use)
  #   2. `$ANDROID_HOME` env var
  #   3. `$ANDROID_SDK_ROOT` env var (older form)
  #   4. `~/Library/Android/sdk` (Android Studio default on macOS)
  #   5. `~/Android/Sdk` (Android Studio default on Linux)

  @doc false
  @spec find_emulator_binary(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def find_emulator_binary(project_dir \\ nil) do
    candidates =
      [
        sdk_dir_from_project(project_dir),
        System.get_env("ANDROID_HOME"),
        System.get_env("ANDROID_SDK_ROOT"),
        Path.expand("~/Library/Android/sdk"),
        Path.expand("~/Android/Sdk")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.join([&1, "emulator", "emulator"]))

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        {:error,
         "Could not find the Android `emulator` binary. Set ANDROID_HOME or " <>
           "configure android/local.properties (run from a project directory)."}

      bin ->
        {:ok, bin}
    end
  end

  defp sdk_dir_from_project(nil) do
    case File.cwd() do
      {:ok, cwd} -> sdk_dir_from_project(cwd)
      _ -> nil
    end
  end

  defp sdk_dir_from_project(dir) do
    case MobDev.NativeBuild.read_sdk_dir(dir) do
      {:ok, sdk} -> sdk
      _ -> nil
    end
  end

  # ── Currently running Android emulators (avd_name → serial) ─────────────────

  defp running_android_serials do
    case run_cmd("adb", ["devices", "-l"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(&adb_line_serial_if_emulator/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn serial -> {serial, avd_name_for_serial(serial)} end)
        |> Enum.reject(fn {_serial, avd} -> is_nil(avd) end)
        |> Map.new(fn {serial, avd} -> {avd, serial} end)

      _ ->
        %{}
    end
  end

  defp adb_line_serial_if_emulator(line) do
    case String.split(line, " ", parts: 2) do
      [serial | _] when serial != "" ->
        if String.starts_with?(serial, "emulator-"), do: serial, else: nil

      _ ->
        nil
    end
  end

  defp avd_name_for_serial(serial) do
    case run_cmd("adb", ["-s", serial, "emu", "avd", "name"]) do
      {output, 0} ->
        # `adb emu avd name` returns the AVD name on the first line, then "OK".
        output
        |> String.split("\n", trim: true)
        |> Enum.find(&(&1 != "" and &1 != "OK"))
        |> case do
          nil -> nil
          line -> String.trim(line)
        end

      _ ->
        nil
    end
  end

  # ── simctl JSON parser ──────────────────────────────────────────────────────

  @doc false
  @spec parse_simctl_json(String.t()) :: [t()]
  def parse_simctl_json(json) do
    case decode_json(json) do
      {:ok, %{"devices" => runtimes}} ->
        Enum.flat_map(runtimes, fn {runtime_id, sims} ->
          runtime_label = pretty_runtime(runtime_id)

          sims
          |> Enum.filter(fn sim ->
            # Some entries have isAvailable=false (deprecated runtimes); skip.
            Map.get(sim, "isAvailable", true)
          end)
          |> Enum.map(fn sim ->
            %__MODULE__{
              platform: :ios,
              name: sim["name"],
              id: sim["udid"],
              running: sim["state"] == "Booted",
              serial: sim["udid"],
              runtime: runtime_label
            }
          end)
        end)

      _ ->
        []
    end
  end

  # com.apple.CoreSimulator.SimRuntime.iOS-26-4 → "iOS 26.4"
  # com.apple.CoreSimulator.SimRuntime.watchOS-11-0 → "watchOS 11.0"
  defp pretty_runtime(id) do
    case Regex.run(Regex.compile!("SimRuntime\\.([A-Za-z]+)-(\\d+)-(\\d+)$"), id) do
      [_, os, major, minor] -> "#{os} #{major}.#{minor}"
      _ -> id
    end
  end

  defp decode_json(json) do
    {:ok, :json.decode(json)}
  rescue
    _ -> :error
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp run_cmd(cmd, args), do: System.cmd(cmd, args, stderr_to_stdout: true)

  defp macos?, do: match?({:unix, :darwin}, :os.type())
end
