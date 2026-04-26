defmodule Mix.Tasks.Mob.Connect do
  use Mix.Task

  @shortdoc "Connect IEx to all running mob devices"

  @moduledoc """
  Discovers connected Android and iOS devices, sets up USB tunnels,
  restarts the app on each device, waits for Erlang nodes to come online,
  then drops into an IEx session connected to all of them.

      mix mob.connect

  ## Options

    * `--no-iex`   — set up connections but don't start IEx (print node names instead)
    * `--name`     — local node name for this session (default: `mob_dev@127.0.0.1`)
    * `--cookie`   — Erlang cookie (default: `mob_secret`)

  ## Multiple simultaneous sessions

  Because Erlang distribution allows many nodes to connect to the same device,
  you can run multiple independent sessions at the same time. Use `--name` to
  give each one a unique identity:

      # Terminal 1 — interactive developer session
      mix mob.connect --name mob_dev_1@127.0.0.1

      # Terminal 2 — agent or second developer
      mix mob.connect --name mob_dev_2@127.0.0.1

  Both see the same live device state and can call `Mob.Test.*` and `nl/1`
  independently without interfering with each other.

  ## IEx + dashboard in one process

  For an interactive session alongside the dev dashboard, use:

      iex -S mix mob.server

  This starts the dashboard at `localhost:4040` and gives you an IEx prompt in
  the same process. Run `mix mob.connect` (or let the dashboard auto-connect)
  to attach to device nodes, then call `Mob.Test.*` directly from the IEx prompt.
  This is the recommended setup when working alongside an agent — the agent uses
  Tidewave to execute `Mob.Test.*` calls in the same running session.

  ## iOS physical device connectivity

  Physical iPhones support three connection modes. The BEAM picks the right one
  automatically at startup based on which network interfaces are present:

  | Priority | Connection | Node name | When |
  |----------|------------|-----------|------|
  | 1 | WiFi / LAN | `<app>_ios@10.0.0.x` | On the same network as the Mac |
  | 1 | Tailscale  | `<app>_ios@100.x.x.x` | Any network — see below |
  | 2 | USB only   | `<app>_ios@169.254.x.x` | Cable plugged in, no WiFi |
  | 3 | None       | `<app>_ios@127.0.0.1` | No network |

  WiFi is preferred over USB so the node IP stays stable across cable plug/unplug.
  Plugging or unplugging the USB cable does not change the node name as long as
  WiFi is available. The node only falls back to the USB link-local address when
  there is no WiFi at all.

  **The node name is still fixed at app launch.** If distribution isn't working,
  force-quit the app on the iPhone and relaunch it so it picks up the current
  network state.

  **USB** is the default and works with no setup. Plug in the cable and run
  `mix mob.connect`.

  **WiFi** works automatically when the Mac and iPhone are on the same network. If
  it doesn't connect, check: was the app last launched with USB plugged in? If so,
  force-quit and relaunch the app (without USB), then run `mix mob.connect` again.
  Public WiFi and corporate networks often block device-to-device traffic (client
  isolation) — use Tailscale in those environments.

  **Tailscale** lets you connect over any network including cellular. It is a free
  mesh VPN (free for personal use at tailscale.com). Install it on both the Mac
  and iPhone, sign in to the same account, and `mix mob.connect` works the same
  way regardless of what network either device is on. Tailscale must be active on
  the iPhone before the app launches — the node name is fixed at BEAM startup.

  **Personal Hotspot** (iPhone sharing its cellular connection as WiFi) also works
  automatically — the Mac connects to the hotspot and the LAN detection picks up
  the `172.20.10.x` address.

  ## Under the hood

  `mix mob.connect` is a convenience wrapper around standard Erlang distribution setup:

      # Android: set up adb port tunnels so the device BEAM registers in the Mac's EPMD
      adb reverse tcp:4369 tcp:4369   # EPMD: device → Mac
      adb forward tcp:9100 tcp:9100   # dist port: Mac → device

      # iOS simulator shares the Mac's network stack — no tunnelling needed

      # iOS physical: BEAM registers its own in-process EPMD on the device;
      # Mac connects directly to the device IP (USB link-local, WiFi, or Tailscale)

      # Then, in Elixir:
      Node.start(:"mob_dev@127.0.0.1", :longnames)
      Node.set_cookie(:mob_secret)
      Node.connect(:"my_app_android@127.0.0.1")
      Node.connect(:"my_app_ios@127.0.0.1")
      IEx.start([])

  You can do all of this by hand in any IEx session — `mix mob.connect` just
  discovers the device node names and wires up the tunnels automatically.
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [iex: :boolean, cookie: :string, name: :string],
        aliases: [c: :cookie, n: :name]
      )

    no_iex = Keyword.get(opts, :iex, true) == false
    cookie = opts |> Keyword.get(:cookie, "mob_secret") |> String.to_atom()
    local_name = opts |> Keyword.get(:name, "mob_dev@127.0.0.1") |> String.to_atom()

    Mix.Task.run("app.config")

    {connected, _failed} = MobDev.Connector.connect_all(cookie: cookie)

    if connected == [] do
      IO.puts("\n#{IO.ANSI.yellow()}No nodes connected. Nothing to do.#{IO.ANSI.reset()}\n")
      IO.puts("Try: mix mob.devices   to diagnose connection issues")
    else
      if no_iex do
        IO.puts("\nNodes ready:")
        Enum.each(connected, fn d -> IO.puts("  #{d.node}") end)
      else
        start_iex(connected, cookie, local_name)
      end
    end
  end

  defp start_iex(connected, cookie, local_name) do
    IO.puts(
      "\n#{IO.ANSI.cyan()}Starting IEx (connected to #{length(connected)} device(s))...#{IO.ANSI.reset()}"
    )

    IO.puts("  Node.list()       — see connected nodes")
    IO.puts("  nl(MyModule)      — hot-push code to all nodes")
    IO.puts("")

    # Start distribution on the local node and connect to all devices.
    unless Node.alive?() do
      Node.start(local_name, :longnames)
      Node.set_cookie(cookie)
    end

    Enum.each(connected, fn d ->
      Node.set_cookie(d.node, cookie)
      Node.connect(d.node)
    end)

    # Hand off to IEx in this process — tunnels stay alive via adb daemon.
    IEx.start()
  end
end
