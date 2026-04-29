defmodule Mix.Tasks.Mob.Deploy do
  use Mix.Task

  @shortdoc "Build and deploy to all connected mob devices"

  @moduledoc """
  Compiles the project then pushes BEAM files to all connected
  Android devices and iOS simulators.

  ## Modes

  **Fast deploy** (default) — push BEAMs + restart. Use this for day-to-day
  Elixir code changes. Requires the native app already installed on device.

      mix mob.deploy

  **Full deploy** — build native binary + install APK/app + push BEAMs.
  Use this the first time, or after changes to native C/Java/Swift code.

      mix mob.deploy --native

  ## Options

    * `--native`              — build native binaries before pushing BEAMs
    * `--no-restart`          — push BEAMs but don't restart the app
    * `--device <id>`         — target a specific device; use `mix mob.devices` to find IDs
    * `--schedulers <N>`      — set BEAM scheduler count (saved to mob.exs)
    * `--beam-flags "<flags>"` — arbitrary BEAM flags string (saved to mob.exs)

  ## BEAM scheduler tuning

  The default native build uses `1:1` (single scheduler) for battery efficiency.
  Override for the current deploy and all future deploys until changed:

      # Pin to 2 schedulers
      mix mob.deploy --schedulers 2

      # Let BEAM auto-detect — one scheduler per logical core
      mix mob.deploy --schedulers 0

      # Arbitrary flags (replaces --schedulers)
      mix mob.deploy --beam-flags "-S 4:4 -A 4"

  The chosen value is written to `mob.exs` under `beam_flags:` and reused on
  subsequent `mix mob.deploy` runs that don't pass either flag. The flags are
  written alongside the BEAMs as a `mob_beam_flags` file that the native launcher
  reads at startup — no APK/app rebuild required.

  ## Under the hood

  A fast deploy is equivalent to:

      mix deps.get                                     # only with --native
      mix compile

      # Android
      adb push _build/prod/lib/*/ebin/*.beam /data/data/<pkg>/files/lib/*/ebin/
      adb shell am force-stop <package>               # restart

      # iOS simulator
      xcrun simctl spawn <udid> cp <beam_files> <app_bundle>/

  When Erlang distribution is already reachable (app running, node connected),
  `mix mob.deploy` skips `adb push` and hot-pushes via RPC instead — equivalent
  to calling `nl(Module)` in IEx for every changed module:

      :rpc.call(node, :code, :load_binary, [Module, path, beam_binary])

  With `--native`, it also runs the platform build before pushing BEAMs:

      # Android
      ./gradlew assembleDebug
      adb install -r app/build/outputs/apk/debug/app-debug.apk

      # iOS simulator
      xcodebuild -scheme <app> -destination 'platform=iOS Simulator,...' build
      xcrun simctl install booted <app>.app
  """

  @switches [
    native: :boolean,
    restart: :boolean,
    android: :boolean,
    ios: :boolean,
    device: :string,
    schedulers: :integer,
    beam_flags: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    restart = Keyword.get(opts, :restart, true)
    native = Keyword.get(opts, :native, false)
    device_id = opts[:device]
    platforms = resolve_platforms(opts)
    beam_flags = resolve_beam_flags(opts)

    # When no --device is given and we're doing a native iOS build, auto-detect
    # a connected physical device now so both the native build and the BEAM push
    # target the same device (not all simulators + the phone).
    effective_device_id =
      device_id ||
        if native and :ios in platforms,
          do: MobDev.NativeBuild.detect_physical_ios()

    IO.puts("")

    if native do
      IO.puts("Fetching dependencies...")
      mix = System.find_executable("mix")
      System.cmd(mix, ["deps.get"], into: IO.stream())
    end

    Mix.Task.run("compile")
    IO.puts("\n#{IO.ANSI.cyan()}Deploying to devices...#{IO.ANSI.reset()}\n")

    native_ok =
      if native do
        MobDev.NativeBuild.build_all(platforms: platforms, device: effective_device_id)
      end

    # Skip BEAM push if native build failed — the APK/app bundle isn't installed
    # so run-as / simctl push would fail with misleading errors.
    if native and native_ok == false do
      IO.puts("\n#{IO.ANSI.red()}Native build had failures — see errors above.#{IO.ANSI.reset()}")

      IO.puts(
        "#{IO.ANSI.yellow()}Run `mix mob.doctor` to check your environment, or `mix mob.deploy` (without --native) once the issue is fixed.#{IO.ANSI.reset()}"
      )

      Mix.raise("Native build failed")
    end

    {deployed, failed} =
      MobDev.Deployer.deploy_all(
        restart: restart,
        platforms: platforms,
        force_fs: native,
        device: device_id,
        ios_device: effective_device_id,
        beam_flags: beam_flags
      )

    if deployed == [] and failed == [] do
      IO.puts("#{IO.ANSI.yellow()}No devices found.#{IO.ANSI.reset()}")
      IO.puts("Try: mix mob.devices   to diagnose connection issues")
    else
      if deployed != [] do
        IO.puts("\n#{IO.ANSI.green()}Deployed to #{length(deployed)} device(s)#{IO.ANSI.reset()}")

        if restart do
          IO.puts(
            "Apps restarted. Run #{IO.ANSI.cyan()}mix mob.connect#{IO.ANSI.reset()} to open IEx."
          )
        else
          IO.puts(
            "BEAMs pushed. In IEx: #{IO.ANSI.cyan()}nl(MyModule)#{IO.ANSI.reset()} to hot-load."
          )
        end
      end

      if failed != [] do
        IO.puts("\n#{IO.ANSI.red()}Failed on #{length(failed)} device(s)#{IO.ANSI.reset()}")

        Enum.each(failed, fn d ->
          IO.puts("  ✗ #{d.name || d.serial}: #{d.error}")
        end)
      end
    end
  end

  defp resolve_platforms(opts) do
    android = opts[:android]
    ios = opts[:ios]

    cond do
      android && ios ->
        [:android, :ios]

      android ->
        [:android]

      ios ->
        if macos?() do
          [:ios]
        else
          IO.puts(
            "#{IO.ANSI.yellow()}Warning: --ios is only supported on macOS. Skipping iOS.#{IO.ANSI.reset()}"
          )

          []
        end

      macos?() ->
        [:android, :ios]

      true ->
        [:android]
    end
  end

  defp macos?, do: match?({:unix, :darwin}, :os.type())

  # Resolve --schedulers / --beam-flags into a combined flags string, save to
  # mob.exs, and return it (or the previously saved value if no flags given).
  defp resolve_beam_flags(opts) do
    new_flags = combine_beam_flags(opts[:schedulers], opts[:beam_flags])

    if new_flags do
      save_beam_flags(new_flags)
      IO.puts("#{IO.ANSI.cyan()}* beam flags: #{new_flags} (saved to mob.exs)#{IO.ANSI.reset()}")
      new_flags
    else
      MobDev.Config.load_mob_config()[:beam_flags]
    end
  end

  @doc false
  @spec combine_beam_flags(pos_integer() | nil, String.t() | nil) :: String.t() | nil
  def combine_beam_flags(schedulers, flags_string) do
    case {schedulers, flags_string} do
      {nil, nil} -> nil
      {n, nil} -> "-S #{n}:#{n}"
      {nil, flags} -> String.trim(flags)
      {n, flags} -> "-S #{n}:#{n} #{String.trim(flags)}"
    end
  end

  # Write or update the beam_flags key in mob.exs.
  defp save_beam_flags(flags) do
    path = Path.join(File.cwd!(), "mob.exs")
    unless File.exists?(path), do: Mix.raise("mob.exs not found in current directory")

    content = File.read!(path)
    updated = update_beam_flags_in_config(content, flags)
    File.write!(path, updated)
  end

  @doc false
  @spec update_beam_flags_in_config(String.t(), String.t() | nil) :: String.t()
  def update_beam_flags_in_config(content, flags) do
    value = inspect(flags)

    if content =~ Regex.compile!("^\\s+beam_flags:", "m") do
      Regex.replace(
        Regex.compile!("^(\\s+beam_flags:).*$", "m"),
        content,
        "  beam_flags: #{value}"
      )
    else
      String.trim_trailing(content) <> "\nconfig :mob_dev, beam_flags: #{value}\n"
    end
  end
end
