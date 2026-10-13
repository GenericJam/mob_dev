defmodule MobDev.DeployerAndroidRelabelTest do
  @moduledoc """
  An Android deploy relabels `otp/` before the `run-as` ERTS probe, not only
  after the last write (MOB-478). After an APK reinstall on a rooted emulator,
  the OTP tree `--native` pushed as root carried the previous install's MCS
  categories; `run-as` couldn't read it, the probe reported ERTS missing, and
  the deploy aborted before its only relabel.

  Runs `Deployer.deploy_all/1` against a fake `adb` on PATH that behaves like
  that device: the probe sees nothing until a `chcon` has run.

  async: false — PATH is process-global.
  """
  use ExUnit.Case, async: false

  alias MobDev.{Deployer, Device}

  @moduletag :tmp_dir

  # The probe's failure output is what the emulator printed on 2026-10-13
  # (Scene3d_arm, android-35 google_apis userdebug): the unreadable erts-*
  # dir doesn't match the glob, so ls is handed the glob itself.
  @fake_adb """
  #!/bin/sh
  set -f
  printf '%s\\n' "$*" >> "$FAKE_ADB_DIR/calls"
  case "$*" in
    *"pm list packages "*) for a; do last=$a; done; echo "package:$last" ;;
    *" root") echo "adbd is already running as root" ;;
    *"id -u") echo 0 ;;
    *chcon*) : > "$FAKE_ADB_DIR/relabeled" ;;
    *"sh -c 'ls "*)
      [ -e "$FAKE_ADB_DIR/relabeled" ] && exit 0
      cmd=$*
      globs=${cmd#*\\'ls }
      for g in ${globs%\\'}; do echo "ls: $g: No such file or directory"; done
      exit 1 ;;
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
    end)

    :ok
  end

  test "a reinstalled app's stale otp/ labels are fixed before the ERTS probe, and again last",
       %{tmp_dir: tmp} do
    emulator = %Device{
      name: "emu",
      serial: "emulator-5620",
      platform: :android,
      type: :emulator
    }

    ExUnit.CaptureIO.capture_io(fn ->
      assert {[_], [], []} =
               Deployer.deploy_all(
                 devices: [emulator],
                 platforms: [:android],
                 restart: false,
                 force_fs: true
               )
    end)

    calls = tmp |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)
    probe = Enum.find_index(calls, &(&1 =~ "sh -c 'ls "))
    assert is_integer(probe), "the run-as ERTS probe never ran"

    assert [first_relabel, last_relabel] =
             for({call, i} <- Enum.with_index(calls), call =~ "chcon", do: i)

    assert first_relabel < probe
    # Nothing written after the final relabel: a root write after it would
    # keep root's categories (the exqlite NIF symlink, P11).
    assert last_relabel == length(calls) - 1
  end
end
