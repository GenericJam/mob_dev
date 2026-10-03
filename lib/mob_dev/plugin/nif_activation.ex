defmodule MobDev.Plugin.NifActivation do
  @moduledoc """
  Warnings for the two ways a plugin's NIF silently misses the installed app
  (MOB-281).

  A plugin's `on_load` tolerates a missing NIF, so neither case fails a build
  or a boot — the first signal is `{:nif_not_loaded, ...}` from the first NIF
  call, with nothing pointing at the cause:

    * **Installed but not activated.** The plugin is in `mix.exs` deps but not
      in `config :mob, :plugins` in `mob.exs`. Activation is the deliberate
      second opt-in step (see [`MOB_PLUGINS.md`](https://github.com/GenericJam/mob/blob/master/MOB_PLUGINS.md)), so the native build compiles
      none of its NIFs. `mix mob.deploy --native` and `mix mob.doctor` name
      every such device-runtime dep (not `only: :dev` / `runtime: false`) that
      declares `nifs:` and print the exact `config` line.

    * **Activated after the last native build.** The plugin is activated, but
      only a BEAM-only `mix mob.deploy` / `mix mob.push` ran since, so the
      installed binary predates it. Every successful native build records, per
      platform, which activated plugins it compiled NIFs for
      (`mob_native_plugins.txt` under `Mix.Project.build_path/0`); a
      BEAM-only deploy or push compares the current activation against that
      record and names the plugins the installed app was built without.

  The checks themselves are advisory: warnings, never errors, and a failure to
  write the record is itself only a warning. (A `mob.exs` that fails to load
  still raises, as every `mob.exs` reader does — MOB-280.) The record describes the last native
  *build* on this machine for this `MIX_ENV`, not what a particular device has
  installed — a device last installed from another checkout or before a
  `mix clean` can still disagree with it. A missing record (a project built
  before this check existed, or a wiped `_build`) is reported separately from
  a known stale build.

  Manifests are read through `MobDev.Plugin.Verify.load_verified/2`, like
  every other build path (MOB-74): a dep whose manifest fails verification is
  never evaluated, so its NIFs are unknown and it is not reported here.
  """

  alias MobDev.Plugin.{Manifest, SignatureGate, Verify}

  @platforms [:android, :ios]
  @record_file "mob_native_plugins.txt"

  @typedoc "`{dep_name, manifest}` — `nil` for a non-plugin dep or an unverifiable manifest."
  @type dep_manifest :: {atom(), map() | nil}

  @typedoc "Per-platform plugin names compiled into the last native build."
  @type build_record :: %{optional(:android | :ios) => [String.t()]}

  @typedoc "One stale-build finding: the plugin, the platform, and why."
  @type drift :: {atom(), :android | :ios, :not_built | :no_record}

  # ── Pure kernels ─────────────────────────────────────────────────────────────

  @doc """
  Device-runtime deps that ship a manifest declaring at least one NIF but are
  not in `activated`. `runtime` is the set of dep names that ship to the device
  (`MobDev.HotPush.runtime_lib_names/0`): an `only: :dev` or `runtime: false`
  dep never reaches the app, so activating it would fix nothing. Tier-0
  plugins (no manifest), manifests without `nifs:`, and activated plugins are
  never flagged. Sorted.
  """
  @spec inactive_nif_plugins([dep_manifest()], [atom()], MapSet.t(String.t())) :: [atom()]
  def inactive_nif_plugins(dep_manifests, activated, runtime) do
    names =
      for {name, manifest} <- dep_manifests,
          name not in activated,
          MapSet.member?(runtime, Atom.to_string(name)),
          nif_platforms(manifest) != [],
          uniq: true,
          do: name

    Enum.sort(names)
  end

  @doc """
  The yellow warning block for `inactive_nif_plugins/3`'s result, or `nil`
  when it is empty. `activated` is the current `config :mob, :plugins` list;
  the printed `config` line is that list plus the inactive plugins, so it can
  replace the existing line verbatim.
  """
  @spec inactive_warning([atom()], [atom()]) :: String.t() | nil
  def inactive_warning([], _activated), do: nil

  def inactive_warning(inactive, activated) do
    lines =
      for p <- inactive do
        "      #{p} is in your deps and ships a NIF, but is not activated — " <>
          "its native code is not built in, so its NIF calls fail with :nif_not_loaded"
      end

    config_line = config_line(activated, inactive)

    IO.ANSI.yellow() <>
      "  ⚠  installed plugins with NIFs are not activated:\n" <>
      Enum.join(lines, "\n") <>
      "\n      To activate, set in mob.exs:  #{config_line}\n" <>
      "      then run `mix mob.deploy --native`." <> IO.ANSI.reset()
  end

  @doc """
  The `config :mob, :plugins, [...]` line that activates `inactive` on top of
  the currently `activated` plugins — the whole list, so it replaces the
  existing line verbatim.
  """
  @spec config_line([atom()], [atom()]) :: String.t()
  def config_line(activated, inactive),
    do: "config :mob, :plugins, #{inspect(Enum.uniq(activated ++ inactive))}"

  @doc """
  For each platform, the activated plugins whose manifest declares a NIF for
  it (a NIF without `:platform` counts for both). Every platform is a key,
  possibly with `[]`. Names are strings, the form the record stores.
  """
  @spec nif_plugins_by_platform([dep_manifest()], [atom()]) :: build_record()
  def nif_plugins_by_platform(dep_manifests, activated) do
    Map.new(@platforms, fn platform ->
      names =
        for {name, manifest} <- dep_manifests,
            name in activated,
            platform in nif_platforms(manifest),
            uniq: true,
            do: Atom.to_string(name)

      {platform, Enum.sort(names)}
    end)
  end

  @doc """
  Plugins activated now (`current`, from `nif_plugins_by_platform/2`) that the
  recorded native build for each of `platforms` lacks. `:not_built` when that
  platform has a record without the plugin; `:no_record` when that platform
  was never recorded. Sorted by plugin, then platform.
  """
  @spec drift(build_record(), build_record(), [:android | :ios]) :: [drift()]
  def drift(current, recorded, platforms) do
    found =
      for platform <- platforms,
          name <- Map.get(current, platform, []),
          reason = drift_reason(recorded, platform, name),
          reason != nil,
          do: {String.to_existing_atom(name), platform, reason}

    Enum.sort(found)
  end

  defp drift_reason(recorded, platform, name) do
    case Map.fetch(recorded, platform) do
      :error -> :no_record
      {:ok, built} -> if name in built, do: nil, else: :not_built
    end
  end

  @doc "The yellow warning block for `drift/3`'s result, or `nil` when empty."
  @spec drift_warning([drift()]) :: String.t() | nil
  def drift_warning([]), do: nil

  def drift_warning(drift) do
    lines = Enum.map(drift, &drift_line/1)

    IO.ANSI.yellow() <>
      "  ⚠  activated plugin NIFs may be missing from the installed app " <>
      "(its NIF calls would fail with :nif_not_loaded):\n" <>
      Enum.join(lines, "\n") <> IO.ANSI.reset()
  end

  defp drift_line({plugin, platform, :not_built}) do
    "      #{plugin} is activated but the installed #{platform} app was built without it " <>
      "— run `mix mob.deploy --native`"
  end

  defp drift_line({plugin, platform, :no_record}) do
    "      #{plugin} is activated but no native #{platform} build has been recorded " <>
      "since mob_dev started tracking it — if the installed app predates activating " <>
      "#{plugin}, run `mix mob.deploy --native`"
  end

  @doc "`record` with `platform`'s entry replaced by `names`; other platforms kept."
  @spec put_record(build_record(), :android | :ios, [String.t()]) :: build_record()
  def put_record(record, platform, names) when platform in @platforms,
    do: Map.put(record, platform, Enum.sort(names))

  @doc """
  Parses the record file's text. One line per platform — the platform name
  followed by the space-separated plugin names; `#` lines are comments.
  Unknown platforms and malformed lines are ignored.
  """
  @spec parse_record(String.t()) :: build_record()
  def parse_record(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line) do
        ["android" | names] -> Map.put(acc, :android, names)
        ["ios" | names] -> Map.put(acc, :ios, names)
        _ -> acc
      end
    end)
  end

  @doc "Renders a record as the text `parse_record/1` reads."
  @spec render_record(build_record()) :: String.t()
  def render_record(record) do
    body =
      for platform <- @platforms, Map.has_key?(record, platform) do
        Enum.join([Atom.to_string(platform) | record[platform]], " ") <> "\n"
      end

    "# NIF plugins compiled into the last native build, per platform (MOB-281).\n" <>
      "# Written by mix mob.deploy --native; read by BEAM-only deploys and mix mob.push.\n" <>
      Enum.join(body)
  end

  @doc """
  The platforms of connected device nodes of the project app `app`, from the
  node names `MobDev.Device.node_name/1` builds: `<app>_android[_<suffix>]@…`
  and `<app>_ios[_<suffix>]@…`. The app prefix is stripped before reading the
  platform, so an app named e.g. `my_ios_app` isn't mistaken for iOS. Nodes of
  other apps are ignored.
  """
  @spec node_platforms([node()], atom() | String.t()) :: [:android | :ios]
  def node_platforms(nodes, app) do
    prefix = "#{app}_"

    found =
      for node <- nodes,
          [name | _] = node |> Atom.to_string() |> String.split("@"),
          String.starts_with?(name, prefix),
          platform <- @platforms,
          platform_tag?(String.replace_prefix(name, prefix, ""), platform),
          do: platform

    Enum.filter(@platforms, &(&1 in found))
  end

  defp platform_tag?(rest, platform) do
    tag = Atom.to_string(platform)
    rest == tag or String.starts_with?(rest, tag <> "_")
  end

  # Same platform rule as the native build (Manifest.nif_for_platform?/2), so the
  # record only claims NIFs the build actually compiled for that platform.
  defp nif_platforms(manifest) when is_map(manifest) do
    nifs = Map.get(manifest, :nifs)
    nifs = if is_list(nifs), do: nifs, else: []

    for nif <- nifs,
        is_map(nif),
        platform <- @platforms,
        Manifest.nif_for_platform?(nif, platform),
        uniq: true,
        do: platform
  end

  defp nif_platforms(_manifest), do: []

  # ── Project I/O ──────────────────────────────────────────────────────────────

  @doc """
  Every dep as `{name, manifest}`, manifests read through
  `Verify.load_verified/2` (honouring `:acknowledge_unsafe_plugins`, like
  `MobDev.Plugin.activated_with_verify/0`). Unverifiable manifests are `nil`.
  """
  @spec dep_manifests() :: [dep_manifest()]
  def dep_manifests do
    acknowledged = SignatureGate.acknowledged_unsafe()

    for {name, dir} <- Mix.Project.deps_paths() do
      opts = if name in acknowledged, do: [acknowledged_unsafe: true], else: []

      case Verify.load_verified(dir, opts) do
        {:ok, manifest} -> {name, manifest}
        {:error, _reason} -> {name, nil}
      end
    end
  end

  @doc "The activated plugin names, non-atom entries dropped."
  @spec activated() :: [atom()]
  def activated, do: Enum.filter(List.wrap(MobDev.Plugin.activated_names()), &is_atom/1)

  @doc "`inactive_nif_plugins/3` for this project, against the activated plugins."
  @spec inactive_nif_plugins([atom()]) :: [atom()]
  def inactive_nif_plugins(activated) do
    inactive_nif_plugins(dep_manifests(), activated, MobDev.HotPush.runtime_lib_names())
  end

  @doc "Where the native-build record lives: under `Mix.Project.build_path/0`."
  @spec record_path() :: Path.t()
  def record_path, do: Path.join(Mix.Project.build_path(), @record_file)

  @doc "Reads the record at `path`; a missing or unreadable file is `%{}`."
  @spec read_record(Path.t()) :: build_record()
  def read_record(path) do
    case File.read(path) do
      {:ok, text} -> parse_record(text)
      {:error, _} -> %{}
    end
  end

  @doc """
  Records that a native build for each of `platforms` just succeeded with the
  currently activated NIF plugins. Other platforms' entries are kept.
  """
  @spec record_native_build([:android | :ios]) :: :ok
  def record_native_build([]), do: :ok

  def record_native_build(platforms) do
    current = nif_plugins_by_platform(dep_manifests(), activated())
    record_native_build(platforms, current, record_path())
  end

  @doc """
  Merges `current`'s entries for `platforms` into the record at `path`. The
  record is advisory: a write failure prints a warning and returns `:ok`
  rather than failing the build that just succeeded.
  """
  @spec record_native_build([:android | :ios], build_record(), Path.t()) :: :ok
  def record_native_build(platforms, current, path) do
    record =
      Enum.reduce(platforms, read_record(path), fn platform, acc ->
        put_record(acc, platform, Map.get(current, platform, []))
      end)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, render_record(record)) do
      :ok
    else
      {:error, reason} ->
        IO.puts(
          IO.ANSI.yellow() <>
            "  ⚠  could not record the native build's plugins at #{path}: " <>
            "#{:file.format_error(reason)} — BEAM-only deploys can't tell if " <>
            "a plugin NIF is missing" <> IO.ANSI.reset()
        )
    end
  end

  @doc "Prints `inactive_warning/2` for this project, if any."
  @spec warn_inactive() :: :ok
  def warn_inactive do
    activated = activated()

    case activated |> inactive_nif_plugins() |> inactive_warning(activated) do
      nil -> :ok
      msg -> IO.puts(msg)
    end
  end

  @doc """
  Prints `drift_warning/1` for a BEAM-only deploy or push to `platforms`,
  if any.
  """
  @spec warn_stale_build([:android | :ios]) :: :ok
  def warn_stale_build(platforms) do
    current = nif_plugins_by_platform(dep_manifests(), activated())

    case current |> drift(read_record(record_path()), platforms) |> drift_warning() do
      nil -> :ok
      msg -> IO.puts(msg)
    end
  end
end
