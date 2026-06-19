defmodule Mix.Tasks.Mob.Adopt.Native.Ios do
  @shortdoc "Generates the ios/ native tree from mob_new templates"

  @moduledoc """
  Walks `priv/templates/mob.new/ios/**/*.eex` (resolved from mob_new —
  see `MobDev.Adopt.Generator`), renders each, and writes via
  `Igniter.create_new_file/4` with `on_exists: :skip`. Then copies binary
  static iOS assets via direct `File.copy!/2`.

  Idempotent — `on_exists: :skip` for EEx-rendered files; `File.exists?`
  pre-check for binaries.

  With `--python`, also applies the Pythonx wiring (`{:pythonx, ...}` dep
  in `mix.exs`, generates `lib/<app>/python_paths.ex`). iOS-only — Android
  Python is intentionally out of scope. Mirrors `mix mob.enable pythonx`.
  """
  use Igniter.Mix.Task

  alias Igniter.Project.Application, as: ProjectApplication
  alias Mix.Tasks.Mob.Adopt.Native.Android, as: AndroidInstaller
  alias MobDev.Adopt.Generator

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
      example: "mix mob.adopt.native.ios --python",
      schema: @common_schema,
      defaults: @common_defaults
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    app_name = ProjectApplication.app_name(igniter) |> to_string()
    assigns = Generator.assigns(app_name, opts)

    igniter
    |> AndroidInstaller.emit_templates(assigns, opts, "ios")
    |> AndroidInstaller.copy_static_binaries(opts, "ios")
    |> maybe_apply_python(opts, app_name)
  end

  defp maybe_apply_python(igniter, opts, app_name) do
    if opts[:python] == true do
      # apply_python_patches operates on the filesystem directly (it
      # predates the Igniter install path). Wrap as a side-effect noticed
      # by Igniter so users see it in the output.
      Generator.apply_python_patches(File.cwd!(), app_name)
      Igniter.add_notice(igniter, "* applied Pythonx wiring (mix.exs + python_paths.ex)")
    else
      igniter
    end
  end
end
