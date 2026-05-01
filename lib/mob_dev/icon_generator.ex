defmodule MobDev.IconGenerator do
  # Image and Avatarz are optional deps — only needed for custom/random icon generation.
  # When they're absent we fall back to the bundled pre-built mob_logo PNGs.
  @compile {:no_warn_undefined, [Image, Avatarz, Avatarz.Sets.Robot]}

  @moduledoc """
  Generates app icons for Android and iOS from either a random robot avatar
  (using Avatarz) or a provided source image (using Image).

  When the `image` dep is not available, falls back to the bundled Mob logo
  (pre-built PNGs shipped with mob_dev, no system tools required).

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

  @mob_logo_dir :code.priv_dir(:mob_dev) |> Path.join("mob_logo")

  @android_sizes %{
    "mipmap-mdpi" => 48,
    "mipmap-hdpi" => 72,
    "mipmap-xhdpi" => 96,
    "mipmap-xxhdpi" => 144,
    "mipmap-xxxhdpi" => 192
  }

  # Adaptive icon canvas is 108×108 dp; foreground PNGs are written at the
  # density-scaled equivalent so the launcher gets a sharp foreground at any
  # device density. Anything outside the centre 66×66 dp may be cropped by
  # the launcher mask, so foreground content should be centre-weighted.
  @adaptive_sizes %{
    "mipmap-mdpi" => 108,
    "mipmap-hdpi" => 162,
    "mipmap-xhdpi" => 216,
    "mipmap-xxhdpi" => 324,
    "mipmap-xxxhdpi" => 432
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

      use_mob_logo(output_dir)
    end
  end

  @doc """
  Copies the bundled Mob logo (pre-built PNGs) to all platform icon directories
  in `output_dir`. Used as the default placeholder icon by `mix mob.install`.
  No extra dependencies or system tools required.

  Returns `:ok`.
  """
  @spec use_mob_logo(output_dir :: String.t()) :: :ok
  def use_mob_logo(output_dir) do
    write_android_icons_from_priv(output_dir)
    write_ios_icons_from_priv(output_dir)
    :ok
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
  Returns the map of Android mipmap bucket names to pixel dimensions
  for legacy (single-layer) icons.
  """
  @spec android_sizes() :: %{String.t() => pos_integer()}
  def android_sizes, do: @android_sizes

  @doc """
  Returns the map of Android mipmap bucket names to pixel dimensions
  for adaptive-icon foreground layers (108×108 dp scaled per density).
  """
  @spec adaptive_sizes() :: %{String.t() => pos_integer()}
  def adaptive_sizes, do: @adaptive_sizes

  @doc """
  Returns the list of iOS icon pixel dimensions.
  """
  @spec ios_sizes() :: [pos_integer()]
  def ios_sizes, do: @ios_sizes

  @doc """
  Generates adaptive Android icons from a source image.

  Writes:
    - `mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml`
      referencing `@mipmap/ic_launcher_foreground` and
      `@color/ic_launcher_background`
    - `mipmap-<bucket>/ic_launcher_foreground.png` at the adaptive icon
      canvas size for each density bucket
    - `values/ic_launcher_background.xml` defining the background color

  ## Options
    * `:background_color` — hex string like `"#E8B53C"`. If absent, sampled
      from the source image at top-centre (10% from the top).

  Legacy `ic_launcher.png`/`ic_launcher_round.png` are written separately
  by `generate_from_source/2` for older Android versions.
  """
  @spec generate_adaptive(source_path :: String.t(), output_dir :: String.t(), keyword()) :: :ok
  def generate_adaptive(source_path, output_dir, opts \\ []) do
    unless image_available?() do
      Mix.raise("""
      The `image` dependency is required to generate adaptive Android icons.
      Add `{:image, "~> 0.54"}` to your deps and run `mix deps.get`.
      """)
    end

    source = Image.open!(source_path)

    bg_hex =
      case opts[:background_color] do
        hex when is_binary(hex) -> normalise_hex!(hex)
        _ -> extract_background_color(source)
      end

    write_adaptive_foregrounds(source, output_dir)
    write_adaptive_xml(output_dir)
    write_background_color(output_dir, bg_hex)
    :ok
  end

  @doc """
  Returns the XML body for `mipmap-anydpi-v26/ic_launcher.xml`.

  Uses `@mipmap/ic_launcher_foreground` for the foreground and
  `@color/ic_launcher_background` for the background.
  """
  @spec adaptive_icon_xml() :: String.t()
  def adaptive_icon_xml do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        <background android:drawable="@color/ic_launcher_background"/>
        <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    </adaptive-icon>
    """
  end

  @doc """
  Returns the XML body for `values/ic_launcher_background.xml` defining
  the adaptive icon background colour.

  Accepts hex strings with or without a leading `#` (case-insensitive).
  Raises `ArgumentError` for non-hex input.
  """
  @spec background_color_xml(String.t()) :: String.t()
  def background_color_xml(hex) do
    hex = normalise_hex!(hex)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <resources>
        <color name="ic_launcher_background">#{hex}</color>
    </resources>
    """
  end

  @doc false
  @spec normalise_hex!(String.t()) :: String.t()
  def normalise_hex!(hex) when is_binary(hex) do
    raw = String.trim(hex) |> String.upcase() |> String.trim_leading("#")

    if Regex.match?(~r/^[0-9A-F]{6}$/, raw) do
      "#" <> raw
    else
      raise ArgumentError,
            "expected hex colour like \"#E8B53C\" or \"E8B53C\", got: #{inspect(hex)}"
    end
  end

  @doc false
  @spec rgb_to_hex(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def rgb_to_hex(r, g, b) do
    [r, g, b]
    |> Enum.map(&clamp_byte/1)
    |> Enum.map(&format_byte/1)
    |> Enum.join()
    |> then(&("#" <> &1))
  end

  defp clamp_byte(n) when is_number(n) do
    n |> round() |> max(0) |> min(255)
  end

  defp format_byte(n) do
    n |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  # ── private ──────────────────────────────────────────────────────────────────

  defp image_available? do
    Code.ensure_loaded?(Image)
  end

  defp resize_for_platforms(source_png, output_dir) do
    source = Image.open!(source_png)
    write_android_icons(source, output_dir)
    write_ios_icons(source, output_dir)
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

  defp write_android_icons_from_priv(output_dir) do
    Enum.each(@android_sizes, fn {bucket, px} ->
      dest_dir = Path.join([output_dir, "android", "app", "src", "main", "res", bucket])
      File.mkdir_p!(dest_dir)
      File.cp!(Path.join(@mob_logo_dir, "#{px}.png"), Path.join(dest_dir, "ic_launcher.png"))
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

  defp write_ios_icons_from_priv(output_dir) do
    dest_dir = Path.join([output_dir, "ios", "Assets.xcassets", "AppIcon.appiconset"])
    File.mkdir_p!(dest_dir)

    Enum.each(@ios_sizes, fn px ->
      File.cp!(Path.join(@mob_logo_dir, "#{px}.png"), Path.join(dest_dir, "icon_#{px}.png"))
    end)

    write_ios_contents_json(dest_dir)
  end

  defp write_adaptive_foregrounds(source, output_dir) do
    Enum.each(@adaptive_sizes, fn {bucket, px} ->
      dest_dir = Path.join([output_dir, "android", "app", "src", "main", "res", bucket])
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, "ic_launcher_foreground.png")
      source |> Image.thumbnail!(px) |> Image.write!(dest)
    end)
  end

  defp write_adaptive_xml(output_dir) do
    dir = Path.join([output_dir, "android", "app", "src", "main", "res", "mipmap-anydpi-v26"])
    File.mkdir_p!(dir)
    body = adaptive_icon_xml()
    File.write!(Path.join(dir, "ic_launcher.xml"), body)
    File.write!(Path.join(dir, "ic_launcher_round.xml"), body)
  end

  defp write_background_color(output_dir, hex) do
    dir = Path.join([output_dir, "android", "app", "src", "main", "res", "values"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ic_launcher_background.xml"), background_color_xml(hex))
  end

  # Sample top-centre pixel (10% from top) — for our typical icons that's
  # inside the artwork's background rather than at a corner that might be
  # transparent or border-styled.
  defp extract_background_color(image) do
    width = Image.width(image)
    height = Image.height(image)
    x = div(width, 2)
    y = div(height, 10) |> max(1)

    case Image.get_pixel(image, x, y) do
      {:ok, [r, g, b | _]} -> rgb_to_hex(r, g, b)
      {:ok, [grey | _]} -> rgb_to_hex(grey, grey, grey)
      _ -> "#FFFFFF"
    end
  end

  defp write_ios_contents_json(dest_dir) do
    images =
      [
        %{idiom: "iphone", scale: "2x", size: "20x20", px: 40},
        %{idiom: "iphone", scale: "3x", size: "20x20", px: 60},
        %{idiom: "iphone", scale: "2x", size: "29x29", px: 58},
        %{idiom: "iphone", scale: "3x", size: "29x29", px: 87},
        %{idiom: "iphone", scale: "2x", size: "40x40", px: 80},
        %{idiom: "iphone", scale: "3x", size: "40x40", px: 120},
        %{idiom: "iphone", scale: "2x", size: "60x60", px: 120},
        %{idiom: "iphone", scale: "3x", size: "60x60", px: 180},
        %{idiom: "ipad", scale: "1x", size: "20x20", px: 20},
        %{idiom: "ipad", scale: "2x", size: "20x20", px: 40},
        %{idiom: "ipad", scale: "1x", size: "29x29", px: 29},
        %{idiom: "ipad", scale: "2x", size: "29x29", px: 58},
        %{idiom: "ipad", scale: "1x", size: "40x40", px: 40},
        %{idiom: "ipad", scale: "2x", size: "40x40", px: 80},
        %{idiom: "ipad", scale: "1x", size: "76x76", px: 76},
        %{idiom: "ipad", scale: "2x", size: "76x76", px: 152},
        %{idiom: "ipad", scale: "2x", size: "83.5x83.5", px: 167},
        %{idiom: "ios-marketing", scale: "1x", size: "1024x1024", px: 1024}
      ]
      |> Enum.map(fn %{idiom: idiom, scale: scale, size: size, px: px} ->
        %{
          "filename" => "icon_#{px}.png",
          "idiom" => idiom,
          "scale" => scale,
          "size" => size
        }
      end)

    contents = %{"images" => images, "info" => %{"author" => "mob", "version" => 1}}
    json_path = Path.join(dest_dir, "Contents.json")
    File.write!(json_path, Jason.encode!(contents, pretty: true))
  end
end
