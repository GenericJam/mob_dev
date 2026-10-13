defmodule MobDev.StyleTest do
  use ExUnit.Case, async: false

  alias MobDev.Style

  @valid %{
    name: :mob_theme_citrus,
    mob_version: "~> 0.6",
    style_spec_version: 1,
    theme: MobThemeCitrus.Theme
  }

  describe "validate/1 (the four-field tokens-only manifest)" do
    test "accepts the minimum viable manifest (round-trips)" do
      m = @valid
      assert {:ok, ^m} = Style.validate(m)
    end

    test "reports every missing field at once" do
      assert {:error, errs} = Style.validate(%{})
      assert [_, _, _, _] = errs
      assert Enum.any?(errs, &(&1 =~ ":name"))
      assert Enum.any?(errs, &(&1 =~ ":mob_version"))
      assert Enum.any?(errs, &(&1 =~ ":style_spec_version"))
      assert Enum.any?(errs, &(&1 =~ ":theme"))
    end

    test "rejects a bad version requirement and an unknown spec version" do
      assert {:error, errs} = Style.validate(%{@valid | mob_version: "not-semver"})
      assert Enum.any?(errs, &(&1 =~ "version requirement"))

      assert {:error, errs} = Style.validate(%{@valid | style_spec_version: 99})
      assert Enum.any?(errs, &(&1 =~ "not supported"))
    end

    test "rejects a non-map manifest" do
      assert {:error, [msg]} = Style.validate([:nope])
      assert msg =~ "must be a map"
    end
  end

  describe "validate/1 — optional assets.fonts" do
    test "accepts a fonts path list" do
      m = Map.put(@valid, :assets, %{fonts: ["priv/fonts/X.ttf"]})
      assert {:ok, ^m} = Style.validate(m)
    end

    test "rejects a non-map assets" do
      assert {:error, [msg]} = Style.validate(Map.put(@valid, :assets, ["priv/fonts/X.ttf"]))
      assert msg =~ "assets must be a map"
    end

    test "rejects keys other than :fonts (styles don't bundle images)" do
      m = Map.put(@valid, :assets, %{fonts: ["priv/fonts/X.ttf"], images: ["priv/a.png"]})
      assert {:error, [msg]} = Style.validate(m)
      assert msg =~ ":images"
    end

    test "rejects fonts that aren't a list of strings" do
      for fonts <- ["priv/fonts/X.ttf", [:x], ["priv/fonts/X.ttf", nil]] do
        assert {:error, [msg]} = Style.validate(Map.put(@valid, :assets, %{fonts: fonts}))
        assert msg =~ "assets.fonts"
      end
    end
  end

  describe "fonts!/1" do
    test "resolves declared fonts against each style dir, in order" do
      a = tmp_style!("")
      b = tmp_style!("")
      touch!(a, "priv/fonts/A.ttf")
      touch!(a, "priv/fonts/B.otf")
      touch!(b, "fonts/C.ttf")

      styles = [
        {a, Map.put(@valid, :assets, %{fonts: ["priv/fonts/A.ttf", "priv/fonts/B.otf"]})},
        {b, Map.merge(@valid, %{name: :other, assets: %{fonts: ["fonts/C.ttf"]}})},
        {tmp_style!(""), @valid}
      ]

      assert Style.fonts!(styles) == [
               Path.join(a, "priv/fonts/A.ttf"),
               Path.join(a, "priv/fonts/B.otf"),
               Path.join(b, "fonts/C.ttf")
             ]
    end

    test "a declared font that doesn't exist fails, naming the style and path" do
      dir = tmp_style!("")
      m = Map.put(@valid, :assets, %{fonts: ["priv/fonts/Missing.ttf"]})

      err = assert_raise ArgumentError, fn -> Style.fonts!([{dir, m}]) end
      assert err.message =~ ":mob_theme_citrus"
      assert err.message =~ Path.join(dir, "priv/fonts/Missing.ttf")
    end

    test "a declared path that is a directory, not a file, fails" do
      dir = tmp_style!("")
      File.mkdir_p!(Path.join(dir, "priv/fonts"))
      m = Map.put(@valid, :assets, %{fonts: ["priv/fonts"]})

      assert_raise ArgumentError, fn -> Style.fonts!([{dir, m}]) end
    end

    test "an invalid manifest fails instead of contributing no fonts" do
      m = Map.put(@valid, :assets, %{fonts: "priv/fonts/X.ttf"})

      assert_raise ArgumentError, ~r/invalid style manifest/, fn ->
        Style.fonts!([{tmp_style!(""), m}])
      end
    end
  end

  describe "load/1" do
    test "loads a manifest file from a style dir" do
      dir = tmp_style!(inspect(@valid))
      assert {:ok, m} = Style.load(dir)
      assert m.name == :mob_theme_citrus
    end

    test "missing manifest is an error (styles have no tier-0 equivalent)" do
      dir = Path.join(System.tmp_dir!(), "mob_style_none_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert {:error, msg} = Style.load(dir)
      assert msg =~ "missing"
    end

    test "a non-map manifest is an error" do
      dir = tmp_style!("[:not, :a, :map]")
      assert {:error, msg} = Style.load(dir)
      assert msg =~ "must evaluate to a map"
    end
  end

  describe "runtime_entries!/0 (build-time resolution)" do
    test "no styles configured → empty entries, nil default" do
      in_tmp_project(fn ->
        assert Style.runtime_entries!() == %{styles: [], default_style: nil}
      end)
    end

    test "a default_style not among the activated styles fails the build" do
      in_tmp_project(fn ->
        Application.put_env(:mob, :default_style, :mob_theme_citrus)
        on_exit(fn -> Application.delete_env(:mob, :default_style) end)

        assert_raise ArgumentError, ~r/not among the activated styles/, fn ->
          Style.runtime_entries!()
        end
      end)
    end
  end

  describe "activated_names/1 + default_style/1 (mob.exs sourcing)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_style_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads :styles and :default_style from mob.exs", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), """
      import Config
      config :mob, styles: [:mob_theme_citrus], default_style: :mob_theme_citrus
      """)

      assert Style.activated_names(dir) == [:mob_theme_citrus]
      assert Style.default_style(dir) == :mob_theme_citrus
    end

    test "falls back to the Application env when mob.exs is missing", %{dir: dir} do
      Application.put_env(:mob, :styles, [:mob_theme_env])
      Application.put_env(:mob, :default_style, :mob_theme_env)

      on_exit(fn ->
        Application.delete_env(:mob, :styles)
        Application.delete_env(:mob, :default_style)
      end)

      assert Style.activated_names(dir) == [:mob_theme_env]
      assert Style.default_style(dir) == :mob_theme_env
    end

    # MOB-280: a broken mob.exs used to read as "no styles".
    test "raises when mob.exs fails to evaluate", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, styles: [:x\n")

      assert_raise TokenMissingError, fn -> Style.activated_names(dir) end
      assert_raise TokenMissingError, fn -> Style.default_style(dir) end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tmp_style!(contents) do
    dir = Path.join(System.tmp_dir!(), "mob_style_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "priv"))
    File.write!(Path.join(dir, "priv/mob_style.exs"), contents)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp touch!(dir, rel) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "font")
  end

  # Style.activated_names/default_style read mob.exs from cwd (absent in a tmp
  # dir → Application-env fallback, which the tests control).
  defp in_tmp_project(fun) do
    dir = Path.join(System.tmp_dir!(), "mob_style_proj_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    cwd = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(cwd)
      File.rm_rf!(dir)
    end
  end
end
