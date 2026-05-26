defmodule MobDev.ReleaseAndroidTest do
  use ExUnit.Case, async: true

  alias MobDev.ReleaseAndroid

  describe "real_crypto_available?/1" do
    # Regression guard for the 2026-05-21 Play Console internal-track
    # crash: the Android release pipeline unconditionally replaced
    # crypto.beam with a stub (supports/1 -> []), assuming the OTP build
    # had no OpenSSL NIF. But the Android CMakeLists.txt statically links
    # crypto.a + libcrypto.a and registers crypto_nif_init — so the real
    # :crypto works. The stub broke :ssl.versions/0 and every HTTPS
    # request. The fix gates the stub on the ABSENCE of crypto.a.

    setup do
      otp_dir = Path.join(System.tmp_dir!(), "mob_otp_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(otp_dir) end)
      %{otp_dir: otp_dir}
    end

    test "true when erts-*/lib/crypto.a exists", %{otp_dir: otp_dir} do
      lib = Path.join(otp_dir, "erts-17.0/lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "crypto.a"), "")

      assert ReleaseAndroid.real_crypto_available?(otp_dir)
    end

    test "matches whatever erts version directory is present", %{otp_dir: otp_dir} do
      lib = Path.join(otp_dir, "erts-16.3/lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "crypto.a"), "")

      assert ReleaseAndroid.real_crypto_available?(otp_dir)
    end

    test "false when crypto.a is absent (stub path)", %{otp_dir: otp_dir} do
      File.mkdir_p!(Path.join(otp_dir, "erts-17.0/lib"))

      refute ReleaseAndroid.real_crypto_available?(otp_dir)
    end

    test "false when the OTP dir doesn't exist at all", %{otp_dir: otp_dir} do
      refute ReleaseAndroid.real_crypto_available?(otp_dir)
    end
  end
end
