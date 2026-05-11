defmodule Mix.Tasks.Mob.RegenDriverTab do
  use Mix.Task

  alias MobDev.StaticNifs

  @shortdoc "Regenerate priv/generated/driver_tab_*.zig from :static_nifs"

  @moduledoc """
  Regenerates the per-app static-NIF table source files in
  `priv/generated/driver_tab_ios.zig` and `priv/generated/driver_tab_android.zig`.

  These files are linked **before** `libbeam.a` so they override BEAM's empty
  built-in `erts_static_nif_tab[]`. Without them, `load_nif/2` falls back to
  `dlopen`, which is broken on iOS (App Store rejects bundled `.dylibs`) and
  on Android (RTLD_LOCAL hides parent's `enif_*` symbols from children).

      mix mob.regen_driver_tab              # regenerate both platforms (default: Zig)
      mix mob.regen_driver_tab --format c   # emit driver_tab_*.c instead (hand-editable C)
      mix mob.regen_driver_tab --check      # verify on-disk matches manifest, exit non-zero on drift

  ## Format

  Zig is the default as of Phase 6a iter 4 — it uses comptime gates
  instead of `#ifdef` for guarded NIFs (e.g. iOS `sqlite3_nif`
  device-only), and Zig's `export` keyword produces the same C-ABI
  symbols libbeam.a expects. `--format c` is still supported for
  anyone who wants a hand-editable C dispatch table. Both formats
  produce equivalent behavior at link time.

  C NIF authors are unaffected by the default: their `c_src/<name>.c`
  files compile via the usual path, and the Zig dispatch table calls
  their `<name>_nif_init()` function through standard C ABI (`extern
  fn <name>_nif_init() callconv(.c)`).

  ## Where the NIF list comes from

  `MobDev.StaticNifs.default_nifs/0` baked-in defaults are merged with any
  `:static_nifs` set in `mob.exs`:

      config :mob_dev,
        static_nifs: [
          %{module: :my_native, archs: [:all]}
        ]

  See `MobDev.StaticNifs` for the entry schema and arch values.

  ## Why a Mix task and not a build-time generator

  The output is committed to the app's repo so reviewers can see what's in
  the static-link surface. It also lets non-Mob build tools (e.g. xcodebuild
  invoked outside `mix mob.deploy`) pick up the file as plain source. The
  task is fast (deterministic file generation) so re-running it on every
  `mix compile` is cheap.

  ## Drift detection

  `mob.doctor` runs `--check` mode and reports any drift between the
  manifest and the on-disk files. CI can do the same.
  """

  @ios_c_path "priv/generated/driver_tab_ios.c"
  @android_c_path "priv/generated/driver_tab_android.c"
  @ios_zig_path "priv/generated/driver_tab_ios.zig"
  @android_zig_path "priv/generated/driver_tab_android.zig"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean, format: :string])
    nifs = resolved_nifs()
    format = parse_format(opts[:format])

    case validate_all(nifs) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(":static_nifs invalid — #{msg}")
    end

    ios_src = StaticNifs.generate(:ios, nifs, format: format) |> IO.iodata_to_binary()
    android_src = StaticNifs.generate(:android, nifs, format: format) |> IO.iodata_to_binary()
    paths = target_paths(format)

    if opts[:check] do
      check_mode(ios_src, android_src, paths)
    else
      write_mode(ios_src, android_src, paths)
    end
  end

  # Default is :zig as of Phase 6a iter 4. Pass `--format c` to opt out
  # (e.g. if you want a hand-editable .c dispatch table). Both formats
  # produce equivalent behavior at link time; the .zig version uses
  # comptime gates instead of `#ifdef` for guarded NIFs.
  defp parse_format(nil), do: :zig
  defp parse_format("zig"), do: :zig
  defp parse_format("c"), do: :c

  defp parse_format(other) do
    Mix.raise("Unknown --format #{inspect(other)}. Supported: zig (default), c.")
  end

  @doc false
  @spec resolved_nifs() :: [StaticNifs.nif_entry()]
  def resolved_nifs do
    # mob.exs isn't auto-imported by Mix.Config — every other task that
    # reads from it goes through Config.Reader.read! directly. Match that
    # pattern here. Application.get_env stays as a secondary source so
    # MIX_CONFIG=... or programmatic Application.put_env still wins for
    # tests that want to bypass the file.
    user =
      MobDev.Config.load_mob_config()
      |> Keyword.get(:static_nifs, Application.get_env(:mob_dev, :static_nifs, []))

    StaticNifs.resolve(user)
  end

  @doc false
  @spec target_paths() :: %{ios: String.t(), android: String.t()}
  def target_paths, do: target_paths(:c)

  @doc false
  @spec target_paths(:c | :zig) :: %{ios: String.t(), android: String.t()}
  def target_paths(:c), do: %{ios: @ios_c_path, android: @android_c_path}
  def target_paths(:zig), do: %{ios: @ios_zig_path, android: @android_zig_path}

  defp validate_all(nifs) do
    Enum.reduce_while(nifs, :ok, fn entry, :ok ->
      case StaticNifs.validate_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "#{inspect(entry)}: #{msg}"}}
      end
    end)
  end

  defp write_mode(ios_src, android_src, %{ios: ios_path, android: android_path}) do
    File.mkdir_p!(Path.dirname(ios_path))
    File.mkdir_p!(Path.dirname(android_path))

    write_if_changed(ios_path, ios_src)
    write_if_changed(android_path, android_src)
  end

  defp write_if_changed(path, new_content) do
    case File.read(path) do
      {:ok, ^new_content} ->
        Mix.shell().info("  ✓ #{path} (unchanged)")

      _ ->
        File.write!(path, new_content)
        Mix.shell().info("  ✓ #{path} (regenerated)")
    end
  end

  defp check_mode(ios_src, android_src, %{ios: ios_path, android: android_path}) do
    drifts =
      [{ios_path, ios_src}, {android_path, android_src}]
      |> Enum.filter(fn {path, expected} ->
        File.read(path) != {:ok, expected}
      end)

    case drifts do
      [] ->
        Mix.shell().info("✓ driver_tab files match :static_nifs")
        :ok

      paths ->
        msg =
          paths
          |> Enum.map(fn {path, _} -> "  - #{path}" end)
          |> Enum.join("\n")

        Mix.raise(
          "driver_tab drift detected — these files don't match :static_nifs:\n#{msg}\n\n" <>
            "Run `mix mob.regen_driver_tab` to fix."
        )
    end
  end
end
