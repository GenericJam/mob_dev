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

    * `--native`         — build native binaries before pushing BEAMs
    * `--no-restart`     — push BEAMs but don't restart the app
    * `--device <id>`    — target a specific device; use `mix mob.devices` to find IDs

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
    device: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    restart = Keyword.get(opts, :restart, true)
    native = Keyword.get(opts, :native, false)
    device_id = opts[:device]
    platforms = resolve_platforms(opts)

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
        ios_device: effective_device_id
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
end
