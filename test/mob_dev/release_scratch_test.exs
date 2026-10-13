defmodule MobDev.ReleaseScratchTest do
  # Runs the scratch prologue of release_device.sh (MOB-425): the build's
  # scratch (objects, the linked binary, the .app, the IPA staging dir) must
  # live under one directory that is gone when the script exits, whether the
  # build succeeds or fails, and a direct run must honour TMPDIR (bare macOS
  # `mktemp -d` ignores it and writes to DARWIN_USER_TEMP_DIR).
  use ExUnit.Case, async: true

  alias MobDev.Release

  @moduletag :tmp_dir

  # The prologue, then what the build does with BUILD_DIR, then `tail`.
  defp run_prologue(env, tail) do
    script = """
    set -e
    #{Release.release_scratch_sh()}
    echo "BUILD_DIR=$BUILD_DIR"
    touch "$BUILD_DIR/MobNode.o"
    mkdir -p "$MOB_RELEASE_SCRATCH/ipa/Payload"
    #{tail}
    """

    {out, status} = System.cmd("bash", ["-c", script], env: env, stderr_to_stdout: true)
    [_, build_dir] = Regex.run(~r/^BUILD_DIR=(.*)$/m, out)
    {status, build_dir}
  end

  describe "a direct run (no MOB_RELEASE_BUILD_DIR)" do
    setup %{tmp_dir: tmp} do
      tmpdir = Path.join(tmp, "TMPDIR")
      File.mkdir_p!(tmpdir)
      {:ok, tmpdir: tmpdir, env: [{"TMPDIR", tmpdir}, {"MOB_RELEASE_BUILD_DIR", nil}]}
    end

    test "puts its scratch under TMPDIR and removes it when the build fails",
         %{tmpdir: tmpdir, env: env} do
      {status, build_dir} = run_prologue(env, "false")

      assert status != 0
      assert String.starts_with?(Path.expand(build_dir), Path.expand(tmpdir))
      assert File.ls!(tmpdir) == []
    end

    test "removes its scratch when the build succeeds", %{tmpdir: tmpdir, env: env} do
      {status, build_dir} = run_prologue(env, "true")

      assert status == 0
      assert String.starts_with?(Path.expand(build_dir), Path.expand(tmpdir))
      assert File.ls!(tmpdir) == []
    end
  end

  test "with MOB_RELEASE_BUILD_DIR, the scratch goes in that directory and nowhere else",
       %{tmp_dir: tmp} do
    given = Path.join(tmp, "given")
    tmpdir = Path.join(tmp, "TMPDIR")
    File.mkdir_p!(given)
    File.mkdir_p!(tmpdir)

    {status, build_dir} =
      run_prologue([{"TMPDIR", tmpdir}, {"MOB_RELEASE_BUILD_DIR", given}], "true")

    assert status == 0
    assert Path.dirname(build_dir) == given
    assert File.exists?(Path.join(build_dir, "MobNode.o"))
    assert File.ls!(tmpdir) == []
  end
end
