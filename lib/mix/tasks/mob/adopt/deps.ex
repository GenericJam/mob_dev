defmodule Mix.Tasks.Mob.Adopt.Deps do
  @shortdoc "Adds :mob and :mob_dev to the project's mix.exs"

  @moduledoc """
  Adds Mob's two deps to the host project's `mix.exs`:

  - `{:mob, "~> 0.7"}` — the framework, used at runtime.
  - `{:mob_dev, "~> 0.6", only: :dev, runtime: false}` — build/deploy
    Mix tasks. Dev-only.

  ## Options

  - `--local` — write `path:` deps instead of Hex version constraints,
    resolved from `MOB_DIR` / `MOB_DEV_DIR` env vars (falling back to
    `./mob` / `../mob`). For Mob framework contributors.

  Other orchestrator flags accepted but inert.

  ## Idempotency

  Patching is done via `MobDev.Adopt.Patcher.inject_deps/3` (the
  same stdlib-AST walk `mix mob.new --liveview` uses), which
  short-circuits if `:mob` is already declared.

  Typically called by `mix mob.adopt`, not directly.
  """
  use Igniter.Mix.Task

  alias MobDev.Adopt.{Generator, Patcher}
  alias MobDev.AdoptGuard

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
      example: "mix mob.adopt.deps",
      schema: @common_schema,
      defaults: @common_defaults
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options

    # Guard call is idempotent — orchestrator runs the same checks but
    # `prepare_for_write` dedupes issues. Defends direct invocation.
    igniter = AdoptGuard.check(igniter, AdoptGuard.mode_from(opts))

    if igniter.issues != [] do
      igniter
    else
      inject(igniter, opts)
    end
  end

  defp inject(igniter, opts) do
    {mob_dep_str, mob_dev_dep_str, _, _} = Generator.resolve_deps(opts)
    live_view? = Keyword.get(opts, :live_view, true)

    # Not `Igniter.Project.Deps.add_dep/3`: 0.8.1 renders 3-tuples with
    # trailing keyword opts as `:k => v` map syntax — invalid Elixir.
    Igniter.update_file(igniter, "mix.exs", fn source ->
      content = Rewrite.Source.get(source, :content)

      patched =
        content
        |> Patcher.inject_deps(mob_dep_str, mob_dev_dep_str)
        |> maybe_inject_ecto_sqlite3(live_view?)

      Rewrite.Source.update(source, :content, patched)
    end)
  end

  # LV mode emits a `mob_app.ex` that calls
  # `Application.ensure_all_started(:ecto_sqlite3)` and runs migrations
  # on-device, so the dep is required. Thin-client mode (`--no-live-view`)
  # doesn't run on-device DB, so we skip.
  defp maybe_inject_ecto_sqlite3(content, true), do: Patcher.inject_ecto_sqlite3(content)
  defp maybe_inject_ecto_sqlite3(content, false), do: content
end
