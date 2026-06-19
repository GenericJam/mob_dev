defmodule Mix.Tasks.Mob.Adopt.Bridge do
  @shortdoc "Installs the Mob LiveView bridge (MobHook + bridge div)"

  @moduledoc """
  Patches `assets/js/app.js` and `lib/<web>/components/layouts/root.html.heex`
  to wire `window.mob` through a LiveView `phx-hook`. Output matches
  `mix mob.new --liveview`.

  Mob's native shell injects `window.mob` into every WebView for direct
  JS↔native interop (camera, audio, sensors). The LV bridge patches
  here *replace* that injection on mount with a LiveView-routed shim,
  so `window.mob.send` goes through `pushEvent`/`handle_event` instead
  of straight to native code. Useful when you want server-side BEAM
  visibility into JS messages. Skip this if your project isn't using
  LiveView (e.g. Hologram, vanilla controllers) — the native injection
  alone is what you want.

  ## Options

  - `--no-live-view` — skip the patches entirely with a notice. For
    Hologram-only or non-Phoenix hosts.

  Other orchestrator flags (`--no-ios`, `--no-android`, `--local`,
  `--python`, `--host-url`) are accepted but inert here — declared in
  the schema only so `mix mob.adopt` can forward its full argv
  without Igniter rejecting unknown options.

  ## Refusal (LV mode)

  Refuses (via `Igniter.add_issue/2`) when `assets/js/app.js` is missing
  or doesn't contain a `new LiveSocket(...)` call, or when the
  `root.html.heex` layout is missing or has no `<body>` tag. The pre-1.0
  contract is "blessed shape only" — `--no-live-view` is the escape
  hatch for everything else.

  ## Idempotency

  Both `MobDev.Adopt.Patcher.inject_mob_hook/1` and
  `inject_mob_bridge_element/1` short-circuit when their markers
  (`MobHook` / `mob-bridge`) are already present.

  Typically called by `mix mob.adopt`, not directly.
  """
  use Igniter.Mix.Task

  alias Igniter.Project.Application, as: ProjectApplication
  alias MobDev.Adopt.Patcher
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
      example: "mix mob.adopt.bridge",
      schema: @common_schema,
      defaults: @common_defaults
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    mode = AdoptGuard.mode_from(igniter.args.options)

    # Guard call is idempotent — orchestrator runs the same checks but
    # `prepare_for_write` dedupes issues. Defends direct invocation.
    igniter = AdoptGuard.check(igniter, mode)

    cond do
      igniter.issues != [] ->
        igniter

      mode == :thin ->
        Igniter.add_notice(igniter, """
        `mob.adopt.bridge` skipped (--no-live-view). The native shell
        will inject `window.mob` directly; no LiveView hook needed.
        """)

      true ->
        igniter
        |> patch_app_js()
        |> patch_root_html()
    end
  end

  defp patch_app_js(igniter) do
    Igniter.update_file(igniter, "assets/js/app.js", &update_app_js/1)
  end

  defp update_app_js(source) do
    content = Rewrite.Source.get(source, :content)
    Rewrite.Source.update(source, :content, Patcher.inject_mob_hook(content))
  end

  defp patch_root_html(igniter) do
    web = "#{ProjectApplication.app_name(igniter)}_web"

    candidates = [
      "lib/#{web}/components/layouts/root.html.heex",
      "lib/#{web}/templates/layout/root.html.heex"
    ]

    case Enum.find(candidates, &Igniter.exists?(igniter, &1)) do
      nil -> igniter
      path -> Igniter.update_file(igniter, path, &update_root_html/1)
    end
  end

  defp update_root_html(source) do
    content = Rewrite.Source.get(source, :content)
    Rewrite.Source.update(source, :content, Patcher.inject_mob_bridge_element(content))
  end
end
