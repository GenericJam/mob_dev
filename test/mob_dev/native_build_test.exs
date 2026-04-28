defmodule MobDev.NativeBuildTest do
  use ExUnit.Case, async: true

  alias MobDev.NativeBuild

  describe "otp_dir_for_abi/3" do
    test "armeabi-v7a returns the arm32 path" do
      assert NativeBuild.otp_dir_for_abi("armeabi-v7a", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm32"
    end

    test "arm64-v8a returns the arm64 path" do
      assert NativeBuild.otp_dir_for_abi("arm64-v8a", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm64"
    end

    test "unknown ABI falls back to arm64" do
      assert NativeBuild.otp_dir_for_abi("x86_64", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm64"
    end

    test "empty ABI string falls back to arm64" do
      assert NativeBuild.otp_dir_for_abi("", "/otp/arm64", "/otp/arm32") == "/otp/arm64"
    end
  end

  describe "filter_serials/2" do
    @serials [
      "ZY22K6BSJM",
      "10.0.0.17:5555",
      "10.0.0.82:5555",
      "emulator-5554",
      "emulator-5556"
    ]

    test "nil returns all serials unchanged" do
      assert NativeBuild.filter_serials(@serials, nil) == @serials
    end

    test "exact serial match" do
      assert NativeBuild.filter_serials(@serials, "ZY22K6BSJM") == ["ZY22K6BSJM"]
    end

    test "matches wifi-adb serial when given bare IP" do
      assert NativeBuild.filter_serials(@serials, "10.0.0.17") == ["10.0.0.17:5555"]
    end

    test "matches wifi-adb serial when given full IP:port" do
      assert NativeBuild.filter_serials(@serials, "10.0.0.17:5555") == ["10.0.0.17:5555"]
    end

    test "matches emulator serial" do
      assert NativeBuild.filter_serials(@serials, "emulator-5554") == ["emulator-5554"]
    end

    test "non-matching id returns empty list" do
      assert NativeBuild.filter_serials(@serials, "NOPE") == []
    end
  end

  describe "read_sdk_dir/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mob_native_build_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "android"))
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project: tmp}
    end

    test "returns {:ok, dir} when sdk.dir is set", %{project: project} do
      File.write!(Path.join([project, "android", "local.properties"]), "sdk.dir=/opt/Android/sdk\n")
      assert {:ok, "/opt/Android/sdk"} = NativeBuild.read_sdk_dir(project)
    end

    test "trims trailing whitespace and resolves ~", %{project: project} do
      home = System.user_home!()

      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=~/Library/Android/sdk   \n"
      )

      assert {:ok, dir} = NativeBuild.read_sdk_dir(project)
      assert dir == Path.expand("~/Library/Android/sdk")
      assert String.starts_with?(dir, home)
    end

    test "returns :error when local.properties is missing", %{project: project} do
      assert :error = NativeBuild.read_sdk_dir(project)
    end

    test "returns :error when local.properties has no sdk.dir line", %{project: project} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "# placeholder\nsome.other=value\n"
      )

      assert :error = NativeBuild.read_sdk_dir(project)
    end
  end

  describe "android_toolchain_available?/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mob_native_build_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "android"))

      sdk_dir = Path.join(tmp, "fake_sdk")
      File.mkdir_p!(sdk_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project: tmp, sdk_dir: sdk_dir}
    end

    test "false when local.properties is missing", %{project: project} do
      refute NativeBuild.android_toolchain_available?(project)
    end

    test "false when sdk.dir points at a missing directory", %{project: project} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=/nonexistent/path/to/sdk\n"
      )

      refute NativeBuild.android_toolchain_available?(project)
    end

    test "true requires adb on PATH plus an existing sdk.dir", %{project: project, sdk_dir: sdk_dir} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=#{sdk_dir}\n"
      )

      expected = System.find_executable("adb") != nil
      assert NativeBuild.android_toolchain_available?(project) == expected
    end
  end

  describe "ios_toolchain_available?/0" do
    test "matches the actual macOS + xcrun status of the host" do
      macos? = match?({:unix, :darwin}, :os.type())
      xcrun? = System.find_executable("xcrun") != nil
      assert NativeBuild.ios_toolchain_available?() == (macos? and xcrun?)
    end
  end
end
