defmodule Mix.Tasks.Mob.Adopt.MobApp do
  @shortdoc "Generates lib/<app>/mob_app.ex + src/<app>.erl (on-device BEAM entry)"

  @moduledoc """
  Generates the on-device BEAM entry point invoked by Mob's native
  shell at app launch:

  - `lib/<app>/mob_app.ex` — the entry module
  - `src/<app>.erl` — Erlang bootstrap that calls
    `<App>.MobApp.start/0`
  - `mix.exs` patches: `erlc_paths: ["src"]` + `erlc_options: [:debug_info]`
    so the Erlang bootstrap gets compiled

  Two flavours of `mob_app.ex`:

  - **LiveView** (default) — calls
    `Application.ensure_all_started(:<app>)` which boots the host
    Phoenix endpoint, runs Ecto migrations, sets up the on-device
    runtime config. `secret_key_base` is read from
    `config/dev.exs` if available (so it matches the host dev
    server) or freshly generated.
  - **Thin client** (with `--no-live-view`) — uses `use Mob.App` with
    `navigation/1` + `on_start/0` callbacks. Does NOT boot Phoenix
    on-device; the WebView points at a deployed Phoenix server (set
    `config :mob, host_url: ...`). The device's BEAM is just the
    native interop layer.

  ## Options

  - `--no-live-view` — generate the thin-client `mob_app.ex` instead
    of the LiveView-flavoured one. Pairs with the `bridge` sub-task
    being skipped under the same flag.

  Other orchestrator flags accepted but inert.

  ## Idempotency

  - Files are created with `on_exists: :skip`. Re-running won't
    overwrite — delete first if you want to switch between LV and
    thin flavours.
  - `erlc_paths` / `erlc_options` injection checks string presence in
    `mix.exs` before patching.

  Typically called by `mix mob.adopt`, not directly.
  """
  use Igniter.Mix.Task

  alias Igniter.Project.Application, as: ProjectApplication
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
      example: "mix mob.adopt.mob_app",
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
    live_view? = Keyword.get(igniter.args.options, :live_view, true)

    mob_app_content = build_mob_app_content(live_view?, module_name, app_name)
    erl_content = Patcher.erlang_entry_content(module_name, app_name)

    igniter
    |> Igniter.create_new_file("lib/#{app_name}/mob_app.ex", mob_app_content, on_exists: :skip)
    |> Igniter.create_new_file("src/#{app_name}.erl", erl_content, on_exists: :skip)
    |> patch_erlc_paths()
  end

  defp build_mob_app_content(true = _live_view, module_name, app_name) do
    secret_key_base =
      Generator.extract_secret_key_base(File.cwd!()) ||
        Generator.generate_secret_key_base()

    signing_salt = Generator.generate_signing_salt()

    Patcher.mob_live_app_content(module_name, app_name, secret_key_base, signing_salt)
  end

  defp build_mob_app_content(false = _live_view, module_name, app_name) do
    Patcher.mob_app_content_thin(module_name, app_name)
  end

  # Adds erlc_paths: ["src"] and erlc_options: [:debug_info] to the host
  # mix.exs def project. Text-based for resilience — keyword-list AST
  # manipulation inside `def project do [...]` is fragile across Phoenix
  # versions. Idempotent via String.contains? checks.
  defp patch_erlc_paths(igniter) do
    Igniter.update_file(igniter, "mix.exs", fn source ->
      content = Rewrite.Source.get(source, :content)
      Rewrite.Source.update(source, :content, inject_erlc(content))
    end)
  end

  @doc false
  @spec inject_erlc(String.t()) :: String.t()
  def inject_erlc(content) do
    content
    |> maybe_inject_key("erlc_paths", ~s(erlc_paths: ["src"],))
    |> maybe_inject_key("erlc_options", ~s(erlc_options: [:debug_info],))
  end

  defp maybe_inject_key(content, key, snippet) do
    if String.contains?(content, key) do
      content
    else
      Regex.replace(
        Regex.compile!("(def project do\\s*\\[)"),
        content,
        "\\1\n      #{snippet}",
        global: false
      )
    end
  end
end
