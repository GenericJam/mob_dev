defmodule Mix.Tasks.Mob.Release.TarballTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mix.Tasks.Mob.Release.Tarball, as: TarballTask

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  describe "argument parsing" do
    test "missing target raises a usage message" do
      assert_raise Mix.Error, ~r/missing target argument/, fn ->
        TarballTask.run([])
      end
    end

    test "unknown target raises with the valid list" do
      assert_raise Mix.Error, ~r/unknown target: bogus.*valid:/s, fn ->
        TarballTask.run(["bogus"])
      end
    end
  end

  describe "happy paths" do
    test "android_arm64 builds the tarball + prints the produced path" do
      {otp_src, exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          hd(argv) == "mktemp" ->
            {:ok, "/tmp/fake-stage\n"}

          hd(argv) == "tar" and "tzf" in argv ->
            {:ok,
             """
             fake-stage/erts-17.0/
             fake-stage/erts-17.0/lib/crypto.a
             fake-stage/erts-17.0/lib/libcrypto.a
             fake-stage/lib/elixir/ebin/elixir.app
             fake-stage/lib/crypto-5.6/priv/lib/crypto.so
             fake-stage/lib/public_key-1.18/ebin/public_key.beam
             fake-stage/lib/ssl-11.4/ebin/ssl.beam
             """}

          true ->
            {:ok, ""}
        end
      end)

      TarballTask.run([
        "android_arm64",
        "--otp-src",
        otp_src,
        "--hash",
        "abc12345",
        "--out-dir",
        "/out",
        "--otp-release",
        "/tmp/otp-android",
        "--openssl-prefix",
        "/tmp/openssl-android-arm64",
        "--exqlite-build",
        exqlite_build
      ])

      File.rm_rf!(otp_src)
    end
  end

  describe "error paths" do
    test "Android target without --exqlite-build raises the precondition message" do
      {otp_src, _exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)

      assert_raise Mix.Error, ~r/exqlite_build required/, fn ->
        TarballTask.run([
          "android_arm64",
          "--otp-src",
          otp_src,
          "--hash",
          "abc12345"
        ])
      end

      File.rm_rf!(otp_src)
    end

    test "missing crypto.so in verify raises with the regex-shaped pattern" do
      {otp_src, exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          hd(argv) == "mktemp" ->
            {:ok, "/tmp/fake-stage\n"}

          hd(argv) == "tar" and "tzf" in argv ->
            # Missing crypto.so — exact silent-shipping bug.
            {:ok,
             """
             stage/erts-17.0/
             stage/erts-17.0/lib/crypto.a
             stage/erts-17.0/lib/libcrypto.a
             stage/lib/elixir/ebin/elixir.app
             stage/lib/public_key-1.18/ebin/public_key.beam
             stage/lib/ssl-11.4/ebin/ssl.beam
             """}

          true ->
            {:ok, ""}
        end
      end)

      assert_raise Mix.Error, ~r/crypto-.*crypto.so/, fn ->
        TarballTask.run([
          "android_arm64",
          "--otp-src",
          otp_src,
          "--hash",
          "abc12345",
          "--exqlite-build",
          exqlite_build
        ])
      end

      File.rm_rf!(otp_src)
    end
  end

  defp mk_tmp_project do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "mob_dev_tarball_task_#{uniq}")

    otp_src = Path.join(base, "otp_src")
    File.mkdir_p!(Path.join(otp_src, "erts"))
    File.write!(Path.join([otp_src, "erts", "vsn.mk"]), "VSN = 17.0\n")
    File.touch!(Path.join(otp_src, "otp_build"))

    project_root = Path.join(base, "project")
    exqlite_build = Path.join([project_root, "_build/dev/lib/exqlite"])
    File.mkdir_p!(Path.join(exqlite_build, "ebin"))
    File.write!(Path.join([exqlite_build, "ebin", "exqlite.app"]), "{vsn, \"0.39.0\"}.")

    File.write!(
      Path.join(project_root, "mix.lock"),
      "%{\"exqlite\": {:hex, :exqlite, \"0.39.0\", \"x\", [:make, :mix], [], \"hexpm\", \"x\"}}"
    )

    {otp_src, exqlite_build}
  end
end
