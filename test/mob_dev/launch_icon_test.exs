defmodule MobDev.LaunchIconTest do
  use ExUnit.Case, async: true

  alias MobDev.LaunchIcon

  @moduletag :tmp_dir

  # A catalog shaped like mob_new's: AppIcon.appiconset with one icon PNG.
  defp catalog_with_icon(tmp_dir) do
    catalog = Path.join(tmp_dir, "Assets.xcassets")
    set = Path.join(catalog, "AppIcon.appiconset")
    File.mkdir_p!(set)

    File.cp!(
      Application.app_dir(:mob_dev, "priv/mob_logo/1024.png"),
      Path.join(set, "icon_1024.png")
    )

    File.write!(Path.join(set, "Contents.json"), ~s({"images":[],"info":{"version":1}}))
    catalog
  end

  test "an app icon without a PNG compiles the project's catalog as it is", %{tmp_dir: tmp_dir} do
    catalog = Path.join(tmp_dir, "Assets.xcassets")
    File.mkdir_p!(Path.join(catalog, "AppIcon.appiconset"))

    assert LaunchIcon.with_catalog(catalog, & &1) == catalog
    refute File.exists?(Path.join(catalog, "MobLaunchIcon.imageset"))
  end

  unless match?({:unix, :darwin}, :os.type()) and System.find_executable("xcrun"),
    do: @tag(skip: "needs macOS with xcrun swift")

  test "adds a rounded 96 pt launch icon to a copy of the catalog, removed afterwards",
       %{tmp_dir: tmp_dir} do
    catalog = catalog_with_icon(tmp_dir)

    {copy, contents, pngs} =
      LaunchIcon.with_catalog(catalog, fn copy ->
        set = Path.join(copy, "MobLaunchIcon.imageset")

        pngs =
          for scale <- [2, 3] do
            png = File.read!(Path.join(set, "launch_icon@#{scale}x.png"))
            <<_::binary-16, width::32, height::32, _::binary>> = png
            {scale, width, height, top_left_alpha(png)}
          end

        {copy, Jason.decode!(File.read!(Path.join(set, "Contents.json"))), pngs}
      end)

    refute copy == catalog
    # Rounded: the corner pixel is transparent.
    assert pngs == [{2, 192, 192, 0}, {3, 288, 288, 0}]

    assert Enum.any?(
             contents["images"],
             &match?(%{"filename" => "launch_icon@3x.png", "scale" => "3x"}, &1)
           )

    # The copy is gone and the app's own catalog is untouched.
    refute File.exists?(copy)
    refute File.exists?(Path.join(catalog, "MobLaunchIcon.imageset"))
  end

  # Alpha of pixel (0, 0) of an 8-bit RGBA PNG. In row 0 every PNG filter
  # leaves the first pixel's bytes as they are, so no unfiltering is needed.
  defp top_left_alpha(<<_sig::binary-8, chunks::binary>>) do
    <<_len::32, "IHDR", _w::32, _h::32, 8, 6, _::binary>> = chunks
    <<_filter, _r, _g, _b, alpha, _::binary>> = :zlib.uncompress(idat(chunks, []))
    alpha
  end

  defp idat(<<len::32, "IDAT", data::binary-size(len), _crc::32, rest::binary>>, acc),
    do: idat(rest, [acc | data])

  defp idat(<<len::32, _type::binary-4, _::binary-size(len), _crc::32, rest::binary>>, acc),
    do: idat(rest, acc)

  defp idat(<<>>, acc), do: IO.iodata_to_binary(acc)
end
