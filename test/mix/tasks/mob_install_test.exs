defmodule Mix.Tasks.Mob.InstallTest do
  # async: false — detect_android_sdk/0 tests mutate ANDROID_HOME, which is
  # process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mob.Install
  alias MobDev.OtpDownloader

  # ── replace_prop/3 ────────────────────────────────────────────────────────────

  describe "replace_prop/3" do
    test "replaces a matching key=value line" do
      content = "mob.otp_release=/path/to/placeholder\nmob.mob_dir=/path/to/mob\n"
      result = Install.replace_prop(content, "mob.otp_release", "/new/path")
      assert result =~ "mob.otp_release=/new/path\n"
      refute result =~ "placeholder"
    end

    test "leaves other keys untouched" do
      content = "mob.otp_release=/old\nmob.mob_dir=/my/mob\n"
      result = Install.replace_prop(content, "mob.otp_release", "/new")
      assert result =~ "mob.mob_dir=/my/mob"
    end

    test "is a no-op when value is nil" do
      content = "mob.otp_release=/old\n"
      assert Install.replace_prop(content, "mob.otp_release", nil) == content
    end

    test "replaces mob.otp_release_arm32 independently" do
      content = "mob.otp_release=/arm64\nmob.otp_release_arm32=/placeholder\n"
      result = Install.replace_prop(content, "mob.otp_release_arm32", "/arm32/real")
      assert result =~ "mob.otp_release_arm32=/arm32/real"
      assert result =~ "mob.otp_release=/arm64"
    end
  end

  # ── write_local_properties/2 ─────────────────────────────────────────────────

  describe "write_local_properties/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_install_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "android"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp props_path(dir), do: Path.join([dir, "android", "local.properties"])

    defp write_placeholder_props(dir) do
      File.write!(props_path(dir), """
      mob.otp_release=/path/to/otp-android
      mob.otp_release_arm32=/path/to/otp-android-arm32
      mob.mob_dir=/path/to/mob
      """)
    end

    test "writes arm64 OTP path when placeholder present", %{dir: dir} do
      write_placeholder_props(dir)
      Install.write_local_properties(dir, mob_dir: dir)
      content = File.read!(props_path(dir))
      assert content =~ "mob.otp_release=#{OtpDownloader.android_otp_dir("arm64-v8a")}"
    end

    test "writes arm32 OTP path when placeholder present", %{dir: dir} do
      write_placeholder_props(dir)
      Install.write_local_properties(dir, mob_dir: dir)
      content = File.read!(props_path(dir))
      assert content =~ "mob.otp_release_arm32=#{OtpDownloader.android_otp_dir("armeabi-v7a")}"
    end

    test "arm64 and arm32 paths written are distinct", %{dir: dir} do
      write_placeholder_props(dir)
      Install.write_local_properties(dir, mob_dir: dir)
      content = File.read!(props_path(dir))
      arm64 = OtpDownloader.android_otp_dir("arm64-v8a")
      arm32 = OtpDownloader.android_otp_dir("armeabi-v7a")
      assert content =~ arm64
      assert content =~ arm32
      refute arm64 == arm32
    end

    test "does nothing when local.properties is fully populated", %{dir: dir} do
      # Both Mob paths and sdk.dir already set — write_local_properties should
      # leave it byte-identical.
      original =
        "sdk.dir=/already/set/sdk\nmob.otp_release=/already/set\nmob.mob_dir=/already/set\n"

      File.write!(props_path(dir), original)
      Install.write_local_properties(dir, mob_dir: dir)
      assert File.read!(props_path(dir)) == original
    end

    test "does nothing when local.properties does not exist", %{dir: dir} do
      Install.write_local_properties(dir, mob_dir: dir)
      refute File.exists?(props_path(dir))
    end
  end

  # ── has_active_sdk_dir?/1 ────────────────────────────────────────────────────

  describe "has_active_sdk_dir?/1" do
    test "true for an uncommented sdk.dir= line" do
      assert Install.has_active_sdk_dir?("sdk.dir=/Users/me/Android/sdk\n")
    end

    test "true with leading whitespace" do
      assert Install.has_active_sdk_dir?("   sdk.dir=/path\n")
    end

    test "false for a commented placeholder" do
      refute Install.has_active_sdk_dir?("# sdk.dir=/path/to/android/sdk\n")
    end

    test "false when the line is missing entirely" do
      refute Install.has_active_sdk_dir?("mob.mob_dir=/foo\n")
    end
  end

  # ── ensure_sdk_dir/2 ─────────────────────────────────────────────────────────

  describe "ensure_sdk_dir/2" do
    test "no-op when sdk_path is nil" do
      assert Install.ensure_sdk_dir("mob.mob_dir=/foo\n", nil) == "mob.mob_dir=/foo\n"
    end

    test "replaces a commented placeholder with an active line" do
      input = "# sdk.dir=/path/to/android/sdk\nmob.mob_dir=/foo\n"
      result = Install.ensure_sdk_dir(input, "/Users/me/Android/sdk")
      assert result =~ ~r/^sdk\.dir=\/Users\/me\/Android\/sdk$/m
      refute result =~ "/path/to/android/sdk"
    end

    test "updates an existing active sdk.dir= line" do
      input = "sdk.dir=/old/path\nmob.mob_dir=/foo\n"
      result = Install.ensure_sdk_dir(input, "/new/path")
      assert result =~ "sdk.dir=/new/path"
      refute result =~ "/old/path"
    end

    test "prepends sdk.dir= when neither active nor commented line is present" do
      input = "mob.mob_dir=/foo\n"
      result = Install.ensure_sdk_dir(input, "/Users/me/Android/sdk")
      assert String.starts_with?(result, "sdk.dir=/Users/me/Android/sdk\n")
    end
  end

  # ── detect_android_sdk/0 ──────────────────────────────────────────────────────

  describe "detect_android_sdk/0" do
    test "returns ANDROID_HOME when set and the directory exists" do
      tmp =
        Path.join(System.tmp_dir!(), "mob_sdk_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      original = System.get_env("ANDROID_HOME")
      System.put_env("ANDROID_HOME", tmp)

      try do
        assert Install.detect_android_sdk() == tmp
      after
        if original,
          do: System.put_env("ANDROID_HOME", original),
          else: System.delete_env("ANDROID_HOME")

        File.rm_rf!(tmp)
      end
    end

    test "skips ANDROID_HOME when the directory doesn't exist" do
      original = System.get_env("ANDROID_HOME")
      System.put_env("ANDROID_HOME", "/nonexistent/path/asdfqwerty")

      try do
        # detect_android_sdk falls through to platform defaults; whether they
        # exist on the test host is host-dependent, so just assert we did NOT
        # return the bogus override.
        refute Install.detect_android_sdk() == "/nonexistent/path/asdfqwerty"
      after
        if original,
          do: System.put_env("ANDROID_HOME", original),
          else: System.delete_env("ANDROID_HOME")
      end
    end
  end
end
