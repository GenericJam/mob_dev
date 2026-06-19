defmodule Mix.Tasks.Mob.Adopt.MobExs do
  @shortdoc "Generates mob.exs and adds it to .gitignore"

  @moduledoc """
  Writes `mob.exs` (build-environment config: `mob_dir`, `elixir_lib`)
  and ensures `.gitignore` ignores it.

  ## Options

  - `--local` — pre-fill `mob_dir` and `elixir_lib` from `MOB_DIR` /
    `MOB_DEV_DIR` env vars (or sibling-directory fallbacks). Without
    `--local` the file uses `Path.join(File.cwd!(), "deps/mob")` and
    reads `MOB_ELIXIR_LIB` / `:code.lib_dir(:elixir)` at runtime.

  Other orchestrator flags accepted but inert.

  ## Idempotency

  - `mob.exs` is created with `on_exists: :skip` — re-running won't
    overwrite an edited mob.exs.
  - `.gitignore` patch checks for `mob.exs` before appending.

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
    {_mob_dep, _mob_dev_dep, mob_dir_expr, elixir_lib_expr} =
      Generator.resolve_deps(local: opts[:local] || false)

    mob_exs_content = Patcher.mob_exs_content(mob_dir_expr, elixir_lib_expr)

    igniter
    |> Igniter.create_new_file("mob.exs", mob_exs_content, on_exists: :skip)
    |> patch_gitignore()
  end

  defp patch_gitignore(igniter) do
    if Igniter.exists?(igniter, ".gitignore") do
      Igniter.update_file(igniter, ".gitignore", &append_mob_exs/1)
    else
      Igniter.create_new_file(igniter, ".gitignore", "# Mob local config\nmob.exs\n",
        on_exists: :skip
      )
    end
  end

  defp append_mob_exs(source) do
    content = Rewrite.Source.get(source, :content)

    if mob_exs_ignored?(content) do
      source
    else
      Rewrite.Source.update(source, :content, content <> "\n# Mob local config\nmob.exs\n")
    end
  end

  defp mob_exs_ignored?(content) do
    String.contains?(content, "\nmob.exs") or String.starts_with?(content, "mob.exs")
  end
end
