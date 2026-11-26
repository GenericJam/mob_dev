defmodule MobDev.ReleaseAndroidTest do
  use ExUnit.Case, async: true

  alias MobDev.ReleaseAndroid

  describe "otp_zip_path/0" do
    # Regression guard: this used to point at the shared `src/main/assets/`
    # source set, which Gradle merges into every build variant. A release
    # build then left `otp.zip` behind where a subsequent debug build would
    # pick it up too — MobBridge.kt's extractOtpIfNeeded() re-extracts it on
    # the next app launch (keyed off PackageInfo.lastUpdateTime, which
    # changes on every reinstall), silently overwriting freshly pushed dev
    # BEAMs with the stale release snapshot. The zip must live under the
    # release-variant asset source set instead, which Gradle never merges
    # into debug builds.
    test "resolves under the release-variant asset source set, not shared main" do
      path = ReleaseAndroid.otp_zip_path()

      assert String.ends_with?(path, "android/app/src/release/assets/otp.zip")
      refute String.contains?(path, "src/main/assets")
    end
  end

  describe "exqlite_ebin!/2" do
    @describetag :tmp_dir

    test "reads exqlite from the given build path, not _build/dev", %{tmp_dir: dir} do
      ebin = Path.join([dir, "_build", "prod", "lib", "exqlite", "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "exqlite.app"), ~s|{application,exqlite,[{vsn,"0.30.1"}]}.|)

      assert {:ok, "0.30.1", ^ebin} =
               ReleaseAndroid.exqlite_ebin!(
                 MapSet.new(["exqlite"]),
                 Path.join([dir, "_build", "prod"])
               )
    end

    test "raises when the app ships exqlite but it is not compiled", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/exqlite is a runtime dependency/, fn ->
        ReleaseAndroid.exqlite_ebin!(MapSet.new(["exqlite"]), Path.join(dir, "_build/prod"))
      end
    end

    test "is :none when the app does not ship exqlite (stale lock entry)", %{tmp_dir: dir} do
      assert :none = ReleaseAndroid.exqlite_ebin!(MapSet.new(["ecto"]), dir)
    end
  end
end
