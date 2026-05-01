defmodule Mix.Tasks.Mob.Publish do
  use Mix.Task

  @shortdoc "Upload a release .ipa to App Store Connect / TestFlight"

  @moduledoc """
  Uploads a release-signed `.ipa` to App Store Connect using `xcrun altool`
  with App Store Connect API key authentication. The build then appears in
  TestFlight after Apple finishes processing (typically 5-15 minutes).

      mix mob.publish                       # uploads _build/mob_release/<App>.ipa
      mix mob.publish path/to/Foo.ipa       # uploads a specific .ipa

  ## Prerequisites

    1. App Store Connect API key (.p8 file). Create one at
       https://appstoreconnect.apple.com/access/api with App Manager role.
    2. The app record exists in App Store Connect (the bundle ID is
       registered there as an app, not just as an App ID in the developer
       portal).
    3. `mob.exs` configured:

           config :mob_dev,
             app_store_connect: [
               key_id:    "ABC123XYZ4",
               issuer_id: "69a6de76-aaaa-bbbb-cccc-1234567890ab",
               key_path:  "~/.appstoreconnect/AuthKey_ABC123XYZ4.p8"
             ]

  ## What it does

  Runs `xcrun altool --upload-app` with API-key auth. altool validates the
  IPA, uploads it, and returns when Apple has accepted the build for
  processing. Apple then takes 5-15 minutes to process the build before it
  appears in TestFlight.
  """

  @switches [verbose: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> Mix.raise("mix mob.publish is only supported on macOS (xcrun altool is required).")
    end

    unless System.find_executable("xcrun") do
      Mix.raise("xcrun not found — install Xcode and run `xcode-select --install`.")
    end

    ipa_path = resolve_ipa_path(args)
    asc = load_asc_config!()

    Mix.shell().info("")
    Mix.shell().info("#{cyan()}=== Uploading to App Store Connect ===#{reset()}")
    Mix.shell().info("  IPA:        #{ipa_path}")
    Mix.shell().info("  Key ID:     #{asc[:key_id]}")
    Mix.shell().info("  Issuer ID:  #{asc[:issuer_id]}")
    Mix.shell().info("  Key path:   #{asc[:key_path]}")
    Mix.shell().info("")
    Mix.shell().info("(altool may take a few minutes — IPA is uploaded then validated by Apple.)")
    Mix.shell().info("")

    install_p8_for_altool!(asc[:key_path], asc[:key_id])

    altool_args = [
      "altool",
      "--upload-app",
      "--type",
      "ios",
      "--file",
      ipa_path,
      "--apiKey",
      asc[:key_id],
      "--apiIssuer",
      asc[:issuer_id]
    ]

    altool_args = if opts[:verbose], do: altool_args ++ ["--verbose"], else: altool_args

    case System.cmd("xcrun", altool_args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} ->
        Mix.shell().info("")
        Mix.shell().info("#{green()}✓ Upload accepted by App Store Connect#{reset()}")
        Mix.shell().info("")
        Mix.shell().info("Apple is processing the build now (~5-15 minutes).")
        Mix.shell().info("Once processed, the build appears in TestFlight at:")
        Mix.shell().info("  #{cyan()}https://appstoreconnect.apple.com/apps#{reset()}")

      {_, rc} ->
        Mix.raise("altool exited #{rc} — see output above.")
    end
  end

  # ── IPA resolution ──────────────────────────────────────────────────────────

  defp resolve_ipa_path([path]) when is_binary(path) do
    abs = Path.expand(path)

    unless File.exists?(abs) do
      Mix.raise("IPA not found at #{abs}")
    end

    abs
  end

  defp resolve_ipa_path([]) do
    output_dir = Path.expand("_build/mob_release")

    case Path.wildcard(Path.join(output_dir, "*.ipa")) do
      [] ->
        Mix.raise("""
        No .ipa found in #{output_dir}.

        Run `mix mob.release` first, or pass an explicit path:

            mix mob.publish path/to/App.ipa
        """)

      [single] ->
        single

      many ->
        Mix.raise("""
        Multiple .ipas found in #{output_dir}; pass one explicitly:

        #{Enum.map_join(many, "\n", &"    #{&1}")}

            mix mob.publish #{List.first(many)}
        """)
    end
  end

  defp resolve_ipa_path(_) do
    Mix.raise("Usage: mix mob.publish [path/to/App.ipa]")
  end

  # ── App Store Connect config ────────────────────────────────────────────────

  defp load_asc_config! do
    config_file = Path.join(File.cwd!(), "mob.exs")

    unless File.exists?(config_file) do
      Mix.raise("mob.exs not found in #{File.cwd!()} — run from the project root.")
    end

    cfg = Config.Reader.read!(config_file) |> Keyword.get(:mob_dev, [])
    asc = cfg[:app_store_connect]

    unless is_list(asc) do
      Mix.raise("""
      Missing :app_store_connect in mob.exs. Add:

          config :mob_dev,
            app_store_connect: [
              key_id:    "ABC123XYZ4",
              issuer_id: "69a6de76-aaaa-bbbb-cccc-1234567890ab",
              key_path:  "~/.appstoreconnect/AuthKey_ABC123XYZ4.p8"
            ]

      Get an API key at https://appstoreconnect.apple.com/access/api
      """)
    end

    Enum.each([:key_id, :issuer_id, :key_path], fn key ->
      unless is_binary(asc[key]) do
        Mix.raise("app_store_connect[:#{key}] missing or not a string in mob.exs")
      end
    end)

    Keyword.update!(asc, :key_path, &Path.expand/1)
  end

  # altool's --apiKey flag looks up the .p8 file in fixed locations:
  #   ./private_keys/AuthKey_<KEY_ID>.p8
  #   ~/private_keys/AuthKey_<KEY_ID>.p8
  #   ~/.private_keys/AuthKey_<KEY_ID>.p8
  #   ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
  # Copy/symlink the user's key into the last of those so altool finds it
  # without us needing to clutter their home dir's ~/private_keys.
  defp install_p8_for_altool!(key_path, key_id) do
    unless File.exists?(key_path) do
      Mix.raise("App Store Connect API key not found at #{key_path}")
    end

    target_dir = Path.expand("~/.appstoreconnect/private_keys")
    File.mkdir_p!(target_dir)
    target = Path.join(target_dir, "AuthKey_#{key_id}.p8")

    if not File.exists?(target) or File.read!(target) != File.read!(key_path) do
      File.cp!(key_path, target)
    end

    :ok
  end

  defp green, do: IO.ANSI.green()
  defp cyan, do: IO.ANSI.cyan()
  defp reset, do: IO.ANSI.reset()
end
