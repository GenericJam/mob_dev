defmodule Mix.Tasks.Mob.Selftest do
  @shortdoc "Run every activated plugin's self-test on the app running on each device"

  @moduledoc """
  Attach to the deployed app on each selected device and run every activated
  plugin's `Mob.Plugin.SelfTest` on it, over distribution.

      mix mob.selftest                       # the one connected emulator/simulator
      mix mob.selftest --device emulator-5554
      mix mob.selftest --all-devices --timeout 10000

  The app must be deployed (`mix mob.deploy`) with the plugins activated in
  `mob.exs`; a self-test is only on the device if the build that is running
  included it. Each plugin's `selftest: Module` from its manifest is called
  with `%{platform: :ios | :android, device: :simulator | :emulator |
  :physical}` and gets one line in a table per device: `pass`, `FAIL` with
  the reason, or `skip` with why (a plugin without a self-test is a skip,
  so it is visible). A self-test that raises, exits, times out or returns
  something outside the contract is a `FAIL`.

  Before the tests run, the permissions the manifests declare are granted
  on emulators and simulators (`adb shell pm grant`, `xcrun simctl privacy
  grant`), so no system prompt stands between a self-test and its native
  code. The app is then relaunched (as `mix mob.connect` does), because a
  simulator may terminate an app whose privacy settings changed.
  `--no-restart` attaches to the app as it is and grants nothing.

  ## Options

    * `--device` / `--only` (`-d`) — target a device by serial/udid
      (serial, udid or short id). Repeatable
    * `--all-devices`  — every emulator and simulator
    * `--all-physical` — every physical device (with `--all-devices`: everything)
    * `--ios-only` / `--android-only` — restrict discovery to one platform
    * `--timeout MS` — per self-test, in milliseconds (default: 30000)
    * `--no-restart` — do not relaunch the app before testing (and do not
      grant permissions)
    * `--cookie C` — dist cookie (default: the app's private cookie)

  With no selection flags exactly one emulator/simulator is picked, and a
  device another `agent-device` session holds is left alone unless named.

  ## Exit status

  Non-zero when any self-test failed, or a selected device's node could not
  be reached (a test that could not run is not a test that passed).
  """

  use Mix.Task

  alias Mix.Tasks.Mob.Connect
  alias Mix.Tasks.Mob.Deploy
  alias MobDev.{Connector, Device, DeviceLeases, TaskHelp, TaskTargets}
  alias MobDev.Plugin.SelfTest

  @switches [
    device: :keep,
    only: :keep,
    all_devices: :boolean,
    all_physical: :boolean,
    ios_only: :boolean,
    android_only: :boolean,
    timeout: :integer,
    restart: :boolean,
    cookie: :string
  ]

  @impl Mix.Task
  def run(args), do: run(args, %{})

  @doc false
  # `deps` replaces the I/O: `:discover` (platforms -> devices, as
  # `Mix.Tasks.Mob.Deploy.discover_devices/1`), `:leases` (-> the agent-device
  # claims), `:grant` (device, plugins -> grants, as
  # `SelfTest.grant_permissions/4` with the app's bundle id), `:connect`
  # (opts -> {connected, failed} devices, as `MobDev.Connector.connect_all/1`),
  # `:plugins` (-> activated plugins) and `:run_all` (node, ctx, opts ->
  # entries, as `SelfTest.run_all/3`).
  @spec run([String.t()], map()) :: :ok
  def run(args, deps) do
    if TaskHelp.help_requested?(args) do
      TaskHelp.print_module_help(__MODULE__)
    else
      selftest(parse!(args), Map.merge(default_deps(), deps))
    end
  end

  defp parse!(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [d: :device])

    unless invalid == [] and argv == [] do
      bad = Enum.map(invalid, &elem(&1, 0)) ++ argv
      Mix.raise("Unknown option(s) or argument(s): #{Enum.join(bad, ", ")}")
    end

    if Keyword.get(opts, :timeout, 1) < 1,
      do: Mix.raise("--timeout must be a positive number of ms")

    opts
  end

  defp selftest(opts, deps) do
    Mix.Task.run("app.config")
    targets = select_devices!(opts, deps)
    plugins = deps.plugins.()
    restart? = Keyword.get(opts, :restart, true)

    # Grants come before the (re)launch: a simulator may terminate an app
    # whose privacy settings change, and a self-test must not meet a prompt.
    if restart?, do: Enum.each(targets, &grant(&1, plugins, deps))

    {connected, failed} =
      deps.connect.(
        cookie: opts[:cookie],
        only: Enum.map(targets, & &1.serial),
        platforms: targets |> Enum.map(& &1.platform) |> Enum.uniq(),
        restart: restart?
      )

    run_opts = [plugins: plugins, timeout_ms: Keyword.get(opts, :timeout, 30_000)]
    results = Enum.map(connected, &run_device(&1, run_opts, deps))

    seen = MapSet.new(connected ++ failed, & &1.serial)
    missing = Enum.reject(targets, &MapSet.member?(seen, &1.serial))

    unreachable =
      Enum.map(failed, &"#{label(&1)}: node not reachable (#{&1.error || &1.status})") ++
        Enum.map(missing, &"#{label(&1)}: not found when connecting")

    Enum.each(unreachable, &IO.puts("\n" <> &1))

    failures =
      for {device, entries} <- results,
          %{plugin: plugin, result: {:fail, reason}} <- SelfTest.failures(entries),
          do: "#{label(device)} #{plugin}: #{reason}"

    case failures ++ unreachable do
      [] -> IO.puts("\nmob.selftest passed on #{length(results)} device(s)")
      problems -> Mix.raise("mob.selftest failed:\n  " <> Enum.join(problems, "\n  "))
    end

    :ok
  end

  defp select_devices!(opts, deps) do
    platforms =
      case Connect.resolve_platforms(opts, MobDev.Config.platforms()) do
        {:ok, platforms} -> platforms
        {:error, message} -> Mix.raise(message)
      end

    ids = Keyword.get_values(opts, :device) ++ Keyword.get_values(opts, :only)
    opts = Keyword.put(opts, :leases, deps.leases.())

    case TaskTargets.resolve(deps.discover.(platforms), ids, opts) do
      {:ok, devices} -> devices
      {:error, reason, context} -> Mix.raise(Deploy.target_error(reason, context, ids))
    end
  end

  defp grant(%Device{} = device, plugins, deps) do
    case deps.grant.(device, plugins) do
      [] ->
        :ok

      grants ->
        IO.puts("\n#{label(device)} permissions:")

        Enum.each(grants, fn %{plugin: plugin, permission: perm, status: status} ->
          case status do
            :ok -> IO.puts("  granted #{perm} (#{plugin})")
            {:error, out} -> IO.puts("  could not grant #{perm} (#{plugin}): #{out}")
          end
        end)
    end
  end

  defp run_device(%Device{} = device, run_opts, deps) do
    ctx = %{platform: device.platform, device: device.type || :physical}
    IO.puts("\n#{label(device)} #{ctx.platform} #{ctx.device}")

    entries = deps.run_all.(device.node, ctx, run_opts)
    Enum.each(SelfTest.table(entries), &IO.puts("  " <> &1))
    IO.puts("  " <> SelfTest.summary(entries))
    {device, entries}
  end

  defp label(%Device{name: name, serial: serial}), do: "#{name || serial} (#{serial})"

  defp default_deps do
    %{
      discover: &Deploy.discover_devices/1,
      leases: &DeviceLeases.load/0,
      grant: &grant_permissions/2,
      connect: &Connector.connect_all/1,
      plugins: &MobDev.Plugin.activated_with_verify/0,
      run_all: &SelfTest.run_all/3
    }
  end

  defp grant_permissions(%Device{platform: platform} = device, plugins) do
    bundle_id =
      case platform do
        :ios -> MobDev.Config.ios_bundle_id()
        :android -> MobDev.Config.bundle_id()
      end

    SelfTest.grant_permissions(device, plugins, bundle_id, fn exe, argv ->
      System.cmd(exe, argv, stderr_to_stdout: true)
    end)
  end
end
