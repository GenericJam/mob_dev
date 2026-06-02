defmodule MobDev.OtpAssetBundleTest do
  use ExUnit.Case, async: true

  alias MobDev.OtpAssetBundle

  describe "default_stripped_prefixes/0" do
    test "includes the high-payoff lib prefixes that no Mob app uses" do
      prefixes = OtpAssetBundle.default_stripped_prefixes()

      # These are the biggest space hogs that no Mob app ever loads.
      # If you remove one of these from the strip list, expect bundle size
      # to balloon — only do it because a specific app actually needs it.
      assert "megaco" in prefixes
      assert "wx" in prefixes
      assert "observer" in prefixes
      assert "debugger" in prefixes
      assert "diameter" in prefixes
    end

    test "does NOT strip prefixes that the BEAM hard-depends on" do
      prefixes = OtpAssetBundle.default_stripped_prefixes()

      # Removing any of these would prevent BEAM from booting.
      # If you find one of them on this list, the OTP zip will be broken.
      refute "kernel" in prefixes
      refute "stdlib" in prefixes
      refute "sasl" in prefixes
      refute "compiler" in prefixes
      refute "crypto" in prefixes
    end
  end

  describe "build/3" do
    test "errors clearly when the source path is not a directory" do
      assert {:error, msg} = OtpAssetBundle.build("/tmp/does-not-exist-xyz", "/tmp/out.zip")
      assert msg =~ "not a directory"
    end

    test "errors clearly when the source has no erts-*/ directory" do
      empty = Path.join(System.tmp_dir!(), "mob_otp_test_empty_#{:rand.uniform(999_999)}")
      File.mkdir_p!(empty)

      try do
        assert {:error, msg} = OtpAssetBundle.build(empty, "/tmp/out.zip")
        assert msg =~ "no erts-"
      after
        File.rm_rf!(empty)
      end
    end

    test "produces a zip with stripped libs removed and remaining tree preserved" do
      source = build_fake_otp_tree()
      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_out_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, info} = OtpAssetBundle.build(source, target_zip)
        assert info.zipped_files > 0
        assert info.zip_size_kb >= 0
        assert File.exists?(target_zip)

        # Verify contents using `unzip -l`
        {listing, 0} = System.cmd("unzip", ["-l", target_zip], stderr_to_stdout: true)

        # Stripped libs are gone
        refute listing =~ "lib/megaco-1.0.0/"
        refute listing =~ "lib/wx-1.0.0/"

        # Kept libs are present
        assert listing =~ "lib/elixir-1.19.0/"
        assert listing =~ "erts-16.0/"

        # Static archive (.a) was deleted
        refute listing =~ "libcrypto.a"

        # erts-*/bin was emptied (the file inside should be gone)
        refute listing =~ "erts-16.0/bin/erl_child_setup"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "slim: false ships the OTP tree untouched (no lib stripping)" do
      source = build_fake_otp_tree()

      target_zip =
        Path.join(System.tmp_dir!(), "mob_otp_test_noslim_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip, slim: false)
        {listing, 0} = System.cmd("unzip", ["-l", target_zip], stderr_to_stdout: true)

        # With slim: false, libs that the default strip would remove survive —
        # required for apps running arbitrary user code (Mix.install) where any
        # OTP lib (inets, ssl, runtime_tools, …) might be needed at runtime.
        assert listing =~ "lib/megaco-1.0.0/"
        assert listing =~ "lib/wx-1.0.0/"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "respects :keep_prefixes — opts can re-add a stripped lib" do
      source = build_fake_otp_tree()
      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_keep_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip, keep_prefixes: ["megaco"])
        {listing, 0} = System.cmd("unzip", ["-l", target_zip], stderr_to_stdout: true)
        assert listing =~ "lib/megaco-1.0.0/"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "respects :strip_extra_prefixes — opts can strip an additional lib" do
      source = build_fake_otp_tree()

      target_zip =
        Path.join(System.tmp_dir!(), "mob_otp_test_extra_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip, strip_extra_prefixes: ["eex"])
        {listing, 0} = System.cmd("unzip", ["-l", target_zip], stderr_to_stdout: true)
        refute listing =~ "lib/eex-1.19.0/"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp build_fake_otp_tree do
    root = Path.join(System.tmp_dir!(), "mob_otp_fake_#{:rand.uniform(999_999)}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    # erts-*/bin (will be stripped)
    File.mkdir_p!(Path.join(root, "erts-16.0/bin"))
    File.write!(Path.join(root, "erts-16.0/bin/erl_child_setup"), "fake binary")

    # erts-*/include (kept — headers)
    File.mkdir_p!(Path.join(root, "erts-16.0/include"))
    File.write!(Path.join(root, "erts-16.0/include/erl_nif.h"), "/* fake */")

    # lib/elixir-* (kept)
    File.mkdir_p!(Path.join(root, "lib/elixir-1.19.0/ebin"))
    File.write!(Path.join(root, "lib/elixir-1.19.0/ebin/elixir.beam"), "fake beam")

    # lib/eex-* (kept by default; one test strips this via opts)
    File.mkdir_p!(Path.join(root, "lib/eex-1.19.0/ebin"))
    File.write!(Path.join(root, "lib/eex-1.19.0/ebin/eex.beam"), "fake beam")

    # lib/megaco-* (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/megaco-1.0.0/ebin"))
    File.write!(Path.join(root, "lib/megaco-1.0.0/ebin/megaco.beam"), "fake")

    # lib/wx-* (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/wx-1.0.0/ebin"))
    File.write!(Path.join(root, "lib/wx-1.0.0/ebin/wx.beam"), "fake")

    # lib/crypto-*/priv/bin (priv/bin file — will be stripped)
    File.mkdir_p!(Path.join(root, "lib/crypto-5.0.0/priv/bin"))
    File.write!(Path.join(root, "lib/crypto-5.0.0/priv/bin/openssl_wrap"), "fake")

    # libcrypto.a static archive (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/crypto-5.0.0/priv/lib"))
    File.write!(Path.join(root, "lib/crypto-5.0.0/priv/lib/libcrypto.a"), "fake archive")

    root
  end
end
