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

  @doc """
  Default reverse-DNS prefix when no platform manifest is available.
  Honors `MOB_BUNDLE_PREFIX` so users with a corporate prefix can set
  it once. Mirrors `MobNew.ProjectGenerator.bundle_prefix/0` so the
  generator's default and the runtime fallback agree.

  Also used by `mix mob.uninstall --all-apps` to compute the prefix
  match (e.g. uninstall every `com.example.*` package on a device).
  """
  @spec bundle_prefix() :: String.t()
  def bundle_prefix do
    case System.get_env("MOB_BUNDLE_PREFIX") do
      nil -> "com.example"
      "" -> "com.example"
      raw -> String.trim(raw)
    end
  end

  # The platforms a project develops for. `:android` and `:ios` are the only
  # valid entries; order is irrelevant.
  @all_platforms [:android, :ios]

  @doc """
  Platforms this project targets, read from `mob.exs`
  (`config :mob_dev, platforms: [:ios]`).

  Defaults to both platforms when unset. The chief use is letting a Mac-only
  iOS developer opt out of Android discovery/tunnelling once, instead of
  passing `--ios-only` on every command. A `--ios-only` / `--android-only`
  flag overrides this at the call site.
  """
  @spec platforms() :: [:android | :ios]
  def platforms, do: parse_platforms(load_mob_config()[:platforms])

  @doc """
  Normalises a raw `:platforms` config value to a valid platform list.

  `nil` (unset) yields both platforms. A list is filtered to the known
  platforms (`:android`, `:ios`); unknown or malformed entries are dropped.
  If nothing valid remains, falls back to both platforms rather than leaving
  the caller with no devices to discover. Pure — exposed for testing.
  """
  @spec parse_platforms(term()) :: [:android | :ios]
  def parse_platforms(nil), do: @all_platforms

  def parse_platforms(value) when is_list(value) do
    case Enum.filter(@all_platforms, &(&1 in value)) do
      [] -> @all_platforms
      valid -> valid
    end
  end

  def parse_platforms(_other), do: @all_platforms

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
           Regex.run(
             Regex.compile!("<key>CFBundleIdentifier</key>\\s*<string>([^<]+)</string>"),
             content
           ) do
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
           Regex.run(Regex.compile!("applicationId\\s+[\"']([^\"']+)[\"']"), content) ||
             Regex.run(Regex.compile!("applicationId\\s*=\\s*[\"']([^\"']+)[\"']"), content) do
      Enum.at(match, 1)
    else
      _ -> nil
    end
  end

  defp app_name, do: Mix.Project.config()[:app] |> to_string()
end
