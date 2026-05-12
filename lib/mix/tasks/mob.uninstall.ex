defmodule Mix.Tasks.Mob.Uninstall do
  @shortdoc "Uninstall a Mob app (or every Mob app) from connected devices"

  @moduledoc """
  Uninstall a Mob app from one or more connected devices.

  By default, uninstalls the **current project's** app from the
  auto-detected device (when exactly one device is connected). For
  other scopes, pass the relevant flag.

  ## Usage

      mix mob.uninstall                                    # this app, one device
      mix mob.uninstall --all-devices                      # this app, all emulators/sims (NOT phones)
      mix mob.uninstall --all-physical                     # this app, every physical device
      mix mob.uninstall --all-devices --all-physical       # literally everything
      mix mob.uninstall --device emulator-5554             # this app, one named device
      mix mob.uninstall --device foo --device bar          # this app, several
      mix mob.uninstall --all-apps                         # one device, every mob app
      mix mob.uninstall --all-devices --all-apps           # every mob app on every emulator/sim
      mix mob.uninstall --bundle-id com.x.y                # override the project's bundle_id
      mix mob.uninstall --bundle-prefix com.acme           # override the prefix for --all-apps
      mix mob.uninstall --yes                              # skip the confirmation prompt
      mix mob.uninstall --help                             # this help
      mix mob.uninstall -h                                 # this help

  ## Options

    * `--device <id>` — Target a specific device by serial or name.
      Repeat for multiple devices: `--device a --device b`. Works
      for any device type — `--device` is the explicit override
      that bypasses the emulator/physical filter.
    * `--all-devices` — Target every connected **emulator or
      simulator**. Physical devices are NEVER swept by this flag —
      that requires `--all-physical` or `--device <id>` explicitly.
      Rationale: emulators are disposable; physical devices are
      someone's personal phone, with potential to do real damage.
    * `--all-physical` — Target every connected physical device
      (iPhones over USB/Wi-Fi, Android devices via adb). Opt-in.
      Composes with `--all-devices` to mean "literally everything."
    * `--bundle-id <id>` — Uninstall this specific bundle id instead of
      auto-detecting the project's.
    * `--all-apps` — Match every installed package whose id starts with
      `bundle_prefix` (defaults to `MOB_BUNDLE_PREFIX` env or
      `com.example`). Useful for clearing stale test apps in one shot.
    * `--bundle-prefix <prefix>` — Override the prefix used by
      `--all-apps`. Defaults to `MobDev.Config.bundle_prefix/0`.
    * `--yes` — Skip the y/N confirmation prompt. The prompt is skipped
      automatically when targeting exactly one app on exactly one
      device (low blast radius).
    * `--help` / `-h` — Print this help text.

  ## Default scope behaviour

  When you pass no flags:

    * 0 devices connected → exit with "no devices found"
    * 1 emulator/sim connected → auto-target it (physical devices
      are never the auto-target — they require explicit selection)
    * >1 devices or only physical devices → exit with an
      instruction to pass `--device`, `--all-devices`, or
      `--all-physical`. Never silently fans out without consent.

  ## Per-platform mechanics

    * **Android** — `adb -s <serial> uninstall <pkg>`. "Unknown
      package" responses bucket as skipped (the app wasn't installed),
      everything else non-zero is a failure.
    * **iOS simulator** — `xcrun simctl uninstall <udid> <bundle>`,
      followed by a probe through `simctl listapps` to distinguish
      actual uninstall from "wasn't installed in the first place".
    * **iOS physical device** — `xcrun devicectl device uninstall app
      --device <udid> <bundle>`. `ContainerLookupErrorDomain` in
      output → not installed (skipped). Requires the device to be
      paired and trusted via Xcode.
  """
  use Mix.Task

  alias MobDev.{TaskHelp, Uninstaller}

  @switches [
    device: [:string, :keep],
    all_devices: :boolean,
    all_physical: :boolean,
    bundle_id: :string,
    all_apps: :boolean,
    bundle_prefix: :string,
    yes: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @impl Mix.Task
  def run(args) do
    if TaskHelp.help_requested?(args) do
      TaskHelp.print_module_help(__MODULE__)
    else
      do_run(args)
    end
  end

  defp do_run(args) do
    {opts, _positional, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    device_ids = Keyword.get_values(opts, :device)

    project_bundle_id =
      case Mix.Project.get() do
        nil -> nil
        _ -> MobDev.Config.bundle_id()
      end

    uninstaller_opts = [
      device_ids: device_ids,
      all_devices: Keyword.get(opts, :all_devices, false),
      all_physical: Keyword.get(opts, :all_physical, false),
      bundle_id: opts[:bundle_id],
      all_apps: Keyword.get(opts, :all_apps, false),
      bundle_prefix: opts[:bundle_prefix],
      project_bundle_id: project_bundle_id
    ]

    case Uninstaller.plan(uninstaller_opts) do
      {:ok, plan} ->
        confirm_and_run(plan, opts)

      {:error, :no_devices, _} ->
        Mix.shell().error(
          "No devices found. Run `mix mob.devices` to diagnose, " <>
            "or connect a device / boot a simulator."
        )

        exit({:shutdown, 1})

      {:error, :ambiguous_devices, ctx} ->
        Mix.shell().error(
          "Multiple devices connected (#{ctx.detected} total, " <>
            "#{ctx.non_physical} emulator/sim, #{ctx.physical} physical) — " <>
            "pass --device <id> (repeatable), --all-devices to sweep " <>
            "emulators/sims, or --all-physical to sweep phones."
        )

        exit({:shutdown, 1})

      {:error, :no_matching_devices, %{requested: ids}} ->
        Mix.shell().error(
          "No matching devices for --device #{inspect(ids)}. " <>
            "Run `mix mob.devices` to see available IDs."
        )

        exit({:shutdown, 1})

      {:error, :no_dev_devices, %{hint: hint}} ->
        # --all-devices wanted emulators/sims; user only has physical
        # devices connected. Print the rich hint from Uninstaller so
        # the user knows the safe-by-default behaviour.
        Mix.shell().error(hint)
        exit({:shutdown, 1})

      {:error, :no_physical_devices, _} ->
        Mix.shell().error(
          "--all-physical was passed, but no physical devices are connected. " <>
            "Plug in / pair an iPhone or Android device, or pass --all-devices " <>
            "to target emulators/sims instead."
        )

        exit({:shutdown, 1})
    end
  end

  defp confirm_and_run(plan, opts) do
    Enum.each(Uninstaller.preview_lines(plan), fn line -> Mix.shell().info(line) end)
    bundle_count = bundle_count(plan)

    if bundle_count == 0 do
      Mix.shell().info("(no apps to uninstall — nothing to do)")
    else
      if should_skip_prompt?(plan, opts) or confirm_yn() do
        {uninstalled, failed, skipped} = Uninstaller.execute_plan(plan)

        Enum.each(format_summary(uninstalled, failed, skipped), fn line ->
          Mix.shell().info(line)
        end)

        if failed != [], do: exit({:shutdown, 1})
      else
        Mix.shell().info("Aborted.")
      end
    end
  end

  @doc """
  Decides whether to skip the y/N confirmation prompt before executing
  a `plan`. Returns `true` when:

    * the user passed `--yes` (any truthy value at `opts[:yes]`), OR
    * the plan targets exactly one device with exactly one bundle id
      (low blast radius — destructive intent is unambiguous and the
      preview already showed exactly what's about to happen).

  Pure for testability — the original inline `opts[:yes] or
  single_target?` form crashed on `BadBooleanError` because
  `opts[:yes]` is `nil` when the flag isn't passed and Elixir 1.20's
  type checker enforces boolean operands on `or`. Pinning this as a
  helper means the boolean-coercion mistake can't happen again.
  """
  @spec should_skip_prompt?(Uninstaller.plan(), keyword()) :: boolean()
  def should_skip_prompt?(plan, opts) do
    bundle_count = bundle_count(plan)
    device_count = length(plan)
    single_target? = device_count == 1 and bundle_count == 1
    yes? = opts[:yes] == true

    yes? or single_target?
  end

  defp bundle_count(plan), do: plan |> Enum.flat_map(fn {_d, bs} -> bs end) |> length()

  defp confirm_yn do
    case Mix.shell().prompt("Proceed? [y/N]") |> String.trim() |> String.downcase() do
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  @doc """
  Build the summary lines for an uninstall run. Pure — pinned by tests
  in `test/mix/tasks/mob_uninstall_test.exs`. Public so the rendering
  invariants (skipped never gets counted as failed, etc.) can be
  asserted independent of connected hardware.
  """
  @spec format_summary([Uninstaller.result()], [Uninstaller.result()], [Uninstaller.result()]) ::
          [String.t()]
  def format_summary(uninstalled, failed, skipped) do
    cond do
      uninstalled == [] and failed == [] and skipped == [] ->
        ["No-op — nothing to uninstall."]

      true ->
        []
        |> append_block(uninstalled, "Uninstalled", :green)
        |> append_block(skipped, "Skipped (not installed)", :yellow)
        |> append_block(failed, "Failed", :red)
    end
  end

  defp append_block(acc, [], _label, _color), do: acc

  defp append_block(acc, results, label, color) do
    ansi_color =
      case color do
        :green -> IO.ANSI.green()
        :yellow -> IO.ANSI.yellow()
        :red -> IO.ANSI.red()
      end

    marker =
      case color do
        :green -> "✓"
        :yellow -> "—"
        :red -> "✗"
      end

    header = "\n#{ansi_color}#{label}: #{length(results)}#{IO.ANSI.reset()}"

    rows =
      Enum.map(results, fn r ->
        device_label = r.device.name || r.device.serial
        suffix = if r.reason, do: " (#{r.reason})", else: ""
        "  #{marker} #{device_label}: #{r.bundle_id}#{suffix}"
      end)

    acc ++ [header | rows]
  end
end
