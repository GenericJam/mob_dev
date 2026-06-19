defmodule Mix.Tasks.Mob.Adopt.Screen do
  @shortdoc "Generates the MobScreen (WebView wrapper) module"

  @moduledoc """
  Generates `lib/<app>/mob_screen.ex` — the `Mob.Screen` that opens the
  WebView pointed at the host Phoenix endpoint.

  The generated module reads the URL from application config:

      config :mob, host_url: "https://your-app.example.com/"

  Default if unset is `http://127.0.0.1:4000/`, suitable for on-device
  BEAM hitting a local Phoenix endpoint. The screen module never has
  the URL hardcoded.

  ## Options

  - `--host-url URL` — write `config :mob, host_url: URL` to
    `config/config.exs`. Equivalent to editing config by hand after
    install; provided as a flag so the install pipeline can be fully
    declarative. No-op when not given.

  Other orchestrator flags (`--no-ios`, `--no-android`, `--local`,
  `--python`, `--no-live-view`) are accepted but inert here — declared
  in the schema only so `mix mob.adopt` can forward its full argv
  to this sub-installer without Igniter rejecting unknown options.

  ## Idempotency

  - `lib/<app>/mob_screen.ex` is created with `on_exists: :skip` — if
    it already exists, contents are left alone. To regenerate, delete
    the file first.
  - `--host-url`'s config write goes through `Igniter.Project.Config`,
    which is idempotent: the key is set to the new value, or left as
    is if the same value is already present.

  Typically called by `mix mob.adopt`, not directly.
  """
  use Igniter.Mix.Task

  alias Igniter.Project.Application, as: ProjectApplication
  alias Igniter.Project.Config, as: ProjectConfig
  alias MobDev.Adopt.Patcher
  alias MobDev.AdoptGuard

  # Common schema — every install sub-task accepts the full orchestrator
  # flag set so `mix mob.adopt` can forward its argv unchanged.
  # Sub-tasks ignore options that don't apply to them.
  @common_schema [
    ios: :boolean,
    android: :boolean,
    local: :boolean,
    python: :boolean,
    host_url: :string,
    live_view: :boolean
  ]
  @common_defaults [ios: true, android: true, live_view: true]

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :mob,
      example: "mix mob.adopt.screen --host-url https://my-app.fly.dev/",
      schema: @common_schema,
      defaults: @common_defaults
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    # Guard call is idempotent — orchestrator runs the same checks but
    # `prepare_for_write` dedupes issues. Defends direct invocation.
    igniter = AdoptGuard.check(igniter, AdoptGuard.mode_from(igniter.args.options))

    if igniter.issues != [] do
      igniter
    else
      generate(igniter)
    end
  end

  defp generate(igniter) do
    app_name = ProjectApplication.app_name(igniter) |> to_string()
    module_name = Macro.camelize(app_name)

    igniter
    |> Igniter.create_new_file(
      "lib/#{app_name}/mob_screen.ex",
      Patcher.mob_screen_content_install(module_name),
      on_exists: :skip
    )
    |> maybe_configure_host_url()
  end

  defp maybe_configure_host_url(igniter) do
    case igniter.args.options[:host_url] do
      url when is_binary(url) and url != "" ->
        ProjectConfig.configure(igniter, "config.exs", :mob, [:host_url], url)

      _ ->
        igniter
    end
  end
end
