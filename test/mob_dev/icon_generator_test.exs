defmodule MobDev.IconGeneratorTest do
  use ExUnit.Case, async: true

  alias MobDev.IconGenerator

  # ── metadata ─────────────────────────────────────────────────────────────────

  describe "android_sizes/0" do
    test "returns a map with 5 entries" do
      assert map_size(IconGenerator.android_sizes()) == 5
    end

    test "includes all five mipmap buckets" do
      sizes = IconGenerator.android_sizes()
      assert Map.has_key?(sizes, "mipmap-mdpi")
      assert Map.has_key?(sizes, "mipmap-hdpi")
      assert Map.has_key?(sizes, "mipmap-xhdpi")
      assert Map.has_key?(sizes, "mipmap-xxhdpi")
      assert Map.has_key?(sizes, "mipmap-xxxhdpi")
    end

    test "mdpi is 48px" do
      assert IconGenerator.android_sizes()["mipmap-mdpi"] == 48
    end

    test "xxxhdpi is 192px" do
      assert IconGenerator.android_sizes()["mipmap-xxxhdpi"] == 192
    end

    test "all values are positive integers" do
      IconGenerator.android_sizes()
      |> Map.values()
      |> Enum.each(fn px -> assert is_integer(px) and px > 0 end)
    end
  end

  describe "ios_sizes/0" do
    test "returns a non-empty list" do
      assert length(IconGenerator.ios_sizes()) >= 4
    end

    test "includes 1024px (App Store)" do
      assert 1024 in IconGenerator.ios_sizes()
    end

    test "includes common iPhone sizes" do
      sizes = IconGenerator.ios_sizes()
      # iPhone App 2x / Spotlight 3x
      assert 120 in sizes
      # iPhone App 3x
      assert 180 in sizes
    end

    test "all values are positive integers" do
      IconGenerator.ios_sizes()
      |> Enum.each(fn px -> assert is_integer(px) and px > 0 end)
    end
  end

  # ── generate_from_source/2 ────────────────────────────────────────────────────

  describe "generate_from_source/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "icon_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns :ok", %{tmp: tmp} do
      source = write_test_png(tmp)
      assert :ok = IconGenerator.generate_from_source(source, tmp)
    end

    test "writes Android mdpi icon", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)
      path = Path.join(tmp, "android/app/src/main/res/mipmap-mdpi/ic_launcher.png")
      assert File.exists?(path)
    end

    test "writes all Android mipmap buckets", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)

      Enum.each(IconGenerator.android_sizes(), fn {bucket, _px} ->
        path = Path.join(tmp, "android/app/src/main/res/#{bucket}/ic_launcher.png")
        assert File.exists?(path), "Missing: #{path}"
      end)
    end

    test "writes iOS icons for each size", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)

      Enum.each(IconGenerator.ios_sizes(), fn px ->
        path = Path.join(tmp, "ios/Assets.xcassets/AppIcon.appiconset/icon_#{px}.png")
        assert File.exists?(path), "Missing icon_#{px}.png"
      end)
    end

    test "writes iOS Contents.json", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)
      json_path = Path.join(tmp, "ios/Assets.xcassets/AppIcon.appiconset/Contents.json")
      assert File.exists?(json_path)
    end

    test "Contents.json is valid JSON with images array", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)
      json_path = Path.join(tmp, "ios/Assets.xcassets/AppIcon.appiconset/Contents.json")
      {:ok, parsed} = Jason.decode(File.read!(json_path))
      assert length(parsed["images"]) > 0
    end

    test "Android icons are square (not squashed)", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)

      Enum.each(IconGenerator.android_sizes(), fn {bucket, px} ->
        path = Path.join(tmp, "android/app/src/main/res/#{bucket}/ic_launcher.png")
        img = Image.open!(path)
        assert Image.width(img) == px, "#{bucket}: width #{Image.width(img)} != #{px}"
        assert Image.height(img) == px, "#{bucket}: height #{Image.height(img)} != #{px}"
      end)
    end

    test "iOS icons are square (not squashed)", %{tmp: tmp} do
      source = write_test_png(tmp)
      IconGenerator.generate_from_source(source, tmp)

      Enum.each(IconGenerator.ios_sizes(), fn px ->
        path = Path.join(tmp, "ios/Assets.xcassets/AppIcon.appiconset/icon_#{px}.png")
        img = Image.open!(path)
        assert Image.width(img) == px, "icon_#{px}: width #{Image.width(img)} != #{px}"
        assert Image.height(img) == px, "icon_#{px}: height #{Image.height(img)} != #{px}"
      end)
    end
  end

  # ── generate_random/1 (integration — requires Avatarz + libvips) ─────────────

  describe "generate_random/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "icon_random_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    @tag :integration
    test "returns :ok and writes icon_source.png", %{tmp: tmp} do
      assert :ok = IconGenerator.generate_random(tmp)
      assert File.exists?(Path.join(tmp, "icon_source.png"))
    end

    @tag :integration
    test "writes android icons after random generation", %{tmp: tmp} do
      IconGenerator.generate_random(tmp)
      path = Path.join(tmp, "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")
      assert File.exists?(path)
    end
  end

  # ── adaptive_sizes/0 ─────────────────────────────────────────────────────────

  describe "adaptive_sizes/0" do
    test "covers all five mipmap buckets" do
      sizes = IconGenerator.adaptive_sizes()
      assert map_size(sizes) == 5

      Enum.each(
        ["mipmap-mdpi", "mipmap-hdpi", "mipmap-xhdpi", "mipmap-xxhdpi", "mipmap-xxxhdpi"],
        fn b -> assert Map.has_key?(sizes, b) end
      )
    end

    test "mdpi is 108px (one density-pixel == one device-pixel)" do
      assert IconGenerator.adaptive_sizes()["mipmap-mdpi"] == 108
    end

    test "xxxhdpi is 432px (4× density)" do
      assert IconGenerator.adaptive_sizes()["mipmap-xxxhdpi"] == 432
    end

    test "every adaptive size is larger than the matching legacy size" do
      adaptive = IconGenerator.adaptive_sizes()
      legacy = IconGenerator.android_sizes()

      Enum.each(adaptive, fn {bucket, px} ->
        assert px > legacy[bucket],
               "adaptive #{bucket} (#{px}) should exceed legacy (#{legacy[bucket]})"
      end)
    end
  end

  # ── adaptive_icon_xml/0 ──────────────────────────────────────────────────────

  describe "adaptive_icon_xml/0" do
    test "is a valid-looking XML fragment with adaptive-icon root" do
      xml = IconGenerator.adaptive_icon_xml()
      assert String.starts_with?(xml, "<?xml")
      assert xml =~ "<adaptive-icon"
      assert xml =~ "</adaptive-icon>"
    end

    test "references the foreground mipmap" do
      assert IconGenerator.adaptive_icon_xml() =~ "@mipmap/ic_launcher_foreground"
    end

    test "references the background colour resource" do
      assert IconGenerator.adaptive_icon_xml() =~ "@color/ic_launcher_background"
    end
  end

  # ── background_color_xml/1 ───────────────────────────────────────────────────

  describe "background_color_xml/1" do
    test "embeds the colour as ic_launcher_background" do
      xml = IconGenerator.background_color_xml("#E8B53C")
      assert xml =~ ~s(<color name="ic_launcher_background">#E8B53C</color>)
    end

    test "accepts hex without leading #" do
      xml = IconGenerator.background_color_xml("E8B53C")
      assert xml =~ ~s(>#E8B53C<)
    end

    test "uppercases hex digits" do
      xml = IconGenerator.background_color_xml("#e8b53c")
      assert xml =~ ~s(>#E8B53C<)
    end

    test "rejects non-hex input" do
      assert_raise ArgumentError, fn ->
        IconGenerator.background_color_xml("not a colour")
      end
    end

    test "rejects 3-digit shorthand (Android wants 6-digit)" do
      assert_raise ArgumentError, fn ->
        IconGenerator.background_color_xml("#FFF")
      end
    end
  end

  # ── rgb_to_hex/3 ─────────────────────────────────────────────────────────────

  describe "rgb_to_hex/3" do
    test "encodes black as #000000" do
      assert IconGenerator.rgb_to_hex(0, 0, 0) == "#000000"
    end

    test "encodes white as #FFFFFF" do
      assert IconGenerator.rgb_to_hex(255, 255, 255) == "#FFFFFF"
    end

    test "pads single-digit hex to two characters" do
      assert IconGenerator.rgb_to_hex(1, 2, 3) == "#010203"
    end

    test "rounds non-integer channels" do
      assert IconGenerator.rgb_to_hex(1.4, 2.6, 3.0) == "#010303"
    end

    test "clamps values above 255" do
      assert IconGenerator.rgb_to_hex(300, 255, 255) == "#FFFFFF"
    end

    test "clamps negative values to 0" do
      assert IconGenerator.rgb_to_hex(-5, 0, 0) == "#000000"
    end
  end

  # ── generate_adaptive/3 ──────────────────────────────────────────────────────

  describe "generate_adaptive/3" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "icon_adaptive_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "writes a foreground PNG for every adaptive size", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])

      assert :ok =
               IconGenerator.generate_adaptive(source, tmp, background_color: "#E8B53C")

      Enum.each(IconGenerator.adaptive_sizes(), fn {bucket, _px} ->
        path =
          Path.join(tmp, "android/app/src/main/res/#{bucket}/ic_launcher_foreground.png")

        assert File.exists?(path), "Missing: #{path}"
      end)
    end

    test "foreground PNGs are sized to match adaptive_sizes/0", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])
      IconGenerator.generate_adaptive(source, tmp, background_color: "#E8B53C")

      Enum.each(IconGenerator.adaptive_sizes(), fn {bucket, px} ->
        path =
          Path.join(tmp, "android/app/src/main/res/#{bucket}/ic_launcher_foreground.png")

        img = Image.open!(path)
        assert Image.width(img) == px, "#{bucket}: width #{Image.width(img)} != #{px}"
        assert Image.height(img) == px, "#{bucket}: height #{Image.height(img)} != #{px}"
      end)
    end

    test "writes adaptive ic_launcher.xml", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])
      IconGenerator.generate_adaptive(source, tmp, background_color: "#E8B53C")

      path = Path.join(tmp, "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml")
      assert File.exists?(path)
      assert File.read!(path) =~ "@mipmap/ic_launcher_foreground"
    end

    test "writes ic_launcher_round.xml referencing the same adaptive icon", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])
      IconGenerator.generate_adaptive(source, tmp, background_color: "#E8B53C")

      path =
        Path.join(tmp, "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml")

      assert File.exists?(path)
      assert File.read!(path) =~ "@mipmap/ic_launcher_foreground"
    end

    test "writes background colour XML in values/", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])
      IconGenerator.generate_adaptive(source, tmp, background_color: "#E8B53C")

      path = Path.join(tmp, "android/app/src/main/res/values/ic_launcher_background.xml")
      assert File.exists?(path)
      assert File.read!(path) =~ "#E8B53C"
    end

    test "auto-extracts background colour from source when not specified", %{tmp: tmp} do
      source = write_test_png(tmp, color: [232, 181, 60])
      assert :ok = IconGenerator.generate_adaptive(source, tmp, [])

      path = Path.join(tmp, "android/app/src/main/res/values/ic_launcher_background.xml")
      content = File.read!(path)
      # Image used a uniform colour, so the extracted hex should match it.
      assert content =~ "#E8B53C"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  # Creates a small solid-colour PNG in `dir`. Defaults to white; pass
  # `color:` as a 3-tuple/list of integers (e.g. `[232, 181, 60]`).
  defp write_test_png(dir, opts \\ []) do
    path = Path.join(dir, "test_source.png")
    color = Keyword.get(opts, :color, :white)
    Image.new!(64, 64, color: color) |> Image.write!(path)
    path
  end
end
