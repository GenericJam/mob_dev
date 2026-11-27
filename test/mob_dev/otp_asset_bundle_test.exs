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

    test "never strips an OTP lib the app's .app closure needs, transitively" do
      # The slim-release regression: an app listing :inets failed to start on
      # the device with {:inets, {~c"no such file or directory", ~c"inets.app"}}
      # because inets is in the default strip list.
      source = build_fake_otp_tree()

      write_app(source, "inets", "9.7",
        applications: [:kernel, :stdlib, :runtime_tools],
        included_applications: [:tftp]
      )

      write_app(source, "runtime_tools", "2.4", applications: [:kernel])
      write_app(source, "tftp", "1.3", applications: [:kernel])
      write_app(source, "ftp", "1.2.5", applications: [:kernel])

      target_zip =
        Path.join(System.tmp_dir!(), "mob_otp_test_required_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, info} =
                 OtpAssetBundle.build(source, target_zip, required_apps: ["my_app", "inets"])

        {listing, 0} = System.cmd("unzip", ["-l", target_zip], stderr_to_stdout: true)

        assert listing =~ "lib/inets-9.7/ebin/inets.app"
        assert listing =~ "lib/runtime_tools-2.4/ebin/runtime_tools.app"
        assert listing =~ "lib/tftp-1.3/ebin/tftp.app"
        refute listing =~ "lib/ftp-1.2.5/"
        refute listing =~ "lib/megaco-1.0.0/"
        assert Enum.sort(info.kept_required) == ["inets", "runtime_tools", "tftp"]
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "removes AppleDouble files, which are not BEAMs" do
      source = build_fake_otp_tree()
      File.write!(Path.join(source, "lib/elixir-1.19.0/ebin/._elixir.beam"), "resource fork")
      File.write!(Path.join(source, "lib/elixir-1.19.0/._ebin"), "resource fork")
      File.write!(Path.join(source, "._erts-16.0"), "resource fork")
      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_ad_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip)
        refute zip_listing(target_zip) =~ "._"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "removes sources, headers and docs of erts and libs" do
      source = build_fake_otp_tree()

      for dir <- ~w(erts-16.0/doc erts-16.0/man erts-16.0/src lib/elixir-1.19.0/doc
                    lib/elixir-1.19.0/src lib/elixir-1.19.0/include usr/include) do
        File.mkdir_p!(Path.join(source, dir))
        File.write!(Path.join([source, dir, "file"]), "x")
      end

      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_doc_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip)
        listing = zip_listing(target_zip)
        refute listing =~ ~r{/(doc|man|src|include)/}
        refute listing =~ "usr/include"
        assert listing =~ "erts-16.0/lib/liberts.so"
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "strips Dbgi and Docs from every BEAM, the app's flat dir included, and keeps Attr" do
      source = build_fake_otp_tree()
      File.mkdir_p!(Path.join(source, "my_app"))
      File.write!(Path.join(source, "my_app/my_app_fake.beam"), beam(:my_app_fake))
      assert "Dbgi" in chunk_names(beam(:my_app_fake))
      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_beam_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:ok, _} = OtpAssetBundle.build(source, target_zip)

        for path <- ["lib/elixir-1.19.0/ebin/elixir.beam", "my_app/my_app_fake.beam"] do
          chunks = target_zip |> zip_entry(path) |> chunk_names()
          refute "Dbgi" in chunks
          refute "Docs" in chunks
          assert "Attr" in chunks
          assert "Code" in chunks
        end
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end

    test "fails the build on a .beam it cannot strip" do
      source = build_fake_otp_tree()
      File.write!(Path.join(source, "lib/elixir-1.19.0/ebin/broken.beam"), "not a beam")
      target_zip = Path.join(System.tmp_dir!(), "mob_otp_test_bad_#{:rand.uniform(999_999)}.zip")

      try do
        assert {:error, msg} = OtpAssetBundle.build(source, target_zip)
        assert msg =~ "could not strip 1 BEAM file(s)"
        assert msg =~ "broken.beam"
        refute File.exists?(target_zip)
      after
        File.rm_rf!(source)
        File.rm(target_zip)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp write_app(root, name, vsn, props) do
    ebin = Path.join(root, "lib/#{name}-#{vsn}/ebin")
    File.mkdir_p!(ebin)
    term = {:application, String.to_atom(name), [{:vsn, ~c"#{vsn}"} | props]}
    File.write!(Path.join(ebin, "#{name}.app"), :io_lib.format("~p.~n", [term]))
  end

  # A real BEAM with debug info (a Dbgi chunk) and attributes (Attr).
  defp beam(module) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [f: 0]},
      {:attribute, 1, :behaviour, :gen_server},
      {:function, 1, :f, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
    ]

    {:ok, ^module, binary} =
      :compile.forms(forms, [:debug_info, :binary, :no_spawn_compiler_process])

    binary
  end

  defp chunk_names(binary) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(binary)
    Enum.map(chunks, fn {name, _} -> to_string(name) end)
  end

  defp zip_listing(zip) do
    {listing, 0} = System.cmd("unzip", ["-l", zip], stderr_to_stdout: true)
    listing
  end

  defp zip_entry(zip, path) do
    {:ok, [{_, binary}]} =
      :zip.extract(String.to_charlist(zip), [:memory, file_list: [String.to_charlist(path)]])

    binary
  end

  defp build_fake_otp_tree do
    root = Path.join(System.tmp_dir!(), "mob_otp_fake_#{:rand.uniform(999_999)}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    # erts-*/bin (will be stripped)
    File.mkdir_p!(Path.join(root, "erts-16.0/bin"))
    File.write!(Path.join(root, "erts-16.0/bin/erl_child_setup"), "fake binary")

    # erts-*/include (stripped — headers, build time only)
    File.mkdir_p!(Path.join(root, "erts-16.0/include"))
    File.write!(Path.join(root, "erts-16.0/include/erl_nif.h"), "/* fake */")

    # erts-*/lib (kept): something must stay under erts-* for the zip to have it
    File.mkdir_p!(Path.join(root, "erts-16.0/lib"))
    File.write!(Path.join(root, "erts-16.0/lib/liberts.so"), "fake so")

    # lib/elixir-* (kept)
    File.mkdir_p!(Path.join(root, "lib/elixir-1.19.0/ebin"))
    File.write!(Path.join(root, "lib/elixir-1.19.0/ebin/elixir.beam"), beam(:elixir_fake))

    # lib/eex-* (kept by default; one test strips this via opts)
    File.mkdir_p!(Path.join(root, "lib/eex-1.19.0/ebin"))
    File.write!(Path.join(root, "lib/eex-1.19.0/ebin/eex.beam"), beam(:eex_fake))

    # lib/megaco-* (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/megaco-1.0.0/ebin"))
    File.write!(Path.join(root, "lib/megaco-1.0.0/ebin/megaco.beam"), beam(:megaco_fake))

    # lib/wx-* (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/wx-1.0.0/ebin"))
    File.write!(Path.join(root, "lib/wx-1.0.0/ebin/wx.beam"), beam(:wx_fake))

    # lib/crypto-*/priv/bin (priv/bin file — will be stripped)
    File.mkdir_p!(Path.join(root, "lib/crypto-5.0.0/priv/bin"))
    File.write!(Path.join(root, "lib/crypto-5.0.0/priv/bin/openssl_wrap"), "fake")

    # libcrypto.a static archive (will be stripped)
    File.mkdir_p!(Path.join(root, "lib/crypto-5.0.0/priv/lib"))
    File.write!(Path.join(root, "lib/crypto-5.0.0/priv/lib/libcrypto.a"), "fake archive")

    root
  end
end
