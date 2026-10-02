defmodule MobDev.PluginTest do
  # async: false — mutates global Application env
  use ExUnit.Case, async: false

  alias MobDev.Plugin

  @host :mob_dev_plugin_test_host

  describe "host_config/3" do
    test "reads a configured key from the host app's env" do
      Application.put_env(@host, :ash_domains, [:blog, :auth])
      on_exit(fn -> Application.delete_env(@host, :ash_domains) end)

      assert Plugin.host_config(@host, :ash_domains, []) == [:blog, :auth]
    end

    test "returns the supplied default when the key is unset" do
      assert Plugin.host_config(@host, :never_set, []) == []
    end

    test "defaults to nil when no default is given" do
      assert Plugin.host_config(@host, :never_set) == nil
    end
  end

  describe "activated_names/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_plugin_names_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads config :mob, :plugins from mob.exs", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, :plugins, [:mob_foo]\n")
      assert Plugin.activated_names(dir) == [:mob_foo]
    end

    test "falls back to the Application env when mob.exs is missing", %{dir: dir} do
      original = Application.get_env(:mob, :plugins)
      Application.put_env(:mob, :plugins, [:mob_from_env])

      on_exit(fn ->
        if original,
          do: Application.put_env(:mob, :plugins, original),
          else: Application.delete_env(:mob, :plugins)
      end)

      assert Plugin.activated_names(dir) == [:mob_from_env]
    end

    # MOB-280: a broken mob.exs used to read as "no plugins", so the native
    # build linked no plugin NIFs and every call hit :nif_not_loaded.
    test "raises when mob.exs fails to evaluate", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, :plugins, [:mob_foo\n")

      assert_raise TokenMissingError, fn -> Plugin.activated_names(dir) end
    end
  end

  # MOB-325: a plugin listed twice in `config :mob, :plugins` passed the MOB-170
  # collision check as one plugin but was merged twice — its NIF source compiled
  # and linked twice (duplicate symbols), its bridge/swift sources and manifest
  # snippets spliced twice.
  describe "load_activated/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_plugin_dup_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "priv"))
      on_exit(fn -> File.rm_rf!(dir) end)

      manifest = %{
        name: :mob_dup,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [
          %{module: :dup_nif, native_dir: "priv/native/jni"},
          %{module: :dup_zig, lang: :zig, native_dir: "priv/native/zig"}
        ],
        android: %{
          bridge_kt: ["priv/native/android/DupBridge.kt"],
          manifest_application_snippets: [~s(<service android:name=".DupService"/>)]
        },
        ios: %{swift_files: ["priv/native/ios/Dup.swift"]}
      }

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest))
      {:ok, dir: dir}
    end

    test "a plugin activated twice is loaded and merged once", %{dir: dir} do
      activated =
        for {d, m, _status} <-
              Plugin.load_activated([:mob_dup, :mob_dup], %{mob_dup: dir}, [:mob_dup]),
            do: {d, m}

      assert [{^dir, %{name: :mob_dup}}] = activated

      assert Plugin.Merge.nif_sources(activated) == [Path.join(dir, "priv/native/jni/dup_nif.c")]

      assert Plugin.Merge.zig_nif_sources(activated) == [
               Path.join(dir, "priv/native/zig/dup_zig.zig")
             ]

      assert [{:mob_dup, _c}, {:mob_dup, _zig}] =
               MobDev.ZigBuild.plugin_nif_sources(activated, :android)

      assert Plugin.Merge.bridge_kt_sources(activated) == [
               Path.join(dir, "priv/native/android/DupBridge.kt")
             ]

      assert Plugin.Merge.swift_files(activated) == [Path.join(dir, "priv/native/ios/Dup.swift")]
      assert [_one] = Plugin.Merge.android_manifest_snippets(activated)
    end

    test "two names resolving to the same plugin dir count as one plugin", %{dir: dir} do
      assert [{^dir, %{name: :mob_dup}, :ok}] =
               Plugin.load_activated([:mob_dup, :mob_alias], %{mob_dup: dir, mob_alias: dir}, [
                 :mob_dup
               ])
    end

    test "distinct plugins and activation order are preserved; unresolved names skipped",
         %{dir: dir} do
      other = dir <> "_tier0"
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)

      assert [{^other, nil, :unsigned}, {^dir, %{}, :ok}] =
               Plugin.load_activated(
                 [:mob_tier0, :mob_missing, :mob_dup, :mob_tier0],
                 %{mob_dup: dir, mob_tier0: other},
                 [:mob_dup]
               )
    end
  end
end
