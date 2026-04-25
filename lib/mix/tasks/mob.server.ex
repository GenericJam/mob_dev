defmodule Mix.Tasks.Mob.Server do
  use Mix.Task

  @shortdoc "Start the Mob dev server (localhost:4040)"

  @moduledoc """
  Starts the Mob dev server and opens it in the browser.

      mix mob.server
      mix mob.server --port 4040   # default port

  The server provides:
  - Live device status cards (Android + iOS simulator)
  - Per-device deploy buttons ("Update" and "First Deploy")
  - Streaming log panel (logcat / iOS simulator console)

  The server runs until you press Ctrl+C.

  For an interactive IEx session alongside the dashboard:

      iex -S mix mob.server

  ## Under the hood

  `mix mob.server` starts a Phoenix + Bandit supervision tree directly in the
  Mix process — equivalent to `iex -S mix phx.server` for a Phoenix app, except
  it starts the supervisor inline rather than through the application callback:

      Application.ensure_all_started(:bandit)
      Application.ensure_all_started(:phoenix_live_view)

      Supervisor.start_link([
        {Phoenix.PubSub, name: MobDev.PubSub},
        MobDev.Server.Endpoint,          # Bandit HTTP server on port 4040
        MobDev.Server.DevicePoller,      # polls adb + xcrun simctl
        MobDev.Server.LogStreamerSupervisor,  # logcat / simctl log streams
        MobDev.Server.WatchWorker,       # optional file-watch loop
        ...
      ], strategy: :one_for_one)

      open "http://localhost:4040"       # macOS: open, Linux: xdg-open

  The endpoint uses `Bandit.PhoenixAdapter` instead of Cowboy, so there is no
  `:plug_cowboy` dependency. Everything else is standard Phoenix LiveView.
  """

  @default_port 4040

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [port: :integer])
    port = opts[:port] || @default_port
    lan_ip = MobDev.Network.lan_ip()

    configure_endpoint(port, lan_ip)
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    children = [
      {Phoenix.PubSub, name: MobDev.PubSub},
      MobDev.Server.LogBuffer,
      MobDev.Server.ElixirLogBuffer,
      MobDev.Server.Endpoint,
      MobDev.Server.DevicePoller,
      MobDev.Server.LogStreamerSupervisor,
      MobDev.Server.WatchWorker,
      {Task.Supervisor, name: MobDev.Server.TaskSupervisor}
    ]

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: MobDev.Server.Supervisor)

    # Attach the Elixir logger handler now that PubSub and the buffer are up
    MobDev.Server.ElixirLogger.attach()

    local_url = "http://localhost:#{port}"
    IO.puts("")
    IO.puts("#{IO.ANSI.cyan()}=== Mob Dev Server ===#{IO.ANSI.reset()}")
    IO.puts("  #{IO.ANSI.green()}#{local_url}#{IO.ANSI.reset()}")

    if lan_ip do
      lan_url = "http://#{:inet.ntoa(lan_ip)}:#{port}"
      IO.puts("  #{IO.ANSI.green()}#{lan_url}#{IO.ANSI.reset()}  ← open on phone")
      IO.puts("")
      IO.puts(MobDev.QR.render(lan_url))
    end

    IO.puts("")
    open_browser(local_url)

    if IEx.started?() do
      # Unlink the supervisor from this task process so it survives after run/1 returns.
      # Without this the supervisor exits when the Mix task process exits.
      Process.unlink(sup)

      IO.puts(
        "  #{IO.ANSI.green()}IEx ready.#{IO.ANSI.reset()} Elixir log output appears in the dashboard → Elixir panel."
      )

      IO.puts("")
    else
      IO.puts(
        "  Tip: run #{IO.ANSI.cyan()}iex -S mix mob.server#{IO.ANSI.reset()} for an interactive terminal."
      )

      IO.puts("  Press Ctrl+C to stop.")
      IO.puts("")
      Process.sleep(:infinity)
    end
  end

  defp configure_endpoint(port, lan_ip) do
    lan_url = if lan_ip, do: "http://#{:inet.ntoa(lan_ip)}:#{port}", else: nil
    Application.put_env(:mob_dev, :dashboard_lan_url, lan_url)

    Application.put_env(:mob_dev, MobDev.Server.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {0, 0, 0, 0}, port: port],
      url: [host: "localhost", port: port],
      server: true,
      live_view: [signing_salt: "mob_dev_server_salt"],
      secret_key_base: String.duplicate("mob_dev_secret_key_base_not_for_production_", 2)
    )
  end

  defp open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _} -> "xdg-open"
        {:win32, _} -> "start"
      end

    Task.start(fn ->
      # brief pause so the server is up before the browser hits it
      :timer.sleep(500)
      System.cmd(cmd, [url], stderr_to_stdout: true)
    end)
  end
end
