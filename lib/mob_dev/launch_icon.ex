defmodule MobDev.LaunchIcon do
  @moduledoc """
  The iOS launch screen's icon: the app icon at 96 pt with rounded corners,
  compiled into the app's asset catalog as the image set `MobLaunchIcon`.

  iOS shows the launch screen from the user's tap until the app's first
  frame, before any of the app's code runs. mob_new's `ios/Info.plist` names
  this image in `UILaunchScreen`, so the app's own icon covers process start;
  Mob's boot screen (`MobRootView`) then draws the same image in the same
  place and adds a loading indicator under it while the BEAM starts.

  The image is made at build time from the largest PNG of the plain app icon
  (`AppIcon.appiconset`'s Contents.json entries without `appearances`), so it
  follows `mix mob.icon` and hand-made icons and nothing is stored in the
  project. The rounding is `priv/launch_icon.swift` (CoreGraphics), cached
  under the system temp dir by the source PNG and the script.
  """

  @image_set "MobLaunchIcon"
  @points 96

  @doc """
  Runs `fun` with the asset catalog to compile and returns its result.

  The catalog is a temporary copy of `catalog` with the `MobLaunchIcon` image
  set added, removed once `fun` returns. When the app icon has no PNG or the
  image cannot be made, `fun` gets `catalog` itself and the launch screen
  stays plain, as it was before this image existed: a build never fails over
  the launch icon.
  """
  @spec with_catalog(Path.t(), (Path.t() -> result)) :: result when result: var
  def with_catalog(catalog \\ "ios/Assets.xcassets", fun) do
    tmp = Path.join(System.tmp_dir!(), "mob_assets_#{unique()}")

    try do
      case prepare(catalog, tmp) do
        {:ok, copy} -> fun.(copy)
        :error -> fun.(catalog)
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp prepare(catalog, tmp) do
    with {:ok, source} <- source_icon(catalog),
         {:ok, pngs} <- rounded_pngs(source) do
      copy = Path.join(tmp, Path.basename(catalog))
      File.mkdir_p!(tmp)
      File.cp_r!(catalog, copy)
      write_image_set!(Path.join(copy, "#{@image_set}.imageset"), pngs)
      {:ok, copy}
    end
  rescue
    e in [File.Error, File.CopyError, File.RenameError, Jason.DecodeError] ->
      IO.puts("  ⚠ launch screen icon not added (plain launch screen): #{Exception.message(e)}")
      :error
  end

  # The temp dir's names: the OS pid as well, since System.unique_integer/1
  # restarts low in every VM and two builds can run at once (MOB-313).
  defp unique, do: "#{:os.getpid()}_#{System.unique_integer([:positive])}"

  @doc false
  # Public for testing: the image set's Contents.json for the @2x and @3x
  # PNGs, by file name.
  @spec contents_json([String.t()]) :: String.t()
  def contents_json(filenames) do
    images =
      [%{"idiom" => "universal", "scale" => "1x"}] ++
        for name <- filenames do
          [_, scale] = Regex.run(~r/@(\dx)\.png$/, name)
          %{"filename" => name, "idiom" => "universal", "scale" => scale}
        end

    Jason.encode!(%{"images" => images, "info" => %{"author" => "mob_dev", "version" => 1}})
  end

  # The largest PNG of the plain app icon: Contents.json's entries without
  # `appearances` (not the dark or tinted variants), or every PNG in the set
  # when it has no Contents.json.
  defp source_icon(catalog) do
    set = Path.join(catalog, "AppIcon.appiconset")

    candidates =
      case File.read(Path.join(set, "Contents.json")) do
        {:ok, json} ->
          for %{"filename" => name} = image <- Jason.decode!(json)["images"] || [],
              not Map.has_key?(image, "appearances"),
              do: Path.join(set, name)

        {:error, _} ->
          Path.wildcard(Path.join(set, "*"))
      end

    candidates
    |> Enum.filter(&(String.downcase(Path.extname(&1)) == ".png" and File.regular?(&1)))
    |> Enum.max_by(&File.stat!(&1).size, fn -> nil end)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  # Made once per source icon and script version: into a scratch dir renamed
  # into place, so a build killed mid-write or a concurrent build never leaves
  # half a PNG in the cache.
  defp rounded_pngs(source) do
    script = Application.app_dir(:mob_dev, "priv/launch_icon.swift")

    key =
      :crypto.hash(:sha256, [File.read!(source), File.read!(script), to_string(@points)])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    dir = Path.join(System.tmp_dir!(), "mob_launch_icon_#{key}")
    pngs = for scale <- [2, 3], do: Path.join(dir, "launch_icon@#{scale}x.png")

    if Enum.all?(pngs, &File.exists?/1) do
      {:ok, pngs}
    else
      # An entry missing a PNG (a temp cleaner got to it) is made again.
      File.rm_rf(dir)
      scratch = "#{dir}.#{unique()}"
      File.mkdir_p!(scratch)

      result =
        System.cmd("xcrun", ["swift", script, source, scratch, to_string(@points)],
          stderr_to_stdout: true
        )

      # A concurrent build may have renamed its own copy into place first.
      with {_, 0} <- result, _ <- File.rename(scratch, dir) do
        File.rm_rf(scratch)
        if Enum.all?(pngs, &File.exists?/1), do: {:ok, pngs}, else: :error
      else
        {output, _status} ->
          File.rm_rf(scratch)
          IO.puts("  ⚠ launch screen icon not made (plain launch screen): #{String.trim(output)}")
          :error
      end
    end
  end

  defp write_image_set!(dir, pngs) do
    File.mkdir_p!(dir)
    Enum.each(pngs, &File.cp!(&1, Path.join(dir, Path.basename(&1))))
    File.write!(Path.join(dir, "Contents.json"), contents_json(Enum.map(pngs, &Path.basename/1)))
  end
end
