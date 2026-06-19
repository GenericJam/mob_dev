defmodule Mix.Tasks.Mob.Adopt.FinalizeTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # apply_igniter! resets `notices` to [] during simulate_write, so we
  # inspect the un-applied igniter for the emitted notice.
  defp notice(argv) do
    igniter =
      test_project()
      |> Igniter.compose_task("mob.adopt.finalize", argv)

    Enum.join(igniter.notices, "\n")
  end

  describe "mob.adopt.finalize notice" do
    test "LiveView flavour line (default)" do
      text = notice([])

      assert text =~ "boots the host Phoenix on-device (LiveView bridge)"
      refute text =~ "thin-client variant"
    end

    test "thin-client flavour line (--no-live-view)" do
      text = notice(["--no-live-view"])

      assert text =~ "thin-client variant (no on-device Phoenix)"
      refute text =~ "boots the host Phoenix on-device"
    end

    test "default WebView URL line when no --host-url" do
      text = notice([])

      assert text =~ "WebView URL defaults to `http://127.0.0.1:4000/`"
      refute text =~ "config :mob, host_url:` set"
    end

    test "host_url line when --host-url is given" do
      text = notice(["--host-url", "https://my-app.fly.dev/"])

      assert text =~ "WebView URL set to `https://my-app.fly.dev/`"
      refute text =~ "WebView URL defaults to"
    end
  end
end
