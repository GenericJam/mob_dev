defmodule Mix.Tasks.Mob.Release.PublishTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mix.Tasks.Mob.Release.Publish, as: PublishTask

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  describe "argument parsing" do
    test "unexpected positional argument raises usage message" do
      assert_raise Mix.Error, ~r/unexpected positional arguments/, fn ->
        PublishTask.run(["surprise"])
      end
    end
  end

  describe "happy path" do
    test "runs the publish pipeline + prints the produced asset list" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          match?(["gh", "release", "view" | _], argv) and "--json" in argv ->
            {:ok, "otp-android-abc12345.tar.gz\n"}

          match?(["gh", "release", "view" | _], argv) ->
            {:ok, "title: x\n"}

          match?(["gh", "release", "delete-asset" | _], argv) ->
            {:ok, ""}

          match?(["gh", "release", "upload" | _], argv) ->
            {:ok, ""}

          true ->
            {:ok, ""}
        end
      end)

      prev_shell = Mix.shell()
      Mix.shell(Mix.Shell.IO)

      output =
        try do
          ExUnit.CaptureIO.capture_io(fn ->
            PublishTask.run(["--hash", "abc12345", "--out-dir", "/tmp"])
          end)
        after
          Mix.shell(prev_shell)
        end

      assert output =~ "otp-abc12345"
      assert output =~ "GenericJam/mob"
      assert output =~ "otp-android-abc12345.tar.gz"
    end
  end

  describe "error paths" do
    test "no tarballs present → Mix.raise with the precondition hint" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> false end)

      assert_raise Mix.Error, ~r/no tarballs found.*abc12345/s, fn ->
        PublishTask.run(["--hash", "abc12345", "--out-dir", "/tmp"])
      end
    end

    test "gh auth failure → Mix.raise with auth_required formatting" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        {:error, {:cmd_failed, %{cmd: argv, exit: 1, output: "HTTP 401: Bad credentials"}}}
      end)

      assert_raise Mix.Error, ~r/authentication required.*gh auth login/s, fn ->
        PublishTask.run(["--hash", "abc12345", "--out-dir", "/tmp"])
      end
    end

    test "gh infra outage → Mix.raise with infra_unreachable formatting" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        {:error, {:cmd_failed, %{cmd: argv, exit: 1, output: "HTTP 503: Service Unavailable"}}}
      end)

      assert_raise Mix.Error, ~r/external infrastructure unreachable.*503/s, fn ->
        PublishTask.run(["--hash", "abc12345", "--out-dir", "/tmp"])
      end
    end

    test "--assets accepts comma-separated basenames" do
      # Only the otp-ios-sim file exists; user asks for two assets.
      stub(MobDev.Release.ShellMock, :file?, fn path ->
        String.ends_with?(path, "otp-ios-sim-abc12345.tar.gz")
      end)

      assert_raise Mix.Error, ~r/missing tarballs.*otp-android-arm32/s, fn ->
        PublishTask.run([
          "--hash",
          "abc12345",
          "--out-dir",
          "/tmp",
          "--assets",
          "otp-ios-sim,otp-android-arm32"
        ])
      end
    end
  end
end
