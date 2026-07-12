defmodule MobDev.NdkVersionTest do
  use ExUnit.Case, async: false
  alias MobDev.NdkVersion

  setup do
    # Make sure no leftover env / app config from another test biases us.
    prev_env = System.get_env("MOB_ANDROID_NDK_VERSION")
    prev_cfg = Application.get_env(:mob_dev, :android_ndk_version)

    System.delete_env("MOB_ANDROID_NDK_VERSION")
    Application.delete_env(:mob_dev, :android_ndk_version)

    on_exit(fn ->
      if prev_env, do: System.put_env("MOB_ANDROID_NDK_VERSION", prev_env)
      if prev_cfg, do: Application.put_env(:mob_dev, :android_ndk_version, prev_cfg)
    end)

    :ok
  end

  describe "recommended/0" do
    test "returns a non-empty version string" do
      v = NdkVersion.recommended()
      assert is_binary(v) and byte_size(v) > 0
      assert v =~ ~r/^\d+\.\d+\.\d+$/, "expected major.minor.patch, got #{inspect(v)}"
    end
  end

  describe "effective/0 + override/0" do
    test "without overrides, returns recommended" do
      assert NdkVersion.override() == :none
      assert NdkVersion.effective() == NdkVersion.recommended()
    end

    test "env var overrides recommended" do
      System.put_env("MOB_ANDROID_NDK_VERSION", "26.1.10909125")

      assert NdkVersion.override() == {:env, "26.1.10909125"}
      assert NdkVersion.effective() == "26.1.10909125"
    end

    test "mob.exs config overrides recommended" do
      Application.put_env(:mob_dev, :android_ndk_version, "25.1.8937393")

      assert NdkVersion.override() == {:mob_exs, "25.1.8937393"}
      assert NdkVersion.effective() == "25.1.8937393"
    end

    test "env var beats mob.exs config" do
      Application.put_env(:mob_dev, :android_ndk_version, "25.1.8937393")
      System.put_env("MOB_ANDROID_NDK_VERSION", "26.1.10909125")

      assert NdkVersion.override() == {:env, "26.1.10909125"}
      assert NdkVersion.effective() == "26.1.10909125"
    end
  end

  describe "installed?/1" do
    test "returns false for a nonexistent version (unless test env happens to have it)" do
      # Pick something obviously not installed.
      refute NdkVersion.installed?("99.99.99999999")
    end

    test "returns false when SDK root missing" do
      original = System.get_env("ANDROID_HOME")
      original_sdk_root = System.get_env("ANDROID_SDK_ROOT")

      System.put_env("ANDROID_HOME", "/nonexistent/sdk/root")
      System.delete_env("ANDROID_SDK_ROOT")

      try do
        refute NdkVersion.installed?(NdkVersion.recommended())
      after
        if original,
          do: System.put_env("ANDROID_HOME", original),
          else: System.delete_env("ANDROID_HOME")

        if original_sdk_root, do: System.put_env("ANDROID_SDK_ROOT", original_sdk_root)
      end
    end
  end

  describe "project_pinned/1" do
    @tag :tmp_dir
    test "extracts ndkVersion from a generated build.gradle", %{tmp_dir: dir} do
      gradle_path = Path.join(dir, "android/app/build.gradle")
      File.mkdir_p!(Path.dirname(gradle_path))

      File.write!(gradle_path, """
      android {
          namespace 'com.example.foo'
          compileSdk 34
          ndkVersion '27.2.12479018'

          defaultConfig {
              applicationId "com.example.foo"
              minSdk 28
          }
      }
      """)

      assert NdkVersion.project_pinned(dir) == "27.2.12479018"
    end

    @tag :tmp_dir
    test "returns nil when ndkVersion not pinned", %{tmp_dir: dir} do
      gradle_path = Path.join(dir, "android/app/build.gradle")
      File.mkdir_p!(Path.dirname(gradle_path))

      File.write!(gradle_path, """
      android {
          namespace 'com.example.foo'
          compileSdk 34

          defaultConfig {
              applicationId "com.example.foo"
              minSdk 28
          }
      }
      """)

      assert NdkVersion.project_pinned(dir) == nil
    end

    @tag :tmp_dir
    test "returns nil for project without android/", %{tmp_dir: dir} do
      assert NdkVersion.project_pinned(dir) == nil
    end

    @tag :tmp_dir
    test "reads from build.gradle.kts as fallback", %{tmp_dir: dir} do
      gradle_path = Path.join(dir, "android/app/build.gradle.kts")
      File.mkdir_p!(Path.dirname(gradle_path))

      File.write!(gradle_path, """
      android {
          ndkVersion = "26.1.10909125"
      }
      """)

      assert NdkVersion.project_pinned(dir) == "26.1.10909125"
    end
  end

  describe "install_command/0" do
    test "produces an sdkmanager invocation referencing the recommended version" do
      cmd = NdkVersion.install_command()
      assert cmd =~ "sdkmanager"
      assert cmd =~ NdkVersion.recommended()
    end
  end

  # The single source of truth cpp_archive / nx_eigen_nif / native_build all use.
  # MOB-89: cpp_archive + nx_eigen_nif used to hardcode ~/Library/Android/sdk,
  # ignoring ANDROID_HOME — so a cpp_archive build failed wherever the NDK lived
  # elsewhere. These pin that root/sysroot/toolchain honor the SDK env.
  describe "root/0 + host/0 + sysroot/0 (shared NDK path — MOB-89)" do
    setup do
      prev_home = System.get_env("ANDROID_HOME")
      prev_root = System.get_env("ANDROID_SDK_ROOT")

      on_exit(fn ->
        restore = fn k, v -> if v, do: System.put_env(k, v), else: System.delete_env(k) end
        restore.("ANDROID_HOME", prev_home)
        restore.("ANDROID_SDK_ROOT", prev_root)
      end)

      :ok
    end

    test "root/0 honors ANDROID_HOME, not a hardcoded ~/Library path" do
      System.delete_env("ANDROID_SDK_ROOT")
      System.put_env("ANDROID_HOME", "/opt/custom-sdk")

      assert NdkVersion.root() == Path.join(["/opt/custom-sdk", "ndk", NdkVersion.effective()])
      refute NdkVersion.root() =~ "Library/Android/sdk"
    end

    test "root/0 falls back to ANDROID_SDK_ROOT when ANDROID_HOME is unset" do
      System.delete_env("ANDROID_HOME")
      System.put_env("ANDROID_SDK_ROOT", "/opt/sdkroot")

      assert NdkVersion.root() =~ "/opt/sdkroot/ndk/"
    end

    test "host/0 is the single NDK prebuilt tag for this OS" do
      assert NdkVersion.host() in ["darwin-x86_64", "linux-x86_64"]
    end

    test "sysroot/0 and toolchain_bin/0 compose root + host" do
      System.delete_env("ANDROID_SDK_ROOT")
      System.put_env("ANDROID_HOME", "/opt/custom-sdk")
      base = Path.join([NdkVersion.root(), "toolchains", "llvm", "prebuilt", NdkVersion.host()])

      assert NdkVersion.sysroot() == Path.join(base, "sysroot")
      assert NdkVersion.toolchain_bin() == Path.join(base, "bin")
    end
  end
end
