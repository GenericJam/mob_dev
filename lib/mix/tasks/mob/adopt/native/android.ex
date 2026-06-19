defmodule Mix.Tasks.Mob.Adopt.Native.Android do
  @shortdoc "Generates the android/ native tree from mob_new templates"

  @moduledoc """
  Walks `priv/templates/mob.new/android/**/*.eex` (resolved from mob_new
  — see `MobDev.Adopt.Generator`), renders each with the project's
  assigns, and writes them via `Igniter.create_new_file/4` with
  `on_exists: :skip`. Then copies the binary static tree
  (`priv/static/mob.new/android/**`) via direct `File.copy!/2` since
  Igniter's `Rewrite` engine assumes UTF-8 text and would corrupt the
  Gradle wrapper jar and PNG icons.

  Idempotent — `on_exists: :skip` for EEx-rendered files; `File.exists?`
  pre-check for binaries.

  The `gradlew` script is `chmod 0o755` after copy so it's executable.
  """
  use Igniter.Mix.Task

  alias Igniter.Project.Application, as: ProjectApplication
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
      example: "mix mob.adopt.native.android",
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
    |> emit_templates(assigns, opts, "android")
    |> copy_static_binaries(opts, "android")
  end

  @doc false
  @spec emit_templates(Igniter.t(), map(), keyword(), String.t()) :: Igniter.t()
  def emit_templates(igniter, assigns, opts, platform) do
    t_root = Generator.templates_root(opts)

    t_root
    |> Path.join("#{platform}/**/*.eex")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(igniter, fn template_path, ig ->
      rel = Path.relative_to(template_path, t_root)
      dest_rel = Generator.expand_path(rel, assigns)
      content = EEx.eval_file(template_path, Map.to_list(assigns))
      Igniter.create_new_file(ig, dest_rel, content, on_exists: :skip)
    end)
  end

  @doc false
  @spec copy_static_binaries(Igniter.t(), keyword(), String.t()) :: Igniter.t()
  def copy_static_binaries(igniter, opts, platform) do
    s_root = Generator.static_root(opts)

    s_root
    |> Path.join("#{platform}/**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.reduce(igniter, &copy_one_binary(&1, &2, s_root))
  end

  defp copy_one_binary(src, igniter, s_root) do
    rel = Path.relative_to(src, s_root)
    if File.exists?(rel), do: igniter, else: do_copy_binary(src, rel, igniter)
  end

  defp do_copy_binary(src, rel, igniter) do
    File.mkdir_p!(Path.dirname(rel))
    File.copy!(src, rel)
    if rel == "android/gradlew", do: File.chmod!(rel, 0o755)
    Igniter.add_notice(igniter, "* copied binary: #{rel}")
  end
end
