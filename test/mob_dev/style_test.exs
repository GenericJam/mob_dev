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
      assert length(errs) == 4
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
