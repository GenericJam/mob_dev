defmodule MobDev.OtpLibVersionSkewTest do
  @moduledoc """
  The shared OTP root must hold exactly one version of an app (MOB-143).

  It is keyed by OTP hash, not by project, so every app on the machine shares
  one `lib/`. Leaving several versions of a dependency there makes the code
  server resolve `code:lib_dir/1` — and so `code:priv_dir/1`, where `load_nif`
  looks — to the highest one, while the app's own beams come from its lock. The
  result is a `bad_lib` failure at boot whose message talks about database
  credentials.
  """
  use ExUnit.Case, async: true

  alias MobDev.NativeBuild

  setup do
    root = Path.join(System.tmp_dir!(), "mob143_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp seed(root, name) do
    dir = Path.join([root, "lib", name])
    File.mkdir_p!(Path.join(dir, "ebin"))
    File.mkdir_p!(Path.join(dir, "priv"))
    File.write!(Path.join([dir, "priv", "sqlite3_nif.so"]), "stub")
    dir
  end

  defp versions(root, app) do
    Path.wildcard(Path.join(root, "lib/#{app}-*"))
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  test "installing an older version removes the newer one", %{root: root} do
    # The exact shape that broke mob_plugin_demo: another project had installed
    # 0.40.0, this one locks 0.38.0, and the code server picked 0.40.0's priv.
    seed(root, "exqlite-0.40.0")
    seed(root, "exqlite-0.36.0")

    NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    assert versions(root, "exqlite") == ["exqlite-0.38.0"]
  end

  test "the target version survives a re-install", %{root: root} do
    dir = seed(root, "exqlite-0.38.0")
    File.write!(Path.join([dir, "ebin", "marker"]), "x")

    NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    assert versions(root, "exqlite") == ["exqlite-0.38.0"]

    assert File.exists?(Path.join([dir, "ebin", "marker"])),
           "re-installing the same version must not wipe what is already there"
  end

  test "other applications are untouched", %{root: root} do
    seed(root, "exqlite-0.40.0")
    seed(root, "emlx-0.1.0")
    seed(root, "pythonx-0.4.0")

    NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    assert versions(root, "emlx") == ["emlx-0.1.0"]
    assert versions(root, "pythonx") == ["pythonx-0.4.0"]
  end

  test "a prefix collision is not swept", %{root: root} do
    # `exqlite-*` must not match a different app that merely starts with the
    # same letters.
    seed(root, "exqlite_extra-1.0.0")
    seed(root, "exqlite-0.40.0")

    NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    assert versions(root, "exqlite_extra") == ["exqlite_extra-1.0.0"]
  end

  test "the malformed empty-version dir older builds left behind is removed", %{root: root} do
    seed(root, "exqlite-")

    NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    refute File.exists?(Path.join(root, "lib/exqlite-"))
  end

  test "ebin and priv exist afterwards", %{root: root} do
    dir = NativeBuild.prepare_otp_lib_dir!(root, "exqlite", "0.38.0")

    assert File.dir?(Path.join(dir, "ebin"))
    assert File.dir?(Path.join(dir, "priv"))
    assert Path.basename(dir) == "exqlite-0.38.0"
  end
end
