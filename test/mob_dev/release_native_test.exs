defmodule MobDev.ReleaseNativeTest do
  # Changes the working directory: the release pipelines read the project from it.
  use ExUnit.Case, async: false

  alias MobDev.NativeBuild

  # MOB-404: `mix mob.release` must build from the current plugin set, not
  # reuse what the last `mix mob.deploy --native` left in the checkout.

  describe "android_abi_filters/1" do
    test "reads a Groovy ndk block" do
      gradle = """
      defaultConfig {
          ndk { abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64' }
      }
      """

      assert NativeBuild.android_abi_filters(gradle) == ["arm64-v8a", "armeabi-v7a", "x86_64"]
    end

    test "reads Kotlin DSL forms and merges repeated declarations in order" do
      gradle = """
      ndk {
          abiFilters += listOf("arm64-v8a")
          abiFilters.addAll(listOf("x86_64", "arm64-v8a"))
      }
      """

      assert NativeBuild.android_abi_filters(gradle) == ["arm64-v8a", "x86_64"]
    end

    test "ignores commented-out filters and other quoted strings" do
      gradle = """
      // ndk { abiFilters 'x86' }
      ndk { abiFilters 'arm64-v8a' } // was 'x86_64'
      namespace 'com.example.app'
      """

      assert NativeBuild.android_abi_filters(gradle) == ["arm64-v8a"]
    end

    test "unset gives []" do
      assert NativeBuild.android_abi_filters("android { compileSdk 35 }") == []
    end
  end

  describe "__release_abis__/1" do
    test "builds exactly the filtered ABIs" do
      assert NativeBuild.__release_abis__(["arm64-v8a"]) == {:ok, ["arm64-v8a"]}
    end

    test "no abiFilters means Gradle packages every ABI, so every one is built" do
      assert NativeBuild.__release_abis__([]) == {:ok, ["arm64-v8a", "armeabi-v7a", "x86_64"]}
    end

    test "an ABI mob can't build is refused rather than shipped stale" do
      assert {:error, msg} = NativeBuild.__release_abis__(["arm64-v8a", "x86"])
      assert msg =~ "lists x86,"
    end

    test "no app build.gradle is an error" do
      assert {:error, msg} = NativeBuild.__release_abis__(nil)
      assert msg =~ "build.gradle"
    end
  end

  describe "release pipelines refresh plugin-derived state" do
    setup do
      cwd = File.cwd!()
      dir = Path.join(System.tmp_dir!(), "release_native_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "priv/generated"))
      File.cd!(dir)
      File.write!("mob.exs", "import Config\nconfig :mob_dev, []\n")

      on_exit(fn ->
        File.cd!(cwd)
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "mix mob.release --android regenerates a stale driver table before building" do
      File.mkdir_p!("android")
      File.write!("android/gradlew", "")
      File.write!("priv/generated/driver_tab_android.c", "/* stale */\n")

      # No android/app/build.gradle: the pipeline stops at the ABI lookup, after
      # the plugin-derived files were refreshed.
      assert {:error, msg} = MobDev.ReleaseAndroid.build_aab()
      assert msg =~ "build.gradle"

      tab = File.read!("priv/generated/driver_tab_android.c")
      refute tab =~ "stale"
      assert tab =~ "_nif_init"
      assert File.exists?("priv/generated/mob_plugins.exs")
    end

    test "mix mob.release --ios regenerates a stale driver table before building" do
      # No distribution profile matches this bundle id, so on macOS the
      # pipeline stops at signing resolution (elsewhere at the macOS check),
      # before downloading or compiling anything.
      File.write!("mob.exs", """
      import Config
      config :mob_dev, ios_bundle_id: "com.mob404.no_such_profile", ios_dist_sign_identity: "none"
      """)

      File.write!("priv/generated/driver_tab_ios.c", "/* stale */\n")

      assert {:error, _} = MobDev.Release.build_ipa()

      tab = File.read!("priv/generated/driver_tab_ios.c")
      refute tab =~ "stale"
      assert tab =~ "_nif_init"
    end
  end
end
