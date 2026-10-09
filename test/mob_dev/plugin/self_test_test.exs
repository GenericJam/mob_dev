defmodule MobDev.Plugin.SelfTestTest do
  # The "device" is this node: `:erpc.call/5` to `node()` runs the self-test
  # in a spawned local process exactly as it would on a phone, including the
  # exception, exit and timeout paths. async: false — the crash fixtures log.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MobDev.Device
  alias MobDev.Plugin.SelfTest

  @ctx %{platform: :android, device: :emulator}

  defmodule Passes do
    @moduledoc false
    def run(%{platform: :android}), do: :pass
  end

  defmodule Fails do
    @moduledoc false
    def run(_ctx), do: {:fail, "status/0 returned :error"}
  end

  defmodule Skips do
    @moduledoc false
    def run(%{device: :emulator}), do: {:skip, :needs_hardware}
  end

  defmodule Raises do
    @moduledoc false
    def run(_ctx), do: raise(ArgumentError, "nif not loaded")
  end

  defmodule Exits do
    @moduledoc false
    def run(_ctx), do: exit(:shutdown)
  end

  defmodule Throws do
    @moduledoc false
    def run(_ctx), do: throw(:oops)
  end

  defmodule Hangs do
    @moduledoc false
    def run(_ctx), do: Process.sleep(:infinity)
  end

  defmodule OffContract do
    @moduledoc false
    def run(_ctx), do: :ok
  end

  defp plugin(name, module), do: {name, %{name: name, selftest: module}}

  describe "run_all/3" do
    test "maps pass, fail and skip through unchanged, with the plugin and module" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [plugin(:mob_a, Passes), plugin(:mob_b, Fails), plugin(:mob_c, Skips)]
        )

      assert [
               %{plugin: :mob_a, module: Passes, result: :pass},
               %{plugin: :mob_b, module: Fails, result: {:fail, "status/0 returned :error"}},
               %{plugin: :mob_c, module: Skips, result: {:skip, :needs_hardware}}
             ] = entries

      assert Enum.all?(entries, &(is_integer(&1.ms) and &1.ms >= 0))
    end

    test "a raise, exit or throw in one self-test is that plugin's failure and the rest still run" do
      log =
        capture_log(fn ->
          entries =
            SelfTest.run_all(node(), @ctx,
              plugins: [
                plugin(:mob_raise, Raises),
                plugin(:mob_exit, Exits),
                plugin(:mob_throw, Throws),
                plugin(:mob_ok, Passes)
              ]
            )

          assert [
                   %{plugin: :mob_raise, result: {:fail, "raised: " <> raised}},
                   %{plugin: :mob_exit, result: {:fail, "exited: :shutdown"}},
                   %{plugin: :mob_throw, result: {:fail, "threw: :oops"}},
                   %{plugin: :mob_ok, result: :pass}
                 ] = entries

          assert raised =~ "ArgumentError"
          assert raised =~ "nif not loaded"
          send(self(), :done)
        end)

      assert_received :done
      # The runner's own process survived every crash (the log is the remote one's).
      refute log =~ "runner"
    end

    test "a self-test that overruns the timeout fails with the timeout and does not block the next" do
      {ms, entries} =
        :timer.tc(
          fn ->
            SelfTest.run_all(node(), @ctx,
              plugins: [plugin(:mob_slow, Hangs), plugin(:mob_ok, Passes)],
              timeout_ms: 50
            )
          end,
          :millisecond
        )

      assert [
               %{plugin: :mob_slow, result: {:fail, "timed out after 50 ms"}, ms: slow_ms},
               %{plugin: :mob_ok, result: :pass}
             ] = entries

      assert slow_ms >= 50
      assert ms < 5_000
    end

    test "a module that is not on the device, or a return outside the contract, is a failure" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [plugin(:mob_stale, Not.Deployed.SelfTest), plugin(:mob_bad, OffContract)]
        )

      assert [
               %{plugin: :mob_stale, result: {:fail, stale}},
               %{plugin: :mob_bad, result: {:fail, bad}}
             ] = entries

      assert stale =~ "Not.Deployed.SelfTest.run/1 is not on the device"
      assert bad =~ "returned :ok, not :pass | {:fail, reason} | {:skip, reason}"
    end

    test "plugins without a self-test (or without a manifest) are skips, not absent" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [
            {"/deps/mob_tier0", nil},
            {:mob_old, %{name: :mob_old, nifs: []}},
            plugin(:mob_ok, Passes)
          ]
        )

      assert [
               %{plugin: :mob_tier0, module: nil, result: {:skip, "no manifest (tier-0 plugin)"}},
               %{plugin: :mob_old, module: nil, result: {:skip, "no selftest in manifest"}},
               %{plugin: :mob_ok, result: :pass}
             ] = entries
    end

    test "an unreachable node is every plugin's failure, not a crash" do
      entries =
        SelfTest.run_all(:"nope@127.0.0.1", @ctx,
          plugins: [plugin(:mob_a, Passes)],
          timeout_ms: 500
        )

      assert [%{plugin: :mob_a, result: {:fail, reason}}] = entries
      assert reason =~ "nope@127.0.0.1 is not reachable"
    end

    test "grants the manifests' permissions first when a device is given" do
      test = self()

      cmd = fn exe, argv ->
        send(test, {:cmd, exe, argv})
        {"", 0}
      end

      plugins = [
        {:mob_location,
         %{
           name: :mob_location,
           selftest: Passes,
           android: %{permissions: ["android.permission.ACCESS_FINE_LOCATION"]}
         }}
      ]

      device = %Device{platform: :android, serial: "emulator-5554", type: :emulator}

      assert [%{result: :pass}] =
               SelfTest.run_all(node(), @ctx,
                 plugins: plugins,
                 device: device,
                 bundle_id: "com.example.host",
                 cmd: cmd
               )

      assert_received {:cmd, "adb",
                       [
                         "-s",
                         "emulator-5554",
                         "shell",
                         "pm",
                         "grant",
                         "com.example.host",
                         "android.permission.ACCESS_FINE_LOCATION"
                       ]}
    end
  end

  describe "grant_permissions/4" do
    @plugins [
      {:mob_location,
       %{
         name: :mob_location,
         permissions: [%{capability: :location, ios: %{handler: "x"}}],
         android: %{
           permissions: [
             "android.permission.ACCESS_FINE_LOCATION",
             "android.permission.ACCESS_COARSE_LOCATION"
           ]
         }
       }},
      {:mob_whisper,
       %{
         name: :mob_whisper,
         permissions: [%{capability: :speech}],
         android: %{permissions: ["android.permission.RECORD_AUDIO"]}
       }},
      {"/deps/mob_deliver", %{name: :mob_deliver, nifs: []}},
      {"/deps/mob_tier0", nil}
    ]

    test "android: pm grant per declared permission, recording what the device said" do
      cmd = fn "adb", ["-s", "emulator-5554", "shell", "pm", "grant", "com.x.app", perm] ->
        if perm =~ "COARSE",
          do: {"Operation not allowed: not a changeable permission type", 255},
          else: {"", 0}
      end

      device = %Device{platform: :android, serial: "emulator-5554", type: :emulator}

      assert [
               %{
                 plugin: :mob_location,
                 permission: "android.permission.ACCESS_FINE_LOCATION",
                 status: :ok
               },
               %{
                 plugin: :mob_location,
                 permission: "android.permission.ACCESS_COARSE_LOCATION",
                 status: {:error, "Operation not allowed: not a changeable permission type"}
               },
               %{plugin: :mob_whisper, permission: "android.permission.RECORD_AUDIO", status: :ok}
             ] = SelfTest.grant_permissions(device, @plugins, "com.x.app", cmd)
    end

    test "ios simulator: simctl privacy grant for capabilities that have a service" do
      cmd = fn "xcrun", ["simctl", "privacy", "UDID-1", "grant", _service, "com.x.app"] ->
        {"", 0}
      end

      device = %Device{platform: :ios, serial: "UDID-1", type: :simulator}

      # :speech has no simctl service, so only location is attempted.
      assert [%{plugin: :mob_location, permission: "location", status: :ok}] =
               SelfTest.grant_permissions(device, @plugins, "com.x.app", cmd)
    end

    test "ios physical device: nothing can be granted from the host" do
      cmd = fn _exe, _argv -> flunk("no command expected") end
      device = %Device{platform: :ios, serial: "00008030-ABCDEF", type: :physical}
      assert SelfTest.grant_permissions(device, @plugins, "com.x.app", cmd) == []
    end
  end

  describe "table/1 and summary/1" do
    test "one aligned row per plugin with the outcome and its detail" do
      entries = [
        %{plugin: :mob_location, module: Passes, result: :pass, ms: 12},
        %{
          plugin: :mob_whisper,
          module: Fails,
          result: {:fail, "nif_loaded/0 returned false"},
          ms: 3
        },
        %{plugin: :mob_deliver, module: nil, result: {:skip, "no selftest in manifest"}, ms: 0},
        %{plugin: :mob_camera, module: Skips, result: {:skip, :needs_hardware}, ms: 1}
      ]

      assert SelfTest.table(entries) == [
               "plugin        outcome  ms  detail",
               "mob_location  pass     12",
               "mob_whisper   FAIL     3   nif_loaded/0 returned false",
               "mob_deliver   skip     0   no selftest in manifest",
               "mob_camera    skip     1   needs_hardware"
             ]

      assert SelfTest.summary(entries) == "1 passed, 1 failed, 2 skipped"
      assert [%{plugin: :mob_whisper}] = SelfTest.failures(entries)
    end

    test "an empty run is an empty table body and a zero summary" do
      assert SelfTest.table([]) == ["plugin  outcome  ms  detail"]
      assert SelfTest.summary([]) == "0 passed, 0 failed, 0 skipped"
    end
  end
end
