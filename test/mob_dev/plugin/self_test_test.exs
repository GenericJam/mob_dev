defmodule MobDev.Plugin.SelfTestTest do
  # The "device" is this node: the self-test is spawned here exactly as it
  # would be on a phone, including the exception, exit, kill and timeout paths.
  use ExUnit.Case, async: true

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

  defmodule SkipsWithReason do
    @moduledoc false
    def run(_ctx), do: {:skip, "no camera on this device"}
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

  defmodule Killed do
    @moduledoc false
    def run(_ctx), do: Process.exit(self(), :kill)
  end

  defmodule Hangs do
    @moduledoc false
    def run(_ctx) do
      Process.register(self(), :mob_selftest_hangs)
      Process.sleep(:infinity)
    end
  end

  defmodule OffContract do
    @moduledoc false
    def run(_ctx), do: :ok
  end

  defmodule FailAtom do
    @moduledoc false
    def run(_ctx), do: {:fail, :nope}
  end

  defmodule SkipAtom do
    @moduledoc false
    def run(_ctx), do: {:skip, :no_reason}
  end

  defp plugin(name, module), do: {name, %{name: name, selftest: module}}

  describe "run_all/3" do
    test "maps pass, fail and both skip shapes through unchanged, with the plugin and module" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [
            plugin(:mob_a, Passes),
            plugin(:mob_b, Fails),
            plugin(:mob_c, Skips),
            plugin(:mob_d, SkipsWithReason)
          ]
        )

      assert [
               %{plugin: :mob_a, module: Passes, result: :pass},
               %{plugin: :mob_b, module: Fails, result: {:fail, "status/0 returned :error"}},
               %{plugin: :mob_c, module: Skips, result: {:skip, :needs_hardware}},
               %{plugin: :mob_d, result: {:skip, "no camera on this device"}}
             ] = entries

      assert Enum.all?(entries, &(is_integer(&1.ms) and &1.ms >= 0))
    end

    test "a raise, exit, throw or kill in one self-test is that plugin's failure and the rest still run" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [
            plugin(:mob_raise, Raises),
            plugin(:mob_exit, Exits),
            plugin(:mob_throw, Throws),
            plugin(:mob_kill, Killed),
            plugin(:mob_ok, Passes)
          ]
        )

      assert [
               %{plugin: :mob_raise, result: {:fail, "raised: " <> raised}},
               %{plugin: :mob_exit, result: {:fail, "exited: :shutdown"}},
               %{plugin: :mob_throw, result: {:fail, "threw: :oops"}},
               %{plugin: :mob_kill, result: {:fail, "killed: :killed"}},
               %{plugin: :mob_ok, result: :pass}
             ] = entries

      assert raised =~ "ArgumentError"
      assert raised =~ "nif not loaded"
    end

    test "a self-test that overruns the timeout is killed on the device, fails, and the next one runs" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [plugin(:mob_slow, Hangs), plugin(:mob_ok, Passes)],
          timeout_ms: 50
        )

      assert [
               %{plugin: :mob_slow, result: {:fail, "timed out after 50 ms"}, ms: slow_ms},
               %{plugin: :mob_ok, result: :pass}
             ] = entries

      assert slow_ms >= 50
      assert Process.whereis(:mob_selftest_hangs) == nil
    end

    test "a module not on the device, or a return outside the contract, is a failure" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [
            plugin(:mob_stale, Not.Deployed.SelfTest),
            plugin(:mob_bad, OffContract),
            plugin(:mob_fail_atom, FailAtom),
            plugin(:mob_skip_atom, SkipAtom),
            {:mob_string, %{name: :mob_string, selftest: "MobString.SelfTest"}}
          ]
        )

      assert [
               %{plugin: :mob_stale, result: {:fail, stale}},
               %{plugin: :mob_bad, result: {:fail, bad}},
               %{plugin: :mob_fail_atom, result: {:fail, fail_atom}},
               %{plugin: :mob_skip_atom, result: {:fail, skip_atom}},
               %{plugin: :mob_string, module: nil, result: {:fail, string}}
             ] = entries

      assert stale =~ "Not.Deployed.SelfTest.run/1 is not on the device"
      assert bad =~ "returned :ok, not :pass | {:fail, reason} | {:skip, reason}"
      assert fail_atom =~ "returned {:fail, :nope}, not"
      assert skip_atom =~ "returned {:skip, :no_reason}, not"
      assert string == ~s(selftest is not a module: "MobString.SelfTest")
    end

    test "plugins without a self-test or a manifest are skips, a failed verification is a failure" do
      entries =
        SelfTest.run_all(node(), @ctx,
          plugins: [
            {"/deps/mob_tier0", nil, :unsigned},
            {"/deps/mob_tampered", nil, {:error, :signature_mismatch}},
            {:mob_old, %{name: :mob_old, nifs: []}},
            {"/deps/mob_nameless", %{name: nil, selftest: Passes}},
            plugin(:mob_ok, Passes)
          ]
        )

      assert [
               %{plugin: :mob_tier0, module: nil, result: {:skip, "no manifest (tier-0 plugin)"}},
               %{
                 plugin: :mob_tampered,
                 result: {:fail, "manifest failed verification: :signature_mismatch"}
               },
               %{plugin: :mob_old, module: nil, result: {:skip, "no selftest in manifest"}},
               %{plugin: :mob_nameless, result: :pass},
               %{plugin: :mob_ok, result: :pass}
             ] = entries
    end

    test "waits for the plugins' applications to be started before the first test, then gives up" do
      # :kernel is started; :mob_never_starts is not, so the wait runs out.
      {ms, entries} =
        :timer.tc(
          fn ->
            SelfTest.run_all(node(), @ctx,
              plugins: [
                {:kernel, %{name: :kernel, selftest: Passes}},
                {:mob_never_starts, %{name: :mob_never_starts, selftest: Passes}}
              ],
              boot_timeout_ms: 300
            )
          end,
          :millisecond
        )

      assert [%{plugin: :kernel, result: :pass}, %{plugin: :mob_never_starts, result: :pass}] =
               entries

      assert ms >= 300 and ms < 3_000

      {ms, _} =
        :timer.tc(
          fn ->
            SelfTest.run_all(node(), @ctx,
              plugins: [{:kernel, %{name: :kernel, selftest: Passes}}]
            )
          end,
          :millisecond
        )

      assert ms < 250
    end

    test "an unreachable node is every plugin's failure, not a crash" do
      entries =
        SelfTest.run_all(:"nope@127.0.0.1", @ctx,
          plugins: [plugin(:mob_a, Passes)],
          timeout_ms: 500
        )

      assert [%{plugin: :mob_a, result: {:fail, reason}}] = entries
      assert reason =~ "nope@127.0.0.1"
      assert reason =~ "noconnection"
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
       }, :ok},
      {:mob_whisper,
       %{
         name: :mob_whisper,
         permissions: [%{capability: :speech}],
         android: %{permissions: ["android.permission.RECORD_AUDIO"]}
       }},
      {"/deps/mob_deliver", %{name: :mob_deliver, nifs: []}},
      {"/deps/mob_tier0", nil}
    ]

    test "android emulator: pm grant per declared permission, recording what the device said" do
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

    test "ios simulator: mob_photos' :media capability grants the photos service" do
      cmd = fn "xcrun", ["simctl", "privacy", "UDID-1", "grant", _service, "com.x.app"] ->
        {"", 0}
      end

      device = %Device{platform: :ios, serial: "UDID-1", type: :simulator}
      plugins = [{:mob_photos, %{name: :mob_photos, permissions: [%{capability: :media}]}}]

      assert [%{plugin: :mob_photos, permission: "photos", status: :ok}] =
               SelfTest.grant_permissions(device, plugins, "com.x.app", cmd)
    end

    test "physical devices get nothing granted from the host" do
      cmd = fn _exe, _argv -> flunk("no command expected") end

      for device <- [
            %Device{platform: :ios, serial: "00008030-ABCDEF", type: :physical},
            %Device{platform: :android, serial: "ZY22DP6HFL", type: :physical}
          ] do
        assert SelfTest.grant_permissions(device, @plugins, "com.x.app", cmd) == []
      end
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
