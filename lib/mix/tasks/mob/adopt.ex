defmodule Mix.Tasks.Mob.Adopt do
  @shortdoc "Installs Mob into an existing Phoenix project"

  @moduledoc """
  Adds Mob (mobile framework) to an existing Phoenix-based Elixir project.

  ## ⚠ Experimental (pre-1.0)

  `mix mob.adopt` is experimental. On anything outside the supported
  shapes the task refuses with a clear message rather than risk
  breaking your app. The supported surface will widen as we stabilise.

  ### Supported (default — LV bridge)

  - Single (non-umbrella) Phoenix project.
  - Stock `assets/js/app.js` (contains `new LiveSocket(...)`).
  - Stock root layout (`lib/<app>_web/components/layouts/root.html.heex`
    or the legacy `templates/layout/root.html.heex`) with a `<body>`
    tag.
  - **Ecto Repo uses the SQLite adapter** (`:ecto_sqlite3` in deps).
    The generated `mob_app.ex` migrates `<App>.Repo` on-device; the
    SQLite assumption is hard-coded. A `mix phx.new --database sqlite3`
    project matches.

  ### Supported (`--no-live-view` — thin-client)

  Same Phoenix-shape requirements but **no Ecto/Repo constraint** —
  the phone opens a deployed Phoenix server via WebView and runs no DB
  on-device. Works against Postgres / MySQL / `--no-ecto` hosts.

  ### Refused (loud, with guidance)

  - Umbrella applications.
  - Non-Phoenix projects (no `:phoenix` dep).
  - Heavily customised `app.js` (no recognisable `new LiveSocket(`).
  - Heavily customised root layout (no recognisable `<body>` tag, or
    no layout file at all).
  - **LV mode** + host Repo uses Postgres / MySQL / MSSQL (or no Repo
    at all). Use `--no-live-view` instead, or wait for the future
    `--with-local-repo` mode that handles non-SQLite hosts via a
    separate on-device LocalRepo.

  Composable, [Igniter](https://hex.pm/packages/igniter)-based — mirrors
  the architecture of [team-alembic/phx_install](https://github.com/team-alembic/phx_install).
  This is the install-into-existing counterpart to `mix mob.new`, which
  generates a project from scratch. `mix mob.new` is unaffected by this task.

  ## Usage

      mix mob.adopt [OPTIONS]

  Run from inside an existing Mix project. The target project must
  declare `{:igniter, "~> 0.7", only: [:dev, :test]}` in its mix.exs
  (most modern Phoenix-ecosystem projects already do).

  The native trees (`--android` / `--ios`, on by default) render from
  mob_new's templates, so they also require the **mob_new archive
  installed**:

      mix archive.install hex mob_new

  mob_new stays the single source of native templates (no duplication
  across repos). The Elixir-side adoption (deps, LiveView bridge,
  `mob.exs`, `MobScreen`) needs no archive — only `--android`/`--ios` do.

  ## Options

  - `--no-ios` — skip the iOS native tree
  - `--no-android` — skip the Android native tree
  - `--local` — `path:` deps for `:mob`/`:mob_dev`; pre-fill `mob.exs`
    paths from `MOB_DIR` / `MOB_DEV_DIR`. For Mob framework contributors.
  - `--python` — iOS-only: pre-configure embedded CPython via Pythonx
  - `--host-url URL` — write `config :mob, host_url: URL` so the
    generated `MobScreen` opens `URL` instead of the default
    `http://127.0.0.1:4000/`. Use for thin-client deployments where
    the WebView points at a deployed Phoenix server (fly.io etc.).
  - `--no-live-view` — skip the LiveView bridge patches
    (`assets/js/app.js` MobHook, `root.html.heex` bridge div) AND
    generate a thin-client `mob_app.ex` that does NOT boot Phoenix
    on-device. For Hologram-only or non-Phoenix hosts where the
    BEAM-on-device is just the native interop layer.

  Both platforms emit by default. Passing both `--no-ios` and
  `--no-android` raises.

  ## What gets installed

  - `:mob` + `:mob_dev` deps in `mix.exs`
  - `lib/<app>/mob_screen.ex` — `Mob.Screen` opening a WebView at
    `Application.get_env(:mob, :host_url)` (default localhost)
  - `mob.exs` — build-environment config
  - `.gitignore` updated to ignore `mob.exs`
  - `android/` and/or `ios/` native trees (gated by platform flags)
  - `lib/<app>/mob_app.ex` + `src/<app>.erl` for on-device BEAM entry
  - `erlc_paths`/`erlc_options` added to `mix.exs`

  Default (no `--no-live-view`):
  - `MobHook` injected into `assets/js/app.js`
  - bridge `<div>` injected into `root.html.heex`
  - `mob_app.ex` boots the host Phoenix endpoint on-device

  With `--no-live-view`:
  - LiveView bridge patches skipped
  - `mob_app.ex` is the thin-client variant (`use Mob.App` shell,
    no `Application.ensure_all_started`)

  ## Composability

  Every sub-installer is invokable independently:

      mix mob.adopt.deps          # just bump mix.exs
      mix mob.adopt.bridge        # just patch app.js + root.html.heex
      mix mob.adopt.screen        # just generate mob_screen.ex
      mix mob.adopt.mob_app       # just generate mob_app.ex + .erl bootstrap
      mix mob.adopt.mob_exs       # just write mob.exs + .gitignore
      mix mob.adopt.native        # both native trees
      mix mob.adopt.native.android
      mix mob.adopt.native.ios
      mix mob.adopt.finalize      # post-install notice (no file changes)

  Each accepts the same flags as `mob.adopt` and respects them
  individually. Run `mix help mob.adopt.<sub>` for sub-task docs.

  On-device runtime services (`Mob.ComponentRegistry`,
  `Mob.NativeLogger`, etc.) start imperatively inside
  `<App>.MobApp.start/0` — `Mob.App` is the *behaviour* the device
  entry uses (via `use Mob.App`), never a supervision-tree child.

  The native trees come from mob_new's `priv/templates/mob.new/`; the
  Elixir-source content (`mob_screen.ex`, `mob_app.ex`, the LV bridge
  patches) from `MobDev.Adopt.Patcher` / `MobDev.Adopt.Generator`, both
  duplicated from mob_new pending the Phase-5 Igniter reunification.
  """
  use Igniter.Mix.Task

  alias Mix.Tasks.Mob.Adopt.{Bridge, Deps, Finalize, MobApp, MobExs, Native, Screen}
  alias MobDev.AdoptGuard

  @schema [
    ios: :boolean,
    android: :boolean,
    local: :boolean,
    python: :boolean,
    host_url: :string,
    live_view: :boolean
  ]

  @defaults [ios: true, android: true, live_view: true]

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :mob,
      example: "mix mob.adopt --host-url https://my-app.fly.dev/",
      schema: @schema,
      defaults: @defaults,
      composes: [
        "mob.adopt.deps",
        "mob.adopt.bridge",
        "mob.adopt.screen",
        "mob.adopt.mob_app",
        "mob.adopt.mob_exs",
        "mob.adopt.native",
        "mob.adopt.finalize"
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    validate_platforms!(igniter.args.options)

    igniter = AdoptGuard.check(igniter, AdoptGuard.mode_from(igniter.args.options))

    if igniter.issues == [] do
      compose_pipeline(igniter)
    else
      igniter
    end
  end

  defp compose_pipeline(igniter) do
    argv = igniter.args.argv || []

    igniter
    |> Igniter.compose_task(Deps, argv)
    |> Igniter.compose_task(Bridge, argv)
    |> Igniter.compose_task(Screen, argv)
    |> Igniter.compose_task(MobApp, argv)
    |> Igniter.compose_task(MobExs, argv)
    |> Igniter.compose_task(Native, argv)
    |> Igniter.compose_task(Finalize, argv)
  end

  defp validate_platforms!(opts) do
    if Keyword.get(opts, :ios, true) == false and Keyword.get(opts, :android, true) == false do
      Mix.raise("Cannot pass both --no-ios and --no-android; at least one platform must remain.")
    end
  end
end
