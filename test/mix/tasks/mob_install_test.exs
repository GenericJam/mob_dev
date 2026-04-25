defmodule Mix.Tasks.Mob.InstallTest do
  use ExUnit.Case, async: true

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

    test "does nothing when local.properties has no placeholders", %{dir: dir} do
      original = "mob.otp_release=/already/set\nmob.mob_dir=/already/set\n"
      File.write!(props_path(dir), original)
      Install.write_local_properties(dir, mob_dir: dir)
      assert File.read!(props_path(dir)) == original
    end

    test "does nothing when local.properties does not exist", %{dir: dir} do
      Install.write_local_properties(dir, mob_dir: dir)
      refute File.exists?(props_path(dir))
    end
  end
end
