defmodule MobDev.Config do
  @moduledoc false

  # Shared config helpers used across deployer, connector, native_build, and
  # battery bench tasks.

  @doc """
  Returns the app's bundle ID / Android package name.

  Resolution order:
    1. `mob.exs` — `config :mob_dev, bundle_id: "..."`
    2. `ios/Info.plist` — `CFBundleIdentifier`
    3. `android/app/build.gradle` — `applicationId`
    4. Generated default: `"com.mob.<app_name>"`
  """
  @spec bundle_id() :: String.t()
  def bundle_id do
    load_mob_config()[:bundle_id] ||
      detect_from_ios_plist() ||
      detect_from_android_gradle() ||
      "com.mob.#{app_name()}"
  end

  @doc """
  Reads the `mob_dev` section from `mob.exs` in the current directory.
  Returns an empty keyword list if the file does not exist.
  """
  @spec load_mob_config() :: keyword()
  def load_mob_config do
    config_file = Path.join(File.cwd!(), "mob.exs")

    if File.exists?(config_file),
      do: Config.Reader.read!(config_file) |> Keyword.get(:mob_dev, []),
      else: []
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp detect_from_ios_plist do
    plist = Path.join([File.cwd!(), "ios", "Info.plist"])

    with true <- File.exists?(plist),
         {:ok, content} <- File.read(plist),
         [_, id] <-
           Regex.run(~r/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/, content) do
      id
    else
      _ -> nil
    end
  end

  defp detect_from_android_gradle do
    gradle = Path.join([File.cwd!(), "android", "app", "build.gradle"])

    with true <- File.exists?(gradle),
         {:ok, content} <- File.read(gradle),
         match when match != nil <-
           Regex.run(~r/applicationId\s+["']([^"']+)["']/, content) ||
             Regex.run(~r/applicationId\s*=\s*["']([^"']+)["']/, content) do
      Enum.at(match, 1)
    else
      _ -> nil
    end
  end

  defp app_name, do: Mix.Project.config()[:app] |> to_string()
end
