defmodule Mix.Tasks.Mob.Adopt.MobExs do
  @shortdoc "Generates mob.exs and gitignores mob.local.exs"

  @moduledoc """
  Writes `mob.exs` — project config you commit (plugin activation, trust,
  styles, and portable `mob_dir` / `elixir_lib` defaults) — and ensures
  `.gitignore` ignores `mob.local.exs`, the machine-local override file
  `mob.exs` imports last.

  ## Options

  - `--local` — also write `mob.local.exs` pointing `mob_dir` at the local
    checkout from `MOB_DIR` (or a sibling-directory fallback). The absolute
    path never lands in `mob.exs`, which uses `Path.join(File.cwd!(),
    "deps/mob")` and reads `MOB_ELIXIR_LIB` / `:code.lib_dir(:elixir)` at
    runtime.

  Other orchestrator flags accepted but inert.

  ## Idempotency

  - An existing `mob.exs` is not rewritten; it only gains the
    `mob.local.exs` import line if it lacks one.
  - `mob.local.exs` is created with `on_exists: :skip`.
  - `.gitignore` patch checks for `mob.local.exs` before appending.

  Typically called by `mix mob.adopt`, not directly.
  """
  use Igniter.Mix.Task

  alias MobDev.Adopt.{Generator, Patcher}
  alias MobDev.{AdoptGuard, MobExs}

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
      example: "mix mob.adopt.mob_exs",
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
      generate(igniter, opts)
    end
  end

  defp generate(igniter, opts) do
    {_mob_dep, _mob_dev_dep, mob_local_dir} =
      Generator.resolve_deps(local: opts[:local] || false)

    igniter
    |> Igniter.create_or_update_file("mob.exs", Patcher.mob_exs_content(), fn source ->
      Rewrite.Source.update(source, :content, &MobExs.ensure_local_import/1)
    end)
    |> maybe_write_local(mob_local_dir)
    |> patch_gitignore()
  end

  defp maybe_write_local(igniter, nil), do: igniter

  defp maybe_write_local(igniter, mob_dir) do
    Igniter.create_new_file(igniter, "mob.local.exs", MobExs.local_content(mob_dir: mob_dir),
      on_exists: :skip
    )
  end

  defp patch_gitignore(igniter) do
    Igniter.create_or_update_file(
      igniter,
      ".gitignore",
      MobExs.ensure_gitignored(""),
      fn source ->
        Rewrite.Source.update(source, :content, &MobExs.ensure_gitignored/1)
      end
    )
  end
end
