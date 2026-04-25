defmodule MobDev.Server.DashboardLive do
  use Phoenix.LiveView, layout: {MobDev.Server.Layouts, :app}

  alias MobDev.Server.{LogFilter, WatchWorker}

  @log_limit 500
  @elixir_limit 200
  @log_topic "logs"
  @elixir_topic "elixir_logs"
  @device_topic "devices"
  @watch_topic "watch"

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MobDev.PubSub, @device_topic)
      Phoenix.PubSub.subscribe(MobDev.PubSub, @log_topic)
      Phoenix.PubSub.subscribe(MobDev.PubSub, @elixir_topic)
      Phoenix.PubSub.subscribe(MobDev.PubSub, @watch_topic)
    end

    devices = MobDev.Server.DevicePoller.get_devices()
    # newest-first list
    all_lines = MobDev.Server.LogBuffer.get()
    elixir_lines = MobDev.Server.ElixirLogBuffer.get()
    lan_url = Application.get_env(:mob_dev, :dashboard_lan_url)

    {qr_small, qr_large} =
      if lan_url do
        encoded = EQRCode.encode(lan_url)
        {EQRCode.svg(encoded, width: 32), EQRCode.svg(encoded, width: 160)}
      else
        {nil, nil}
      end

    watch = WatchWorker.status()

    socket =
      socket
      |> assign(
        devices: devices,
        all_log_lines: all_lines,
        log_filter: :app,
        text_filter: "",
        # serial => :update | :first_deploy
        deploying: %{},
        # serial => [line, ...]
        deploy_output: %{},
        lan_url: lan_url,
        qr_small: qr_small,
        qr_large: qr_large,
        watch_active: watch.watching,
        watch_nodes: watch.nodes,
        watch_last_push: watch.last_push,
        all_elixir_lines: elixir_lines,
        elixir_text_filter: ""
      )
      |> stream(:log_lines, LogFilter.apply(all_lines, :app, "") |> Enum.reverse())
      |> stream(:elixir_lines, Enum.reverse(elixir_lines))

    {:ok, socket}
  end

  # ── PubSub handlers ──────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:devices_updated, devices}, socket) do
    {:noreply, assign(socket, :devices, devices)}
  end

  def handle_info({:log_line, _serial, line}, socket) do
    all_lines = [line | socket.assigns.all_log_lines] |> Enum.take(@log_limit)
    socket = assign(socket, :all_log_lines, all_lines)

    socket =
      if LogFilter.matches?(line, socket.assigns.log_filter, socket.assigns.text_filter) do
        stream_insert(socket, :log_lines, line, at: -1, limit: @log_limit)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:elixir_log_line, line}, socket) do
    all = [line | socket.assigns.all_elixir_lines] |> Enum.take(@elixir_limit)
    socket = assign(socket, :all_elixir_lines, all)

    socket =
      if elixir_matches?(line, socket.assigns.elixir_text_filter) do
        stream_insert(socket, :elixir_lines, line, at: -1, limit: @elixir_limit)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:watch_status, status}, socket) do
    {:noreply, assign(socket, watch_active: status == :watching)}
  end

  def handle_info({:watch_push, info}, socket) do
    {:noreply, assign(socket, watch_nodes: info.nodes, watch_last_push: info)}
  end

  def handle_info({:deploy_line, serial, line}, socket) do
    output = Map.get(socket.assigns.deploy_output, serial, [])

    {:noreply,
     assign(
       socket,
       :deploy_output,
       Map.put(socket.assigns.deploy_output, serial, [line | output])
     )}
  end

  def handle_info({:deploy_done, serial}, socket) do
    deploying = Map.delete(socket.assigns.deploying, serial)
    {:noreply, assign(socket, :deploying, deploying)}
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("deploy", %{"serial" => serial, "mode" => mode}, socket) do
    deploying = Map.put(socket.assigns.deploying, serial, String.to_atom(mode))
    device = Enum.find(socket.assigns.devices, &(&1.serial == serial))

    socket =
      assign(socket,
        deploying: deploying,
        deploy_output: Map.put(socket.assigns.deploy_output, serial, [])
      )

    spawn_deploy(serial, String.to_atom(mode), device.platform, self())
    {:noreply, socket}
  end

  def handle_event("toggle_watch", _, socket) do
    if socket.assigns.watch_active do
      WatchWorker.stop_watching()
    else
      WatchWorker.start_watching()
    end

    {:noreply, socket}
  end

  def handle_event("set_log_filter", %{"filter" => raw_filter}, socket) do
    filter =
      case raw_filter do
        "all" -> :all
        "app" -> :app
        serial -> serial
      end

    filtered =
      LogFilter.apply(socket.assigns.all_log_lines, filter, socket.assigns.text_filter)
      |> Enum.reverse()

    socket =
      socket
      |> assign(:log_filter, filter)
      |> stream(:log_lines, filtered, reset: true)

    {:noreply, socket}
  end

  # phx-change on a <form> sends {name => value} pairs; the input is named "text_filter".
  def handle_event("set_text_filter", %{"text_filter" => text}, socket) do
    filtered =
      LogFilter.apply(socket.assigns.all_log_lines, socket.assigns.log_filter, text)
      |> Enum.reverse()

    socket =
      socket
      |> assign(:text_filter, text)
      |> stream(:log_lines, filtered, reset: true)

    {:noreply, socket}
  end

  def handle_event("clear_text_filter", _, socket) do
    filtered =
      LogFilter.apply(socket.assigns.all_log_lines, socket.assigns.log_filter, "")
      |> Enum.reverse()

    socket =
      socket
      |> assign(:text_filter, "")
      |> stream(:log_lines, filtered, reset: true)

    {:noreply, socket}
  end

  def handle_event("clear_logs", _, socket) do
    MobDev.Server.LogBuffer.clear()

    socket =
      socket
      |> assign(:all_log_lines, [])
      |> stream(:log_lines, [], reset: true)

    {:noreply, socket}
  end

  def handle_event("set_elixir_text_filter", %{"elixir_text_filter" => text}, socket) do
    filtered = apply_elixir_filter(socket.assigns.all_elixir_lines, text)

    socket =
      socket
      |> assign(:elixir_text_filter, text)
      |> stream(:elixir_lines, filtered, reset: true)

    {:noreply, socket}
  end

  def handle_event("clear_elixir_text_filter", _, socket) do
    socket =
      socket
      |> assign(:elixir_text_filter, "")
      |> stream(:elixir_lines, Enum.reverse(socket.assigns.all_elixir_lines), reset: true)

    {:noreply, socket}
  end

  def handle_event("clear_elixir_logs", _, socket) do
    MobDev.Server.ElixirLogBuffer.clear()

    socket =
      socket
      |> assign(:all_elixir_lines, [])
      |> stream(:elixir_lines, [], reset: true)

    {:noreply, socket}
  end

  # ── Deploy task ──────────────────────────────────────────────────────────────

  defp spawn_deploy(serial, mode, platform, lv_pid) do
    mix = System.find_executable("mix") || "mix"
    platform_flag = if platform == :ios, do: "--ios", else: "--android"

    args =
      case mode do
        :first_deploy -> ["mob.deploy", "--native", platform_flag]
        :update -> ["mob.deploy", platform_flag]
      end

    _ = serial

    Task.start(fn ->
      # Stream output line by line via a Port so the UI updates in real time
      port =
        Port.open(
          {:spawn_executable, mix},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args},
            {:line, 2048},
            {:cd, File.cwd!()}
          ]
        )

      stream_port(port, serial, lv_pid)
      send(lv_pid, {:deploy_done, serial})
    end)
  end

  defp stream_port(port, serial, lv_pid) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(lv_pid, {:deploy_line, serial, line})
        stream_port(port, serial, lv_pid)

      {^port, {:exit_status, _}} ->
        :done
    after
      120_000 -> :timeout
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Elixir log filter — matches message or module name; comma separates OR terms
  defp elixir_matches?(_line, ""), do: true

  defp elixir_matches?(line, filter) do
    terms = filter |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    text = [line.message, inspect(line.module)] |> Enum.join(" ") |> String.downcase()
    Enum.any?(terms, &String.contains?(text, String.downcase(&1)))
  end

  defp apply_elixir_filter(lines, filter) do
    lines
    |> Enum.filter(&elixir_matches?(&1, filter))
    |> Enum.reverse()
  end

  defp level_class("E"), do: "log-E"
  defp level_class("W"), do: "log-W"
  defp level_class("I"), do: "log-I"
  defp level_class(_), do: "log-D"

  defp platform_badge(:android), do: {"Android", "bg-green-900 text-green-300"}
  defp platform_badge(:ios), do: {"iOS", "bg-blue-900 text-blue-300"}
  defp platform_badge(_), do: {"?", "bg-zinc-700 text-zinc-300"}

  defp short_serial(serial) do
    if String.contains?(serial, ":"),
      # IP:port — show as-is
      do: serial,
      # USB serial — last 8 chars is enough
      else: String.slice(serial, -8, 8)
  end

  # ── Template ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <%!-- Header --%>
    <header class="flex items-center justify-between px-6 py-3 border-b border-zinc-800 bg-zinc-900 shrink-0">
      <div class="flex items-center gap-3">
        <span class="text-lg font-bold tracking-tight text-white">Mob Dev</span>
        <span class="text-xs text-zinc-500">mob_dev v0.2.2</span>
      </div>
      <div class="flex items-center gap-4">
        <span class="text-xs text-zinc-500"><%= length(@devices) %> device(s) connected</span>

        <%!-- Watch toggle --%>
        <div class="flex items-center gap-2">
          <button
            phx-click="toggle_watch"
            class={"text-xs px-3 py-1 rounded font-medium transition-colors " <>
              if(@watch_active,
                do:   "bg-emerald-700 hover:bg-emerald-600 text-white",
                else: "bg-zinc-700 hover:bg-zinc-600 text-zinc-200")}>
            <%= if @watch_active, do: "⏹ Watching", else: "▶ Watch" %>
          </button>
          <span :if={@watch_active and @watch_nodes != []}
                class="text-xs text-zinc-400">
            <%= length(@watch_nodes) %> node(s)
          </span>
          <span :if={@watch_last_push != nil} class="text-xs text-zinc-500">
            last push: <%= @watch_last_push.pushed %> module(s)
            · <%= Calendar.strftime(@watch_last_push.at, "%H:%M:%S") %>
          </span>
        </div>

        <div :if={@lan_url} class="group relative flex items-center gap-2">
          <%!-- Small QR trigger — always visible in header --%>
          <div class="w-8 h-8 cursor-pointer opacity-60 group-hover:opacity-100 transition-opacity"
               title={"Open on phone: #{@lan_url}"}>
            <%= Phoenix.HTML.raw(@qr_small) %>
          </div>
          <%!-- Large QR popup on hover --%>
          <div class="hidden group-hover:flex flex-col items-center gap-2 absolute top-full right-0 mt-2 p-3 bg-zinc-900 border border-zinc-700 rounded-lg shadow-xl z-50">
            <div class="bg-white p-2 rounded">
              <%= Phoenix.HTML.raw(@qr_large) %>
            </div>
            <span class="text-xs text-zinc-400 font-mono"><%= @lan_url %></span>
          </div>
        </div>
      </div>
    </header>

    <%!-- Device cards --%>
    <section class="px-6 py-4 border-b border-zinc-800 bg-zinc-900 shrink-0">
      <div :if={@devices == []} class="text-zinc-500 text-sm">
        No devices connected. Run <code class="text-zinc-300">adb connect IP:5555</code> or start the iOS simulator.
      </div>
      <div class="flex flex-wrap gap-4">
        <div :for={device <- @devices}
             class="rounded-lg border border-zinc-700 bg-zinc-800 p-4 min-w-56 flex flex-col gap-3">
          <% {badge_label, badge_class} = platform_badge(device.platform) %>
          <% deploying_mode = @deploying[device.serial] %>
          <% is_deploying = deploying_mode != nil %>
          <% deploy_out = Map.get(@deploy_output, device.serial, []) %>

          <%!-- Name + platform badge --%>
          <div class="flex items-center justify-between gap-2">
            <span class="font-mono text-sm text-zinc-200 truncate">
              <%= device.name || short_serial(device.serial) %>
            </span>
            <span class={"text-xs px-2 py-0.5 rounded-full font-medium " <> badge_class}>
              <%= badge_label %>
            </span>
          </div>

          <%!-- Status row --%>
          <div class="flex items-center gap-3 text-xs text-zinc-400">
            <span :if={device.beam_running == true} class="flex items-center gap-1 text-green-400">
              <span class="w-1.5 h-1.5 rounded-full bg-green-400 inline-block"></span> BEAM running
            </span>
            <span :if={device.beam_running == false} class="flex items-center gap-1 text-zinc-500">
              <span class="w-1.5 h-1.5 rounded-full bg-zinc-500 inline-block"></span> BEAM stopped
            </span>
            <span :if={device.battery != nil} class="text-zinc-400">
              🔋 <%= device.battery %>%
            </span>
          </div>

          <%!-- Deploy buttons --%>
          <% platform_flag = if device.platform == :ios, do: "--ios", else: "--android" %>
          <div class="flex gap-2">
            <button
              phx-click="deploy"
              phx-value-serial={device.serial}
              phx-value-mode="update"
              disabled={is_deploying}
              class="flex-1 text-xs px-3 py-1.5 rounded bg-violet-700 hover:bg-violet-600 disabled:opacity-40 disabled:cursor-not-allowed text-white font-medium transition-colors">
              <%= if deploying_mode == :update, do: "Updating…", else: "Update" %>
            </button>
            <button
              phx-click="deploy"
              phx-value-serial={device.serial}
              phx-value-mode="first_deploy"
              disabled={is_deploying}
              class="flex-1 text-xs px-3 py-1.5 rounded bg-zinc-600 hover:bg-zinc-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-medium transition-colors">
              <%= if deploying_mode == :first_deploy, do: "Deploying…", else: "First Deploy" %>
            </button>
          </div>
          <%!-- Terminal equivalents --%>
          <div class="text-zinc-600 text-xs font-mono space-y-0.5">
            <div>update: <span class="text-zinc-500">mix mob.deploy <%= platform_flag %></span></div>
            <div>first deploy: <span class="text-zinc-500">mix mob.deploy --native <%= platform_flag %></span></div>
          </div>

          <%!-- Deploy output (shown while deploying) --%>
          <div :if={is_deploying or deploy_out != []}
               class="font-mono text-xs text-zinc-400 bg-zinc-900 rounded p-2 max-h-32 overflow-y-auto space-y-0.5">
            <div :for={deploy_line <- Enum.reverse(Enum.take(deploy_out, 30))}><%= deploy_line %></div>
          </div>
        </div>
      </div>
    </section>

    <%!-- Log panels — device logs (left) + Elixir server logs (right) --%>
    <section class="flex flex-1 min-h-0 gap-0 px-6 py-3">

      <%!-- Device logs --%>
      <div class="flex flex-col flex-1 min-w-0 min-h-0 pr-3">
        <div class="flex items-center gap-3 mb-2 shrink-0">
          <span class="text-xs font-medium text-zinc-400 uppercase tracking-wider">Device Logs</span>
          <div class="flex gap-1">
            <button
              phx-click="set_log_filter" phx-value-filter="app"
              class={"text-xs px-2 py-0.5 rounded " <> if(@log_filter == :app, do: "bg-violet-700 text-white", else: "text-zinc-400 hover:text-zinc-200")}>
              App
            </button>
            <button
              phx-click="set_log_filter" phx-value-filter="all"
              class={"text-xs px-2 py-0.5 rounded " <> if(@log_filter == :all, do: "bg-violet-700 text-white", else: "text-zinc-400 hover:text-zinc-200")}>
              All
            </button>
            <button :for={device <- @devices}
              phx-click="set_log_filter" phx-value-filter={device.serial}
              class={"text-xs px-2 py-0.5 rounded " <> if(@log_filter == device.serial, do: "bg-violet-700 text-white", else: "text-zinc-400 hover:text-zinc-200")}>
              <%= device.name || short_serial(device.serial) %>
            </button>
          </div>
          <form phx-change="set_text_filter" class="flex items-center gap-1">
            <input
              type="text"
              name="text_filter"
              value={@text_filter}
              placeholder="filter…"
              phx-debounce="200"
              class="text-xs px-2 py-0.5 rounded bg-zinc-800 border border-zinc-700 text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-500 w-40" />
            <button
              :if={@text_filter != ""}
              type="button"
              phx-click="clear_text_filter"
              class="text-xs text-zinc-500 hover:text-zinc-300 px-1">
              ×
            </button>
          </form>
          <button phx-click="clear_logs" class="ml-auto text-xs text-zinc-500 hover:text-zinc-300">
            Clear
          </button>
        </div>

        <div id="log-container"
             class="flex-1 overflow-y-auto bg-zinc-900 rounded-lg border border-zinc-800 p-3 space-y-0.5"
             phx-hook="ScrollBottom">
          <div id="log-lines" phx-update="stream">
            <div :for={{dom_id, line} <- @streams.log_lines} id={dom_id}>
              <%= if Map.get(line, :restart) do %>
                <div class="flex items-center gap-2 my-1 text-xs text-amber-400 select-none">
                  <div class="flex-1 h-px bg-amber-900"></div>
                  <span><%= line.ts %> Restart</span>
                  <div class="flex-1 h-px bg-amber-900"></div>
                </div>
              <% else %>
                <div class={"log-line " <> level_class(line.level) <> if(line.mob, do: " log-mob", else: "")}>
                  <span class="text-zinc-600 select-none"><%= line.ts %> </span>
                  <span :if={line.tag} class="text-zinc-500">[<%= line.tag %>] </span>
                  <%= line.message %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- Draggable divider --%>
      <div id="log-divider"
           phx-hook="ResizableDivider"
           class="relative flex items-center justify-center w-3 shrink-0 cursor-col-resize select-none group">
        <div class="w-px h-full bg-zinc-800 group-hover:bg-violet-700 transition-colors"></div>
        <div class="absolute flex flex-col gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none">
          <div class="w-1 h-1 rounded-full bg-violet-500"></div>
          <div class="w-1 h-1 rounded-full bg-violet-500"></div>
          <div class="w-1 h-1 rounded-full bg-violet-500"></div>
        </div>
      </div>

      <%!-- Elixir / IEx logs --%>
      <div class="flex flex-col w-96 shrink-0 min-h-0 pl-3">
        <div class="flex items-center gap-2 mb-2 shrink-0 flex-wrap">
          <span class="text-xs font-medium text-zinc-400 uppercase tracking-wider">Elixir</span>
          <form phx-change="set_elixir_text_filter" class="flex items-center gap-1">
            <input
              type="text"
              name="elixir_text_filter"
              value={@elixir_text_filter}
              placeholder="filter… (comma for multiple)"
              phx-debounce="200"
              class="text-xs px-2 py-0.5 rounded bg-zinc-800 border border-zinc-700 text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-500 w-44" />
            <button
              :if={@elixir_text_filter != ""}
              type="button"
              phx-click="clear_elixir_text_filter"
              class="text-xs text-zinc-500 hover:text-zinc-300 px-1">
              ×
            </button>
          </form>
          <button phx-click="clear_elixir_logs" class="ml-auto text-xs text-zinc-500 hover:text-zinc-300">
            Clear
          </button>
        </div>

        <div id="elixir-log-container"
             class="flex-1 overflow-y-auto bg-zinc-900 rounded-lg border border-zinc-800 p-3 space-y-0.5"
             phx-hook="ScrollBottom">
          <div id="elixir-lines" phx-update="stream">
            <div :for={{dom_id, line} <- @streams.elixir_lines} id={dom_id}>
              <div class={"log-line " <> level_class(line.level)}>
                <span class="text-zinc-600 select-none"><%= line.ts %> </span>
                <span :if={line.module} class="text-zinc-500">
                  [<%= inspect(line.module) %>]
                </span>
                <%= line.message %>
              </div>
            </div>
          </div>
        </div>
      </div>

    </section>
    """
  end
end
