defmodule MobDev.Plugin.V1EnvelopeRefusedTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, SignatureGate, Verify}

  # `priv/` of mob_scanner 0.1.3 exactly as published on Hex
  # (`mix hex.package fetch mob_scanner 0.1.3 --unpack`): a real v1 envelope
  # signed in plugin CI with the shared first-party key.
  @fixture Path.expand("../../fixtures/plugins/mob_scanner_v1", __DIR__)
  @trusted_fp "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
  @hexpm_entry {:hex, :mob_scanner, "0.1.3",
                "20e740fadc1d521c04fdb41052f521ed53cfc17b5bc3cfaa8f8948b28ba96626", [:mix],
                [{:mob, "~> 0.7", [hex: :mob, repo: "hexpm", optional: false]}], "hexpm",
                "86b366d59efc042765378a9bc4c42c4b60ebd917a146a9edb89a857996c85d34"}

  # The plugin sits at <deps>/mob_scanner, and `opts` are the provenance
  # inputs under which the MOB-287 transition accepted it: Mix resolves it
  # through Hex.SCM, mix.lock pins it to hexpm, the directory is the deps
  # checkout, and its key is trusted. Its v1 signature is valid. MOB-301
  # removed the transition, so none of that may get it accepted any more.
  setup do
    root = Path.join(System.tmp_dir!(), "mob_v1_refused_#{System.unique_integer([:positive])}")
    deps_path = Path.join(root, "deps")
    dir = Path.join(deps_path, "mob_scanner")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(@fixture, "priv"), Path.join(dir, "priv"))
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [
      scms: %{mob_scanner: Hex.SCM},
      lock: %{mob_scanner: @hexpm_entry},
      deps_path: deps_path,
      trust_map: %{mob_scanner: @trusted_fp}
    ]

    {:ok, dir: dir, opts: opts}
  end

  test "load_verified refuses a v1 plugin that met every transition condition, unevaluated",
       %{dir: dir, opts: opts} do
    # The prepended side effect leaves the manifest evaluating to the signed
    # map, so the old transition would have run it and accepted the plugin.
    sentinel = Path.join(Path.dirname(dir), "EVALUATED")
    manifest = Path.join(dir, "priv/mob_plugin.exs")
    File.write!(manifest, "File.write!(#{inspect(sentinel)}, \"x\")\n" <> File.read!(manifest))

    assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
    refute File.exists?(sentinel)
  end

  test "the build gate refuses it even when handed the signed manifest", %{dir: dir, opts: opts} do
    {:ok, manifest} = Manifest.load(dir)

    assert {:error, [{:envelope_v1_unsupported, :mob_scanner}]} =
             SignatureGate.check_activated([{dir, manifest}], opts[:trust_map], [])
  end

  test "the build error tells the user to mix deps.update the plugin", %{dir: dir} do
    error =
      assert_raise Mix.Error, fn ->
        SignatureGate.raise_on_signature_drift!([{dir, nil}])
      end

    assert error.message =~ "plugin :mob_scanner ships a legacy v1 signature"

    assert error.message =~
             "Update it to a v2-signed release:\n      mix deps.update mob_scanner\n"

    # A path dependency (the mob_plugin_demo plugins) never changes with
    # deps.update; the message must name re-signing the checkout too.
    assert error.message =~
             "A path dependency\n    (a local checkout) is not changed by deps.update"

    assert error.message =~ "~/.mob/keys/mob_scanner.priv"
  end
end
