defmodule MobDev.DeployerStaleSslTest do
  @moduledoc """
  A deploy deletes the host ssl BEAMs and crypto shim an older mob_dev left
  in the app's beams dir, which is first on -pa (MOB-493). If that delete
  fails the files keep shadowing the runtime's ssl and crypto, so the deploy
  must fail rather than report success.

  The Android cases run `Deployer.deploy_all/1` against a fake `adb` on PATH
  whose `rm` fails. async: false — PATH is process-global.
  """
  use ExUnit.Case, async: false

  alias MobDev.{Deployer, Device}

  @moduletag :tmp_dir

  # FAKE_ADB_ROOT=no answers `adb root` the way a production phone does, so
  # the deploy takes the run-as path.
  @fake_adb """
  #!/bin/sh
  set -f
  printf '%s\\n' "$*" >> "$FAKE_ADB_DIR/calls"
  case "$*" in
    *"pm list packages "*) for a; do last=$a; done; echo "package:$last" ;;
    *" root")
      if [ "$FAKE_ADB_ROOT" = no ]; then
        echo "adbd cannot run as root in production builds"
      else
        echo "adbd is already running as root"
      fi ;;
    *"id -u") echo 0 ;;
    *"rm -f "*) echo "rm: ssl.beam: Permission denied"; exit 1 ;;
  esac
  exit 0
  """

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    adb = Path.join(bin, "adb")
    File.write!(adb, @fake_adb)
    File.chmod!(adb, 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    System.put_env("FAKE_ADB_DIR", tmp)

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("FAKE_ADB_DIR")
      System.delete_env("FAKE_ADB_ROOT")
    end)

    :ok
  end

  for {label, root} <- [{"rooted", "yes"}, {"run-as", "no"}] do
    test "a failed delete fails the #{label} Android deploy before any BEAM is pushed",
         %{tmp_dir: tmp} do
      System.put_env("FAKE_ADB_ROOT", unquote(root))

      emulator = %Device{
        name: "emu",
        serial: "emulator-5620",
        platform: :android,
        type: :emulator
      }

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[], [failed], _} =
                 Deployer.deploy_all(
                   devices: [emulator],
                   platforms: [:android],
                   restart: false,
                   force_fs: true
                 )

        assert inspect(failed) =~ "removing stale host ssl/crypto BEAMs failed"
      end)

      calls = tmp |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)
      rm = Enum.find_index(calls, &(&1 =~ "rm -f "))
      assert is_integer(rm), "the stale-file delete never ran"
      refute Enum.any?(Enum.drop(calls, rm + 1), &(&1 =~ ~r/ push |tar xf/))
    end
  end

  describe "remove_stale_host_ssl/1 (iOS simulator deploy and native build)" do
    test "files that aren't there are fine", %{tmp_dir: tmp} do
      assert Deployer.remove_stale_host_ssl(tmp) == :ok
    end

    test "a file that can't be deleted is an error naming it", %{tmp_dir: tmp} do
      beams = Path.join(tmp, "beams")
      File.mkdir_p!(beams)
      File.write!(Path.join(beams, "crypto.beam"), "")
      File.chmod!(beams, 0o555)
      on_exit(fn -> File.chmod(beams, 0o755) end)

      assert {:error, message} = Deployer.remove_stale_host_ssl(beams)
      assert message =~ Path.join(beams, "crypto.beam")
    end
  end
end
