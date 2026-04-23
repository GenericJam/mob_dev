defmodule MobDev.IconGenerator do
  # Image and Avatarz are optional deps — only needed for custom/random icon generation.
  # When they're absent we fall back to resizing the bundled mob_logo.svg via sips
  # (macOS built-in), which requires no extra dependencies.
  @compile {:no_warn_undefined, [Image, Avatarz, Avatarz.Sets.Robot]}

  @moduledoc """
  Generates app icons for Android and iOS from either a random robot avatar
  (using Avatarz) or a provided source image (using Image).

  When the `image` dep is not available, falls back to the bundled Mob logo
  (resized via `sips`, which ships with macOS).

  ## Android sizes (mipmap buckets)

    | Bucket      | px  |
    |-------------|-----|
    | mdpi        |  48 |
    | hdpi        |  72 |
    | xhdpi       |  96 |
    | xxhdpi      | 144 |
    | xxxhdpi     | 192 |

  ## iOS sizes (AppIcon.appiconset subset)

    | Usage                     | px   |
    |---------------------------|------|
    | iPhone Notification 2x    |  40  |
    | iPhone Notification 3x    |  60  |
    | iPhone Settings 2x        |  58  |
    | iPhone Settings 3x        |  87  |
    | iPhone Spotlight 2x       |  80  |
    | iPhone Spotlight 3x       | 120  |
    | iPhone App 2x             | 120  |
    | iPhone App 3x             | 180  |
    | iPad Notification 1x      |  20  |
    | iPad Notification 2x      |  40  |
    | iPad Settings 1x          |  29  |
    | iPad Settings 2x          |  58  |
    | iPad Spotlight 1x         |  40  |
    | iPad Spotlight 2x         |  80  |
    | iPad App 1x               |  76  |
    | iPad App 2x               | 152  |
    | iPad Pro App 2x           | 167  |
    | App Store                 |1024  |
  """

  @mob_logo_svg :code.priv_dir(:mob_dev) |> Path.join("mob_logo.svg")

  @android_sizes %{
    "mipmap-mdpi"    => 48,
    "mipmap-hdpi"    => 72,
    "mipmap-xhdpi"   => 96,
    "mipmap-xxhdpi"  => 144,
    "mipmap-xxxhdpi" => 192
  }

  @ios_sizes [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]

  @doc """
  Generates a random robot avatar and writes platform icons into `output_dir`.

  Creates:
    - `output_dir/android/app/src/main/res/<bucket>/ic_launcher.png` for each Android bucket
    - `output_dir/ios/Assets.xcassets/AppIcon.appiconset/icon_<px>.png` for each iOS size
    - `output_dir/icon_source.png` — the 1024×1024 master

  Returns `:ok` on success.
  """
  @spec generate_random(output_dir :: String.t()) :: :ok
  def generate_random(output_dir) do
    if image_available?() do
      renders_path = Path.join(output_dir, ".icon_renders")
      File.mkdir_p!(renders_path)

      seed = Path.basename(output_dir)
      avatar = Avatarz.render(seed, Avatarz.Sets.Robot, :robot, renders_path)

      source_png = Path.join(output_dir, "icon_source.png")
      Image.write!(avatar.image, source_png)

      resize_for_platforms(source_png, output_dir)
    else
      Mix.shell().info("""
      \nNote: the `image` dependency is not available so a random icon could not
      be generated. Using the Mob logo as a placeholder instead.
      Run `mix mob.icon` after adding `{:image, "~> 0.54"}` to your deps to
      replace it with a custom or generated icon.\n
      """)
      resize_svg_for_platforms(@mob_logo_svg, output_dir)
    end
  end

  @doc """
  Resizes an existing image at `source_path` to all platform icon sizes,
  writing them into `output_dir`.

  Returns `:ok`.
  """
  @spec generate_from_source(source_path :: String.t(), output_dir :: String.t()) :: :ok
  def generate_from_source(source_path, output_dir) do
    if image_available?() do
      resize_for_platforms(source_path, output_dir)
    else
      Mix.raise("""
      The `image` dependency is required to generate icons from a source file.
      Add `{:image, "~> 0.54"}` to your deps and run `mix deps.get`.
      """)
    end
  end

  @doc """
  Returns the map of Android mipmap bucket names to pixel dimensions.
  """
  @spec android_sizes() :: %{String.t() => pos_integer()}
  def android_sizes, do: @android_sizes

  @doc """
  Returns the list of iOS icon pixel dimensions.
  """
  @spec ios_sizes() :: [pos_integer()]
  def ios_sizes, do: @ios_sizes

  # ── private ──────────────────────────────────────────────────────────────────

  # Returns true when the `image` library is loaded and available at runtime.
  defp image_available? do
    Code.ensure_loaded?(Image)
  end

  defp resize_for_platforms(source_png, output_dir) do
    source = Image.open!(source_png)
    write_android_icons(source, output_dir)
    write_ios_icons(source, output_dir)
    :ok
  end

  # Fallback path: resize an SVG to all platform sizes using sips (macOS built-in).
  # sips can convert SVG→PNG and resize in one step, no extra deps needed.
  defp resize_svg_for_platforms(svg_path, output_dir) do
    all_sizes =
      Map.values(@android_sizes) ++ @ios_sizes
      |> Enum.uniq()

    # Convert each size once into a temp PNG, then distribute to platform dirs.
    tmp = System.tmp_dir!()

    size_to_png =
      Map.new(all_sizes, fn px ->
        tmp_png = Path.join(tmp, "mob_icon_#{px}.png")
        {0, _} = System.cmd("sips", [
          "-s", "format", "png",
          "-z", "#{px}", "#{px}",
          svg_path, "--out", tmp_png
        ], stderr_to_stdout: true)
        {px, tmp_png}
      end)

    write_android_icons_from_map(size_to_png, output_dir)
    write_ios_icons_from_map(size_to_png, output_dir)

    # Clean up temp files
    Enum.each(size_to_png, fn {_, path} -> File.rm(path) end)
    :ok
  end

  defp write_android_icons(source, output_dir) do
    Enum.each(@android_sizes, fn {bucket, px} ->
      dest_dir = Path.join([output_dir, "android", "app", "src", "main", "res", bucket])
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, "ic_launcher.png")
      source |> Image.thumbnail!(px) |> Image.write!(dest)
    end)
  end

  defp write_android_icons_from_map(size_to_png, output_dir) do
    Enum.each(@android_sizes, fn {bucket, px} ->
      dest_dir = Path.join([output_dir, "android", "app", "src", "main", "res", bucket])
      File.mkdir_p!(dest_dir)
      File.cp!(size_to_png[px], Path.join(dest_dir, "ic_launcher.png"))
    end)
  end

  defp write_ios_icons(source, output_dir) do
    dest_dir = Path.join([output_dir, "ios", "Assets.xcassets", "AppIcon.appiconset"])
    File.mkdir_p!(dest_dir)

    Enum.each(@ios_sizes, fn px ->
      dest = Path.join(dest_dir, "icon_#{px}.png")
      source |> Image.thumbnail!(px) |> Image.write!(dest)
    end)

    write_ios_contents_json(dest_dir)
  end

  defp write_ios_icons_from_map(size_to_png, output_dir) do
    dest_dir = Path.join([output_dir, "ios", "Assets.xcassets", "AppIcon.appiconset"])
    File.mkdir_p!(dest_dir)

    Enum.each(@ios_sizes, fn px ->
      File.cp!(size_to_png[px], Path.join(dest_dir, "icon_#{px}.png"))
    end)

    write_ios_contents_json(dest_dir)
  end

  defp write_ios_contents_json(dest_dir) do
    images =
      [
        %{idiom: "iphone", scale: "2x", size: "20x20",   px: 40},
        %{idiom: "iphone", scale: "3x", size: "20x20",   px: 60},
        %{idiom: "iphone", scale: "2x", size: "29x29",   px: 58},
        %{idiom: "iphone", scale: "3x", size: "29x29",   px: 87},
        %{idiom: "iphone", scale: "2x", size: "40x40",   px: 80},
        %{idiom: "iphone", scale: "3x", size: "40x40",   px: 120},
        %{idiom: "iphone", scale: "2x", size: "60x60",   px: 120},
        %{idiom: "iphone", scale: "3x", size: "60x60",   px: 180},
        %{idiom: "ipad",   scale: "1x", size: "20x20",   px: 20},
        %{idiom: "ipad",   scale: "2x", size: "20x20",   px: 40},
        %{idiom: "ipad",   scale: "1x", size: "29x29",   px: 29},
        %{idiom: "ipad",   scale: "2x", size: "29x29",   px: 58},
        %{idiom: "ipad",   scale: "1x", size: "40x40",   px: 40},
        %{idiom: "ipad",   scale: "2x", size: "40x40",   px: 80},
        %{idiom: "ipad",   scale: "1x", size: "76x76",   px: 76},
        %{idiom: "ipad",   scale: "2x", size: "76x76",   px: 152},
        %{idiom: "ipad",   scale: "2x", size: "83.5x83.5", px: 167},
        %{idiom: "ios-marketing", scale: "1x", size: "1024x1024", px: 1024}
      ]
      |> Enum.map(fn %{idiom: idiom, scale: scale, size: size, px: px} ->
        %{
          "filename" => "icon_#{px}.png",
          "idiom"    => idiom,
          "scale"    => scale,
          "size"     => size
        }
      end)

    contents = %{"images" => images, "info" => %{"author" => "mob", "version" => 1}}
    json_path = Path.join(dest_dir, "Contents.json")
    File.write!(json_path, Jason.encode!(contents, pretty: true))
  end
end
