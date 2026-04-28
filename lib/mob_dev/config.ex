defmodule MobDev.Config do
  @moduledoc false

  # Shared config helpers used across deployer, connector, native_build, and
  # battery bench tasks.

  @doc """
  Returns the app's bundle ID / Android package name.

  Resolution order:
    1. `mob.exs` — `config :mob_dev, bundle_id: "..."` (opt-in override;
       not required — projects work fine without it)
    2. `ios/Info.plist` — `CFBundleIdentifier`
    3. `android/app/build.gradle` — `applicationId`
    4. Generated default: `"<MOB_BUNDLE_PREFIX or com.example>.<app_name>"`

  The four-level fallback exists so cross-platform tasks (e.g. `mix mob.deploy`)
  always have a value to work with, regardless of which platform's manifest is
  authoritative for the project. For most users, the value resolved at step 2
  or 3 is what `mix mob.new` wrote there at generation time; mob.exs is
  reserved for explicit overrides.
  """
  @spec bundle_id() :: String.t()
  def bundle_id do
    load_mob_config()[:bundle_id] ||
      detect_from_ios_plist() ||
      detect_from_android_gradle() ||
      "#{bundle_prefix()}.#{app_name()}"
  end

  # Default reverse-DNS prefix when no platform manifest is available. Honors
  # MOB_BUNDLE_PREFIX so users with a corporate prefix can set it once.
  # Mirrors MobNew.ProjectGenerator.bundle_prefix/0 so the generator's default
  # and the runtime fallback agree.
  defp bundle_prefix do
    case System.get_env("MOB_BUNDLE_PREFIX") do
      nil -> "com.example"
      "" -> "com.example"
      raw -> String.trim(raw)
    end
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
