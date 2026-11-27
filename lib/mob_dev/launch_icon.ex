defmodule MobDev.LaunchIcon do
  @moduledoc """
  The iOS launch screen's icon: the app icon at 96 pt with rounded corners,
  compiled into the app's asset catalog as the image set `MobLaunchIcon`.

  iOS shows the launch screen from the user's tap until the app's first
  frame, before any of the app's code runs. mob_new's `ios/Info.plist` names
  this image in `UILaunchScreen`, so the app's own icon covers process start;
  Mob's boot screen (`MobRootView`) then draws the same image in the same
  place and adds a loading indicator under it while the BEAM starts.

  The image is made at build time from the largest PNG in
  `AppIcon.appiconset`, so it follows `mix mob.icon` and hand-made icons and
  nothing is stored in the project. The rounding is `priv/launch_icon.swift`
  (CoreGraphics), cached under the system temp dir by the source PNG's hash.
  """

  @image_set "MobLaunchIcon"
  @points 96

  @doc """
  Runs `fun` with the asset catalog to compile and returns its result.

  The catalog is a temporary copy of `catalog` with the `MobLaunchIcon` image
  set added, removed once `fun` returns. When the app icon has no PNG or the
  image cannot be made, `fun` gets `catalog` itself and the launch screen
  stays plain, as it was before this image existed.
  """
  @spec with_catalog(Path.t(), (Path.t() -> result)) :: result when result: var
  def with_catalog(catalog \\ "ios/Assets.xcassets", fun) do
    with {:ok, source} <- largest_icon(catalog),
         {:ok, pngs} <- rounded_pngs(source) do
      tmp = Path.join(System.tmp_dir!(), "mob_assets_#{System.unique_integer([:positive])}")
      copy = Path.join(tmp, Path.basename(catalog))

      try do
        File.mkdir_p!(tmp)
        File.cp_r!(catalog, copy)
        write_image_set!(Path.join(copy, "#{@image_set}.imageset"), pngs)
        fun.(copy)
      after
        File.rm_rf(tmp)
      end
    else
      _ -> fun.(catalog)
    end
  end

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

  defp largest_icon(catalog) do
    catalog
    |> Path.join("AppIcon.appiconset/*.png")
    |> Path.wildcard()
    |> Enum.max_by(&File.stat!(&1).size, fn -> nil end)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  # Made once per source icon: into a scratch dir renamed into place, so a
  # build killed mid-write or a concurrent build never leaves half a PNG in
  # the cache.
  defp rounded_pngs(source) do
    hash = :crypto.hash(:sha256, File.read!(source)) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "mob_launch_icon_#{binary_part(hash, 0, 16)}_#{@points}")
    pngs = for scale <- [2, 3], do: Path.join(dir, "launch_icon@#{scale}x.png")

    if Enum.all?(pngs, &File.exists?/1) do
      {:ok, pngs}
    else
      scratch = "#{dir}.#{System.unique_integer([:positive])}"
      File.mkdir_p!(scratch)
      script = Application.app_dir(:mob_dev, "priv/launch_icon.swift")

      case System.cmd("xcrun", ["swift", script, source, scratch, to_string(@points)],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          _ = File.rename(scratch, dir)
          File.rm_rf(scratch)
          if Enum.all?(pngs, &File.exists?/1), do: {:ok, pngs}, else: :error

        {output, _} ->
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
