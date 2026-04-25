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
end
