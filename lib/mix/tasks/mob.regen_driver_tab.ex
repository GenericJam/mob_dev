defmodule Mix.Tasks.Mob.RegenDriverTab do
  use Mix.Task

  alias MobDev.StaticNifs

  @shortdoc "Regenerate priv/generated/driver_tab_*.c from :static_nifs"

  @moduledoc """
  Regenerates the per-app static-NIF table source files in
  `priv/generated/driver_tab_ios.c` and `priv/generated/driver_tab_android.c`.

  These files are linked **before** `libbeam.a` so they override BEAM's empty
  built-in `erts_static_nif_tab[]`. Without them, `load_nif/2` falls back to
  `dlopen`, which is broken on iOS (App Store rejects bundled `.dylibs`) and
  on Android (RTLD_LOCAL hides parent's `enif_*` symbols from children).

      mix mob.regen_driver_tab           # regenerate both platforms
      mix mob.regen_driver_tab --check   # verify on-disk matches manifest, exit non-zero on drift

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

  @ios_path "priv/generated/driver_tab_ios.c"
  @android_path "priv/generated/driver_tab_android.c"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])
    nifs = resolved_nifs()

    case validate_all(nifs) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(":static_nifs invalid — #{msg}")
    end

    ios_src = StaticNifs.generate(:ios, nifs) |> IO.iodata_to_binary()
    android_src = StaticNifs.generate(:android, nifs) |> IO.iodata_to_binary()

    if opts[:check] do
      check_mode(ios_src, android_src)
    else
      write_mode(ios_src, android_src)
    end
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
  def target_paths, do: %{ios: @ios_path, android: @android_path}

  defp validate_all(nifs) do
    Enum.reduce_while(nifs, :ok, fn entry, :ok ->
      case StaticNifs.validate_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "#{inspect(entry)}: #{msg}"}}
      end
    end)
  end

  defp write_mode(ios_src, android_src) do
    File.mkdir_p!(Path.dirname(@ios_path))
    File.mkdir_p!(Path.dirname(@android_path))

    write_if_changed(@ios_path, ios_src)
    write_if_changed(@android_path, android_src)
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

  defp check_mode(ios_src, android_src) do
    drifts =
      [{@ios_path, ios_src}, {@android_path, android_src}]
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
