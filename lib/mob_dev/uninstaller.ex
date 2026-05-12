defmodule MobDev.Uninstaller do
  @moduledoc """
  Uninstall a Mob app (or every Mob-prefixed app) from one or more
  connected devices.

  The user-facing surface is `mix mob.uninstall`. This module owns the
  matrix math + per-platform uninstall mechanics so the Mix task stays
  thin and the testable invariants live here.

  ## Scope dimensions

  Two orthogonal axes:

    * **Devices** — one auto-detected (when exactly one is connected),
      a list of named devices (`--device foo --device bar`), or every
      connected device (`--all-devices`).
    * **Apps** — the current project's bundle id by default, every
      installed package matching the user's `bundle_prefix`
      (`--all-apps`), or an explicit override (`--bundle-id`).

  The (devices × apps) matrix gets flattened into per-pair uninstall
  attempts and the results bucket into `{uninstalled, failed, skipped}`
  — same shape as `MobDev.Deployer.deploy_all/1` so the report
  rendering can borrow the same idiom.

  ## Per-platform mechanics

    * **Android (adb)** — `adb -s <serial> uninstall <pkg>`.
      stderr "Unknown package" → `:skipped` (not installed). All
      other non-zero exits → `:error`.

    * **iOS simulator (xcrun simctl)** — `xcrun simctl uninstall
      <udid> <bundle>`. simctl returns exit 0 whether the app was
      installed or not, so we probe with `xcrun simctl listapps`
      first to distinguish skip-vs-uninstall.

    * **iOS physical device (devicectl)** — `xcrun devicectl device
      uninstall app --device <udid> <bundle>`. Exit 0 → uninstalled.
      `ContainerLookupErrorDomain` in stderr → `:skipped`
      (app not installed on this device).
  """

  alias MobDev.Discovery.{Android, IOS}
  alias MobDev.Device

  @type outcome :: :uninstalled | :skipped | :error
  @type result :: %{
          device: Device.t(),
          bundle_id: String.t(),
          outcome: outcome(),
          reason: String.t() | nil
        }

  @typedoc """
  An uninstall plan — list of (device, [bundle_id]) pairs.
  Built from `plan/1`; executed by `execute_plan/1`.
  """
  @type plan :: [{Device.t(), [String.t()]}]

  @typedoc "Why `plan/1` couldn't build a matrix."
  @type plan_error ::
          :no_devices
          | :ambiguous_devices
          | :no_matching_devices

  @doc """
  Build the (devices × apps) plan without executing it.

  The Mix task uses this to render a "what's about to happen" preview
  and prompt for confirmation before any destructive work runs.

  Recognized opts: same as `uninstall_all/1`.

  Returns:
    * `{:ok, plan}` — plan ready to execute. Each pair has at least
      one device and one bundle id.
    * `{:error, :no_devices, %{detected: 0}}` — no connected devices.
    * `{:error, :ambiguous_devices, %{detected: N}}` — multiple
      devices connected, no `--device` or `--all-devices` flag.
    * `{:error, :no_matching_devices, %{requested: [...]}}` — the
      user passed `--device` IDs but none matched.
  """
  @spec plan(keyword()) :: {:ok, plan()} | {:error, plan_error(), map()}
  def plan(opts \\ []) do
    all = list_all_devices(opts)
    device_ids = opts[:device_ids] || []

    cond do
      all == [] ->
        {:error, :no_devices, %{detected: 0}}

      opts[:all_devices] ->
        {:ok, build_plan(all, opts)}

      device_ids != [] ->
        case filter_devices_by_id(all, device_ids) do
          [] ->
            {:error, :no_matching_devices, %{requested: device_ids, detected: length(all)}}

          matched ->
            {:ok, build_plan(matched, opts)}
        end

      length(all) == 1 ->
        # Auto-detect: exactly one device connected, target it.
        {:ok, build_plan(all, opts)}

      true ->
        {:error, :ambiguous_devices, %{detected: length(all)}}
    end
  end

  @doc """
  Execute a `plan/0` against the connected devices. Returns
  `{uninstalled, failed, skipped}` lists of `result/0` maps.
  """
  @spec execute_plan(plan()) :: {[result()], [result()], [result()]}
  def execute_plan(plan) do
    plan
    |> Enum.flat_map(fn {device, bundles} ->
      Enum.map(bundles, &uninstall_one(device, &1))
    end)
    |> categorize_results()
  end

  @doc """
  Top-level orchestration: discover devices, resolve target apps,
  run the uninstall matrix. Equivalent to `plan/1 |> execute_plan/1`
  but raises on the plan-error cases instead of returning a tuple —
  useful for tests that just want results without going through the
  Mix-task layer.

  Recognized opts: see `plan/1`.
  """
  @spec uninstall_all(keyword()) :: {[result()], [result()], [result()]}
  def uninstall_all(opts \\ []) do
    case plan(opts) do
      {:ok, p} ->
        execute_plan(p)

      {:error, reason, ctx} ->
        raise ArgumentError,
              "Uninstaller.uninstall_all/1 — plan failed (#{reason}): #{inspect(ctx)}"
    end
  end

  defp build_plan(devices, opts) do
    bundle_prefix = opts[:bundle_prefix] || MobDev.Config.bundle_prefix()

    Enum.map(devices, fn d ->
      {d, resolve_apps_for_device(d, opts, bundle_prefix)}
    end)
  end

  # ── Pure helpers (the testable surface) ────────────────────────────────

  @doc """
  Bucket `results` into `{uninstalled, failed, skipped}`.
  Mirrors `MobDev.Deployer.categorize_results/1`.
  """
  @spec categorize_results([result()]) :: {[result()], [result()], [result()]}
  def categorize_results(results) do
    uninstalled = for %{outcome: :uninstalled} = r <- results, do: r
    failed = for %{outcome: :error} = r <- results, do: r
    skipped = for %{outcome: :skipped} = r <- results, do: r
    {uninstalled, failed, skipped}
  end

  @doc """
  Filter a list of `%Device{}` by `device_ids`. When `device_ids` is
  empty, return all. When non-empty, match by serial OR name (case-
  sensitive prefix on serial, exact on either name). Devices not
  found are dropped silently — the caller is expected to validate
  user intent.

  Used by `resolve_devices/1` when the user passes `--device foo`.
  """
  @spec filter_devices_by_id([Device.t()], [String.t()]) :: [Device.t()]
  def filter_devices_by_id(devices, []), do: devices

  def filter_devices_by_id(devices, ids) do
    Enum.filter(devices, fn d ->
      Enum.any?(ids, &Device.match_id?(d, &1))
    end)
  end

  @doc """
  Parse `adb uninstall` output into an outcome.

  Adb's reporting is informal:

    * `"Success"` (sometimes followed by other lines) → `:uninstalled`
    * stderr contains `"Failure"` with `"DELETE_FAILED_INTERNAL_ERROR"`
      and `"Unknown package"` → `:skipped` (not installed)
    * any other non-zero exit → `:error`

  `output` is the combined stdout+stderr; `exit_code` is the process
  exit status. Returns `{outcome, reason}` where `reason` is a
  short user-facing string (or nil for the success case).
  """
  @spec interpret_adb_uninstall(String.t(), non_neg_integer()) ::
          {outcome(), String.t() | nil}
  def interpret_adb_uninstall(output, exit_code) do
    cond do
      exit_code == 0 and String.contains?(output, "Success") ->
        {:uninstalled, nil}

      String.contains?(output, "Unknown package") ->
        {:skipped, "not installed"}

      exit_code != 0 ->
        {:error, String.trim(output)}

      true ->
        # adb sometimes returns exit 0 with no Success marker — be
        # conservative and treat unclear output as an error rather
        # than claiming success.
        {:error, String.trim(output)}
    end
  end

  @doc """
  Parse `xcrun devicectl device uninstall app` output into an outcome.

  devicectl is more structured than adb but its error reporting still
  varies by Xcode version. Patterns:

    * exit 0 → app actually uninstalled (or wasn't there — devicectl
      doesn't always distinguish; check the listapps probe if
      precision matters).
    * `ContainerLookupErrorDomain` → bundle id not installed → `:skipped`.
    * `MissingProfileError` / `NotPaired` → device-pairing problem,
      real error.
    * Anything else exit != 0 → `:error` with trimmed output.

  Output is the combined stdout+stderr; exit_code is the process exit
  status. Returns `{outcome, reason}`.

  Public for regression-testing without a paired physical device.
  """
  @spec interpret_devicectl_uninstall(String.t(), non_neg_integer()) ::
          {outcome(), String.t() | nil}
  def interpret_devicectl_uninstall(output, exit_code) do
    cond do
      exit_code == 0 ->
        {:uninstalled, nil}

      String.contains?(output, "ContainerLookupErrorDomain") or
          String.contains?(output, "not installed") ->
        {:skipped, "not installed"}

      true ->
        {:error, String.trim(output)}
    end
  end

  @doc """
  Parse `adb shell pm list packages <prefix>` output into a list of
  package names. Returns names without the `package:` prefix, sorted
  for deterministic ordering.

      iex> MobDev.Uninstaller.parse_package_list("package:com.example.a\\npackage:com.example.b\\n")
      ["com.example.a", "com.example.b"]

      iex> MobDev.Uninstaller.parse_package_list("")
      []

      iex> MobDev.Uninstaller.parse_package_list("garbage\\n")
      []
  """
  @spec parse_package_list(String.t()) :: [String.t()]
  def parse_package_list(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), "package:", parts: 2) do
        ["", pkg] -> [pkg]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Build a human-readable preview of the uninstall matrix.

  Used by the Mix task to show "what's about to happen" before the
  destructive step. Lines are colored ANSI (faint/cyan/dim) but the
  ANSI codes can be stripped for assertion-friendly tests.
  """
  @spec preview_lines([{Device.t(), [String.t()]}]) :: [String.t()]
  def preview_lines([]), do: ["(no apps to uninstall — nothing to do)"]

  def preview_lines(pairs) do
    header = "About to uninstall:"

    rows =
      Enum.flat_map(pairs, fn {device, bundles} ->
        [
          "  #{IO.ANSI.cyan()}#{device.name || device.serial}#{IO.ANSI.reset()} (#{device.platform}):"
          | Enum.map(bundles, &"    - #{&1}")
        ]
      end)

    [header | rows]
  end

  # ── Device discovery ───────────────────────────────────────────────────

  defp list_all_devices(opts) do
    platforms = opts[:platforms] || [:android, :ios]

    android =
      if :android in platforms,
        do: Android.list_devices() |> Enum.reject(&(&1.status == :unauthorized)),
        else: []

    ios = if :ios in platforms, do: IOS.list_devices(), else: []

    android ++ ios
  end

  # ── App resolution per device ──────────────────────────────────────────

  defp resolve_apps_for_device(device, opts, bundle_prefix) do
    cond do
      opts[:bundle_id] ->
        [opts[:bundle_id]]

      opts[:all_apps] ->
        list_matching_packages(device, bundle_prefix)

      true ->
        [opts[:project_bundle_id] || MobDev.Config.bundle_id()]
    end
  end

  defp list_matching_packages(%Device{platform: :android, serial: serial}, prefix) do
    {output, _} =
      System.cmd("adb", ["-s", serial, "shell", "pm", "list", "packages", prefix],
        stderr_to_stdout: true
      )

    parse_package_list(output)
  end

  defp list_matching_packages(%Device{platform: :ios, serial: udid}, prefix) do
    # simctl returns a hashmap-ish plist of installed apps. Quick
    # path: dump as JSON, walk top-level keys, filter by prefix.
    case System.cmd("xcrun", ["simctl", "listapps", udid], stderr_to_stdout: true) do
      {output, 0} -> simctl_listapps_with_prefix(output, prefix)
      _ -> []
    end
  end

  defp list_matching_packages(_device, _prefix), do: []

  @doc false
  @spec simctl_listapps_with_prefix(String.t(), String.t()) :: [String.t()]
  def simctl_listapps_with_prefix(output, prefix) when is_binary(output) do
    # simctl listapps output is roughly:
    #   "com.example.foo" = { ... };
    #   "com.example.bar" = { ... };
    # Pull the quoted keys via regex; cheap, no plist parser needed
    # for this use case.
    Regex.scan(~r/"([^"]+)"\s*=\s*\{/, output)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
  end

  # ── Per-device uninstall ───────────────────────────────────────────────

  defp uninstall_one(%Device{platform: :android, serial: serial} = d, bundle_id) do
    {output, exit_code} =
      System.cmd("adb", ["-s", serial, "uninstall", bundle_id], stderr_to_stdout: true)

    {outcome, reason} = interpret_adb_uninstall(output, exit_code)
    %{device: d, bundle_id: bundle_id, outcome: outcome, reason: reason}
  end

  defp uninstall_one(%Device{platform: :ios, type: :physical, serial: udid} = d, bundle_id) do
    # iOS physical device: devicectl. Distinct from simctl —
    # devicectl returns non-zero with "ContainerLookupErrorDomain"
    # when the bundle id isn't installed on the device, vs simctl
    # which returns 0 either way.
    args = [
      "devicectl",
      "device",
      "uninstall",
      "app",
      "--device",
      udid,
      bundle_id
    ]

    {output, exit_code} = System.cmd("xcrun", args, stderr_to_stdout: true)
    {outcome, reason} = interpret_devicectl_uninstall(output, exit_code)
    %{device: d, bundle_id: bundle_id, outcome: outcome, reason: reason}
  end

  defp uninstall_one(%Device{platform: :ios, serial: udid} = d, bundle_id) do
    # iOS simulators: simctl uninstall returns 0 either way. Probe
    # the app-list first so the outcome distinguishes
    # "actually-uninstalled" from "wasn't there to begin with".
    case System.cmd("xcrun", ["simctl", "uninstall", udid, bundle_id], stderr_to_stdout: true) do
      {_, 0} ->
        # Was it installed? Check now that simctl has supposedly
        # processed the uninstall. If simctl listapps still shows it,
        # the uninstall didn't take.
        if package_listed_on_sim?(udid, bundle_id) do
          %{
            device: d,
            bundle_id: bundle_id,
            outcome: :error,
            reason: "still installed after uninstall"
          }
        else
          %{device: d, bundle_id: bundle_id, outcome: :uninstalled, reason: nil}
        end

      {output, _} ->
        case classify_simctl_error(output) do
          :not_installed ->
            %{device: d, bundle_id: bundle_id, outcome: :skipped, reason: "not installed"}

          :error ->
            %{device: d, bundle_id: bundle_id, outcome: :error, reason: String.trim(output)}
        end
    end
  end

  defp uninstall_one(%Device{platform: platform} = d, bundle_id) do
    %{
      device: d,
      bundle_id: bundle_id,
      outcome: :skipped,
      reason:
        "platform #{inspect(platform)} not supported by `mix mob.uninstall` (use Xcode/Android Studio)"
    }
  end

  defp package_listed_on_sim?(udid, bundle_id) do
    case System.cmd("xcrun", ["simctl", "listapps", udid], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, ~s("#{bundle_id}"))
      _ -> false
    end
  end

  @doc false
  @spec classify_simctl_error(String.t()) :: :not_installed | :error
  def classify_simctl_error(output) when is_binary(output) do
    if String.contains?(output, "No such application") or
         String.contains?(output, "not installed") do
      :not_installed
    else
      :error
    end
  end
end
