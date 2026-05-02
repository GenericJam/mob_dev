defmodule Mix.Tasks.Mob.RepublishTest do
  use ExUnit.Case, async: true

  # Tests cover the pure version-bump logic. The full task (chaining to
  # mob.release + mob.publish) needs a real iOS toolchain + an App Store
  # Connect API key and is exercised by `mix mob.republish --ios` on a
  # configured machine — out of scope for unit tests.

  alias Mix.Tasks.Mob.Republish

  setup do
    tmp = Path.join(System.tmp_dir!(), "republish_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "bump_ios_build_number!/1" do
    test "bumps an integer CFBundleVersion by 1", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "7")

      assert {"7", "8"} = Republish.bump_ios_build_number!(plist)

      assert read_cfbundle_version!(plist) == "8"
    end

    test "handles starting value of 1 → 2", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "1")

      assert {"1", "2"} = Republish.bump_ios_build_number!(plist)
    end

    test "handles large values (no integer overflow surprises)", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "9999")

      assert {"9999", "10000"} = Republish.bump_ios_build_number!(plist)
    end

    test "is idempotent under re-read — running twice bumps twice", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "5")

      assert {"5", "6"} = Republish.bump_ios_build_number!(plist)
      assert {"6", "7"} = Republish.bump_ios_build_number!(plist)
      assert {"7", "8"} = Republish.bump_ios_build_number!(plist)

      assert read_cfbundle_version!(plist) == "8"
    end

    test "raises with a clear message when CFBundleVersion is a semver string", %{tmp: tmp} do
      # Common user mistake: someone writes "1.0" or "1.0.0" in the
      # build-number slot because they're confusing it with the public
      # version (CFBundleShortVersionString). Apple validators reject
      # these too, but the failure message is opaque — we should error
      # earlier and clearly.
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "1.0.0")

      assert_raise Mix.Error, ~r/expected a bare integer/, fn ->
        Republish.bump_ios_build_number!(plist)
      end
    end

    test "raises when CFBundleVersion has trailing characters", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "7-rc1")

      assert_raise Mix.Error, ~r/expected a bare integer/, fn ->
        Republish.bump_ios_build_number!(plist)
      end
    end

    test "error message points the user at how to fix the plist by hand", %{tmp: tmp} do
      plist = Path.join(tmp, "Info.plist")
      write_minimal_plist!(plist, "1.0")

      try do
        Republish.bump_ios_build_number!(plist)
        flunk("expected the bump to raise on a non-integer CFBundleVersion")
      rescue
        e in Mix.Error ->
          msg = e.message
          # The error must hand the user a copy-pasteable PlistBuddy
          # command — the whole point of a clear error here is that
          # they can recover without finding this guide first.
          assert msg =~ "PlistBuddy"
          assert msg =~ "Set :CFBundleVersion 1"
          assert msg =~ "CFBundleShortVersionString"
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp write_minimal_plist!(path, build_version) do
    File.write!(path, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.example.test</string>
        <key>CFBundleVersion</key>
        <string>#{build_version}</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0.0</string>
    </dict>
    </plist>
    """)
  end

  defp read_cfbundle_version!(path) do
    {raw, 0} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", path])
    String.trim(raw)
  end
end
