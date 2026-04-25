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

  # ── helpers ──────────────────────────────────────────────────────────────────

  # Creates a minimal 64×64 white PNG in the tmp dir using Image library.
  defp write_test_png(dir) do
    path = Path.join(dir, "test_source.png")
    Image.new!(64, 64, color: :white) |> Image.write!(path)
    path
  end
end
