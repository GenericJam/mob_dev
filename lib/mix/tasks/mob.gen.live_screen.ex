defmodule Mix.Tasks.Mob.Gen.LiveScreen do
  use Mix.Task

  @shortdoc "Generate a LiveView + Mob.Screen pair"

  @moduledoc """
  Generates a paired `Mob.Screen` and Phoenix `LiveView` for LiveView mode apps.

  ## Usage

      mix mob.gen.live_screen NAME [PATH]

  `NAME` is the LiveView module name (PascalCase). `PATH` is the URL path
  (defaults to `/name` derived from `NAME`).

  ## Examples

      mix mob.gen.live_screen Dashboard
      # → lib/<app>_web/live/dashboard_live.ex  (LiveView)
      # → lib/<app>/screens/dashboard_screen.ex (Mob.Screen)

      mix mob.gen.live_screen Settings /preferences
      # → path override: /preferences

  ## What gets generated

  ### LiveView (`lib/<app>_web/live/<name>_live.ex`)

      defmodule MyAppWeb.DashboardLive do
        use MyAppWeb, :live_view
        use Mob.LiveView

        def mount(_params, _session, socket) do
          {:ok, socket}
        end

        def render(assigns) do
          ~H\"""
          <div>
            <h1>Dashboard</h1>
          </div>
          \"""
        end

        # Receive messages from the native layer:
        #   window.mob.send({ type: "back" })
        def handle_event("mob_message", _data, socket) do
          {:noreply, socket}
        end

        # Push messages to the native layer JS:
        #   push_event(socket, "mob_push", %{type: "haptic"})
      end

  ### Mob.Screen (`lib/<app>/screens/<name>_screen.ex`)

      defmodule MyApp.DashboardScreen do
        use Mob.Screen

        def mount(_params, _session, socket) do
          {:ok, socket}
        end

        def render(_assigns) do
          Mob.UI.webview(
            url: Mob.LiveView.local_url("/dashboard"),
            show_url: false
          )
        end
      end

  ## Router note

  Add the LiveView to your Phoenix router:

      live "/dashboard", DashboardLive

  Then navigate to the screen from Elixir:

      Mob.Socket.navigate(socket, {:push, MyApp.DashboardScreen})
  """

  @impl Mix.Task
  def run(argv) do
    case argv do
      [] ->
        Mix.raise("Usage: mix mob.gen.live_screen NAME [PATH]")

      [name | rest] ->
        path = List.first(rest)
        project_dir = File.cwd!()

        unless File.exists?(Path.join(project_dir, "mix.exs")) do
          Mix.raise("No mix.exs found. Run from your project root.")
        end

        app_name = read_app_name(project_dir)
        generate(project_dir, app_name, name, path)
    end
  end

  # ── Generation ────────────────────────────────────────────────────────────

  defp generate(project_dir, app_name, name, path_override) do
    module_name = Macro.camelize(app_name)
    snake_name = Macro.underscore(name)
    url_path = path_override || "/#{snake_name}"

    live_module = "#{module_name}Web.#{name}Live"
    screen_module = "#{module_name}.#{name}Screen"
    web_module = "#{module_name}Web"

    live_path = Path.join([project_dir, "lib", "#{app_name}_web", "live", "#{snake_name}_live.ex"])
    screen_path = Path.join([project_dir, "lib", app_name, "screens", "#{snake_name}_screen.ex"])

    write_file(live_path, live_view_template(live_module, web_module, name, snake_name))
    write_file(screen_path, screen_template(screen_module, url_path))

    Mix.shell().info("""

    Generated:
      #{live_path}
      #{screen_path}

    Next steps:

      1. Add the route to your Phoenix router (lib/#{app_name}_web/router.ex):

             live "#{url_path}", #{name}Live

      2. Navigate to the screen from Elixir:

             Mob.Socket.navigate(socket, {:push, #{screen_module}})

      3. Send events from JS to Elixir:

             window.mob.send({ type: "action", payload: "hello" })

         Handle them in #{live_module}:

             def handle_event("mob_message", %{"type" => "action"} = data, socket) do
               {:noreply, socket}
             end
    """)
  end

  defp write_file(path, content) do
    if File.exists?(path) do
      Mix.shell().info("  * skip #{path} (already exists)")
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      Mix.shell().info([:green, "  * create ", :reset, path])
    end
  end

  # ── Templates ─────────────────────────────────────────────────────────────

  defp live_view_template(live_module, web_module, name, snake_name) do
    display = name |> String.replace(~r/([A-Z])/, " \\1") |> String.trim()

    """
    defmodule #{live_module} do
      use #{web_module}, :live_view
      use Mob.LiveView

      def mount(_params, _session, socket) do
        {:ok, socket}
      end

      def render(assigns) do
        ~H\"\"\"
        <div class="mob-screen" id="#{snake_name}">
          <h1>#{display}</h1>
        </div>
        \"\"\"
      end

      # Receive messages from the native layer via window.mob.send(data).
      def handle_event("mob_message", _data, socket) do
        {:noreply, socket}
      end

      # Push to native layer: push_event(socket, "mob_push", %{...})
    end
    """
  end

  defp screen_template(screen_module, url_path) do
    """
    defmodule #{screen_module} do
      use Mob.Screen

      def mount(_params, _session, socket) do
        {:ok, socket}
      end

      def render(_assigns) do
        Mob.UI.webview(
          url: Mob.LiveView.local_url("#{url_path}"),
          show_url: false
        )
      end
    end
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp read_app_name(project_dir) do
    MobDev.Enable.read_app_name_from(Path.join(project_dir, "mix.exs"))
  rescue
    e -> Mix.raise(Exception.message(e))
  end
end
