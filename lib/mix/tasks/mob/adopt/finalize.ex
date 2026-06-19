defmodule Mix.Tasks.Mob.Adopt.Finalize do
  @shortdoc "Prints next-steps after mob.adopt"

  @moduledoc """
  Emits a post-install notice with the next steps for the user.
  Performs no file changes — purely informational.

  All orchestrator flags accepted but inert. (`--no-live-view` causes a
  slight variation in the notice, mentioning the thin-client setup
  instead of the standard LV bridge flow.)
  """
  use Igniter.Mix.Task

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
      example: "mix mob.adopt.finalize",
      schema: @common_schema,
      defaults: @common_defaults
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    live_view? = Keyword.get(igniter.args.options, :live_view, true)
    host_url = igniter.args.options[:host_url]
    Igniter.add_notice(igniter, notice(live_view?, host_url))
  end

  defp notice(live_view?, host_url) do
    host_line =
      if is_binary(host_url) and host_url != "" do
        "   - WebView URL set to `#{host_url}` via `config :mob, host_url:`.\n"
      else
        "   - WebView URL defaults to `http://127.0.0.1:4000/`. Override with\n" <>
          "     `config :mob, host_url: \"https://your-app.example.com/\"`.\n"
      end

    flavour_line =
      if live_view?,
        do: "   - `mob_app.ex` boots the host Phoenix on-device (LiveView bridge).\n",
        else:
          "   - `mob_app.ex` is the thin-client variant (no on-device Phoenix).\n" <>
            "     Deploy your Phoenix server separately; WebView opens its URL.\n"

    """

    Mob installed.

    #{flavour_line}#{host_line}
    1. Edit mob.exs with your local paths (mob_dir, elixir_lib).
    2. Edit android/local.properties with your Android SDK path.
    3. First-time setup (icon generation, OTP runtime, signing):

           mix mob.install   # mob_dev's first-run task — different from the
                             # `mix mob.adopt` you just ran. Runs once per device.

    4. iOS only — if targeting a physical iPhone:

           mix mob.provision   # register bundle ID + provisioning profile

    5. Deploy to device (first time builds the native APK/iOS app):

           mix mob.deploy --native
    """
  end
end
