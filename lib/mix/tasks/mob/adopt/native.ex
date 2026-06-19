defmodule Mix.Tasks.Mob.Adopt.Native do
  @shortdoc "Installs the native (Android + iOS) build trees"

  @moduledoc """
  Dispatcher — composes `mob.adopt.native.android` and
  `mob.adopt.native.ios`.

  ## Options

  - `--no-android` — skip the Android tree.
  - `--no-ios` — skip the iOS tree.
  - `--local` — forwarded to the platform sub-installers for path-dep
    resolution.
  - `--python` — iOS-only: pre-configure embedded CPython via Pythonx
    (forwarded to `mob.adopt.native.ios`).

  Other orchestrator flags accepted but inert.

  Both platforms emit by default. Useful as a standalone task for
  "refresh the native trees after a template fix" workflows.
  """
  use Igniter.Mix.Task

  alias Mix.Tasks.Mob.Adopt.Native.{Android, Ios}

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
      example: "mix mob.adopt.native",
      schema: @common_schema,
      defaults: @common_defaults,
      composes: ["mob.adopt.native.android", "mob.adopt.native.ios"]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options

    igniter
    |> maybe_compose(Android, Keyword.get(opts, :android, true))
    |> maybe_compose(Ios, Keyword.get(opts, :ios, true))
  end

  defp maybe_compose(igniter, _module, false), do: igniter

  defp maybe_compose(igniter, module, true),
    do: Igniter.compose_task(igniter, module, igniter.args.argv)
end
