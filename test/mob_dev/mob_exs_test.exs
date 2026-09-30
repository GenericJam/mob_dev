defmodule MobDev.MobExsTest do
  use ExUnit.Case, async: true

  alias MobDev.MobExs

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_exs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp committed_mob_exs do
    """
    import Config

    config :mob, :plugins, [:mob_camera]

    #{MobExs.local_import()}
    """
  end

  defp read_config(dir), do: Config.Reader.read!(Path.join(dir, "mob.exs"))

  describe "insert_config/2" do
    test "a stanza added to mob.exs does not override mob.local.exs", %{dir: dir} do
      # :styles is a plain list — Config replaces it rather than merging, so
      # whichever call runs last decides the value.
      File.write!(Path.join(dir, "mob.local.exs"), """
      import Config
      config :mob, :styles, [:local_style]
      """)

      updated = MobExs.insert_config(committed_mob_exs(), "config :mob, :styles, [:committed]")
      File.write!(Path.join(dir, "mob.exs"), updated)

      assert read_config(dir)[:mob][:styles] == [:local_style]
      assert read_config(dir)[:mob][:plugins] == [:mob_camera]
      assert String.ends_with?(String.trim_trailing(updated), MobExs.local_import())
    end

    test "appends when mob.exs has no local import", %{dir: dir} do
      updated = MobExs.insert_config("import Config\n", "config :mob_dev, beam_flags: \"-S 1:1\"")
      File.write!(Path.join(dir, "mob.exs"), updated)

      assert read_config(dir)[:mob_dev][:beam_flags] == "-S 1:1"
    end

    # Hand-written imports: unparenthesised and unconditional, and a
    # multi-line `if ... do ... end`. The stanza must land above the whole
    # statement, not after it and not inside it.
    for {label, import_stmt} <- [
          {"bare import_config", ~s|import_config "mob.local.exs"|},
          {"if/do/end",
           ~s|if File.exists?(Path.join(__DIR__, "mob.local.exs")) do\n  import_config "mob.local.exs"\nend|}
        ] do
      test "goes above a #{label} import", %{dir: dir} do
        File.write!(
          Path.join(dir, "mob.local.exs"),
          "import Config\nconfig :mob, :styles, [:local]\n"
        )

        mob_exs =
          "import Config\n\nconfig :mob, :plugins, [:mob_camera]\n\n#{unquote(import_stmt)}\n"

        updated = MobExs.insert_config(mob_exs, "config :mob, :styles, [:committed]")
        File.write!(Path.join(dir, "mob.exs"), updated)

        assert read_config(dir)[:mob][:styles] == [:local]
        assert read_config(dir)[:mob][:plugins] == [:mob_camera]
      end
    end
  end

  describe "ensure_local_import/1" do
    test "adds the import so mob.local.exs values win", %{dir: dir} do
      File.write!(
        Path.join(dir, "mob.local.exs"),
        "import Config\nconfig :mob_dev, mob_dir: \"/local\"\n"
      )

      File.write!(
        Path.join(dir, "mob.exs"),
        MobExs.ensure_local_import("import Config\nconfig :mob_dev, mob_dir: \"/path/to/mob\"\n")
      )

      assert read_config(dir)[:mob_dev][:mob_dir] == "/local"
    end

    test "leaves a mob.exs that already imports mob.local.exs unchanged" do
      assert MobExs.ensure_local_import(committed_mob_exs()) == committed_mob_exs()
    end

    # A second import of the same file makes Config.Reader raise
    # "attempting to load configuration ... recursively".
    test "recognises an unparenthesised import and does not add a second one", %{dir: dir} do
      File.write!(
        Path.join(dir, "mob.local.exs"),
        "import Config\nconfig :mob_dev, mob_dir: \"/local\"\n"
      )

      mob_exs = "import Config\n\nimport_config \"mob.local.exs\"\n"

      assert MobExs.ensure_local_import(mob_exs) == mob_exs

      File.write!(Path.join(dir, "mob.exs"), MobExs.ensure_local_import(mob_exs))
      assert read_config(dir)[:mob_dev][:mob_dir] == "/local"
    end
  end

  describe "put_local_config/2" do
    test "writes mob_dir to mob.local.exs and leaves mob.exs config intact", %{dir: dir} do
      mob_exs = """
      import Config

      config :mob_dev, mob_dir: "/path/to/mob"
      config :mob, :plugins, [:mob_camera]
      config :mob, :trusted_plugins, %{mob_camera: "ed25519:abc="}
      """

      File.write!(Path.join(dir, "mob.exs"), mob_exs)

      MobExs.put_local_config(dir, mob_dir: "/Users/me/code/mob")

      written = File.read!(Path.join(dir, "mob.exs"))
      assert String.starts_with?(written, mob_exs)
      refute written =~ "/Users/me/code/mob"

      config = read_config(dir)
      assert config[:mob_dev][:mob_dir] == "/Users/me/code/mob"
      assert config[:mob][:plugins] == [:mob_camera]
      assert config[:mob][:trusted_plugins] == %{mob_camera: "ed25519:abc="}
    end

    test "keeps the other settings already in mob.local.exs", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), committed_mob_exs())

      File.write!(Path.join(dir, "mob.local.exs"), """
      import Config
      config :mob_dev, mob_dir: "/old", android_ndk_version: "27.0.0"
      """)

      MobExs.put_local_config(dir, mob_dir: "/new")

      assert read_config(dir)[:mob_dev] |> Enum.sort() ==
               [android_ndk_version: "27.0.0", mob_dir: "/new"]

      assert File.read!(Path.join(dir, "mob.exs")) == committed_mob_exs()
    end

    test "creates a mob.exs that imports mob.local.exs when there is none", %{dir: dir} do
      MobExs.put_local_config(dir, mob_dir: "/abs/mob")

      assert read_config(dir)[:mob_dev][:mob_dir] == "/abs/mob"
    end
  end
end
