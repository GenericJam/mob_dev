defmodule Mix.Tasks.Mob.DeployBeamFlagsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Deploy

  defp native_lock(serials, overrides \\ %{}) do
    serials = Enum.sort(serials)

    target_digest =
      serials
      |> Enum.join(<<0>>)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.merge(
      %{
        bundle_id: MobDev.Config.bundle_id(),
        owner: "0123456789abcdef",
        serials: serials,
        target_digest: target_digest,
        phase: :native_ready,
        state: :held_success
      },
      overrides
    )
  end

  defp payload_plan(serials) do
    %{
      version: 1,
      package: MobDev.Config.bundle_id(),
      serials: Enum.sort(serials),
      attempt_id: "0123456789abcdef"
    }
  end

  defp committed_lock(serials), do: native_lock(serials, %{phase: :final_committed})

  defp committed_result(result, serials), do: {result, committed_lock(serials)}

  defp native_outcome(serials, overrides \\ %{}) do
    Map.merge(
      %{
        ok?: true,
        android_device_disposition: if(serials == [], do: :not_attempted, else: :held),
        android_serials: serials,
        android_deploy_lock: if(serials == [], do: nil, else: native_lock(serials)),
        android_payload_plan: if(serials == [], do: nil, else: payload_plan(serials))
      },
      overrides
    )
  end

  defp successful_finalizer(_lock), do: :ok

  defp physical_ios_device(serial) do
    %MobDev.Device{
      platform: :ios,
      serial: serial,
      type: :physical,
      status: :discovered,
      error: nil
    }
  end

  defp ios_simulator(serial) do
    %MobDev.Device{
      platform: :ios,
      serial: serial,
      type: :simulator,
      status: :booted,
      error: nil
    }
  end

  defp android_device(serial, type \\ :physical) do
    %MobDev.Device{
      platform: :android,
      serial: serial,
      type: type,
      status: :discovered,
      error: nil
    }
  end

  defp no_device_match_pattern do
    Regex.compile!("No device matched.*mix mob\\.devices", "s")
  end

  describe "resolve_target_platforms!/4" do
    test "rejects a CoreDevice-shaped identifier with the default platform list" do
      hardware_udid = "00008110-001E1C3A34F8401E"
      core_device_id = "11111111-2222-3333-4444-555555555555"
      target = physical_ios_device(hardware_udid)

      error =
        assert_raise Mix.Error, fn ->
          Deploy.resolve_target_platforms!(
            [:android, :ios],
            core_device_id,
            fn -> [android_device("emulator-5554", :emulator)] end,
            fn -> [target] end
          )
        end

      assert error.message ==
               ~s(No device matched "#{core_device_id}". Run `mix mob.devices` to see available device IDs.)
    end

    test "rejects an arbitrary unknown identifier with the default platform list" do
      android = android_device("ZY22CRLMWK")
      ios = physical_ios_device("00008110-001E1C3A34F8401E")

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          "not-a-device",
          fn -> [android] end,
          fn -> [ios] end
        )
      end
    end

    test "rejects an explicit selection when discovery is empty" do
      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!([:android, :ios], "not-a-device", fn -> [] end, fn ->
          []
        end)
      end
    end

    test "does not infer a CoreDevice identifier across multiple physical devices" do
      devices = [
        physical_ios_device("00008110-001E1C3A34F8401E"),
        physical_ios_device("00008120-001A2B3C4D5E6F78")
      ]

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          "11111111-2222-3333-4444-555555555555",
          fn -> [] end,
          fn -> devices end
        )
      end
    end

    test "accepts the exact hardware UDID among multiple physical devices" do
      hardware_udid = "00008110-001E1C3A34F8401E"

      devices = [
        physical_ios_device(hardware_udid),
        physical_ios_device("00008120-001A2B3C4D5E6F78")
      ]

      assert Deploy.resolve_target_platforms!(
               [:android, :ios],
               hardware_udid,
               fn -> [] end,
               fn -> devices end
             ) ==
               [:ios]
    end

    test "accepts documented Android device identifiers" do
      for {id, device} <- [
            {"ZY22CRLMWK", android_device("ZY22CRLMWK")},
            {"emulator-5554", android_device("emulator-5554", :emulator)},
            {"10.0.0.17", android_device("10.0.0.17:5555")},
            {"10.0.0.17:5555", android_device("10.0.0.17:5555")}
          ] do
        assert Deploy.resolve_target_platforms!(
                 [:android, :ios],
                 id,
                 fn -> [device] end,
                 fn -> [] end
               ) == [:android]
      end
    end

    test "rejects identifiers that contradict an explicit platform" do
      hardware_udid = "00008110-001E1C3A34F8401E"
      ios = physical_ios_device(hardware_udid)
      android = android_device("ZY22CRLMWK")

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android],
          hardware_udid,
          fn -> [android] end,
          fn -> [ios] end
        )
      end

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:ios],
          android.serial,
          fn -> [android] end,
          fn -> [ios] end
        )
      end
    end

    test "fails closed when the same identifier appears in both inventories" do
      id = "shared-id"

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          id,
          fn -> [android_device(id)] end,
          fn -> [physical_ios_device(id)] end
        )
      end
    end

    test "fails closed on case-insensitive Android serial collisions" do
      id = "r5cw3089hvb"

      devices = [
        android_device("R5CW3089HVB"),
        android_device("r5cw3089hvb")
      ]

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          id,
          fn -> devices end,
          fn -> [] end
        )
      end
    end

    test "fails closed when a bare IP matches multiple WiFi ADB serials" do
      id = "10.0.0.17"

      devices = [
        android_device("10.0.0.17:5555"),
        android_device("10.0.0.17:4444")
      ]

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          id,
          fn -> devices end,
          fn -> [] end
        )
      end
    end

    test "fails closed on iOS simulator display-ID collisions" do
      id = "12345678"

      devices = [
        ios_simulator("12345678-ABCD-1234-ABCD-1234567890AB"),
        ios_simulator("12345678-EF01-5678-EF01-1234567890AB")
      ]

      assert_raise Mix.Error, no_device_match_pattern(), fn ->
        Deploy.resolve_target_platforms!(
          [:android, :ios],
          id,
          fn -> [] end,
          fn -> devices end
        )
      end
    end
  end

  describe "run/2 explicit device preflight" do
    test "rejects invalid native-ready recovery intent before discovery or orchestration" do
      parent = self()

      callbacks = [
        android_lister: fn -> send(parent, :android_discovery_called) end,
        ios_lister: fn -> send(parent, :ios_discovery_called) end,
        orchestrator: fn _opts, _platforms, _device_id ->
          send(parent, :orchestration_called)
        end
      ]

      invalid_args = [
        ["--resume-native-ready", "--android", "--device", "serial-a"],
        ["--resume-native-ready", "--native", "--device", "serial-a"],
        ["--resume-native-ready", "--native", "--android"],
        [
          "--resume-native-ready",
          "--native",
          "--android",
          "--device",
          "serial-a",
          "--no-restart"
        ]
      ]

      for args <- invalid_args do
        assert_raise Mix.Error,
                     "--resume-native-ready requires --native --android --device <exact-id> and restart",
                     fn -> Deploy.run(args, callbacks) end
      end

      refute_received :android_discovery_called
      refute_received :ios_discovery_called
      refute_received :orchestration_called
    end

    test "passes only constrained recovery intent to orchestration after exact discovery" do
      parent = self()
      id = "serial-a"

      callbacks = [
        android_lister: fn -> [android_device(id)] end,
        ios_lister: fn -> [] end,
        orchestrator: fn opts, platforms, device_id ->
          send(parent, {:recovery_orchestration, opts, platforms, device_id})
          :orchestrated
        end
      ]

      assert Deploy.run(
               ["--resume-native-ready", "--native", "--android", "--device", id],
               callbacks
             ) == :orchestrated

      assert_received {:recovery_orchestration, opts, [:android], ^id}
      assert opts[:resume_native_ready]
      assert opts[:native]
      refute Keyword.has_key?(opts, :recovery_proof)
    end

    test "does not enter orchestration for unmatched, mismatched, or ambiguous IDs" do
      parent = self()
      android = android_device("emulator-5554", :emulator)
      ios = physical_ios_device("00008110-001E1C3A34F8401E")

      cases = [
        {["--android", "--ios"], "11111111-2222-3333-4444-555555555555", [android], [ios]},
        {["--android", "--ios"], "not-a-device", [android], [ios]},
        {["--android"], ios.serial, [android], [ios]},
        {["--android", "--ios"], "r5cw3089hvb",
         [android_device("R5CW3089HVB"), android_device("r5cw3089hvb")], []},
        {["--android", "--ios"], "10.0.0.17",
         [android_device("10.0.0.17:5555"), android_device("10.0.0.17:4444")], []},
        {["--android", "--ios"], "12345678", [],
         [
           ios_simulator("12345678-ABCD-1234-ABCD-1234567890AB"),
           ios_simulator("12345678-EF01-5678-EF01-1234567890AB")
         ]}
      ]

      for {platform_args, id, android_devices, ios_devices} <- cases do
        ref = make_ref()

        callbacks = [
          android_lister: fn -> android_devices end,
          ios_lister: fn -> ios_devices end,
          orchestrator: fn _opts, _platforms, _device_id ->
            send(parent, {ref, :orchestration_called})
          end
        ]

        assert_raise Mix.Error, no_device_match_pattern(), fn ->
          Deploy.run(platform_args ++ ["--native", "--device", id], callbacks)
        end

        # The production orchestrator owns flag/config writes, compatibility,
        # dependency fetching, compilation, native build/install, and deploy.
        refute_received {^ref, :orchestration_called}
      end
    end

    test "enters the injected orchestrator after an authoritative match" do
      parent = self()
      id = "emulator-5554"

      callbacks = [
        android_lister: fn -> [android_device(id, :emulator)] end,
        ios_lister: fn -> [] end,
        orchestrator: fn opts, platforms, device_id ->
          send(parent, {:orchestration_called, opts, platforms, device_id})
          :orchestrated
        end
      ]

      assert Deploy.run(["--android", "--ios", "--native", "--device", id], callbacks) ==
               :orchestrated

      assert_received {:orchestration_called, opts, [:android], ^id}
      assert opts[:native]
    end

    test "enters the injected orchestrator for WiFi ADB selectors" do
      parent = self()

      cases = [
        {"10.0.0.17", [android_device("10.0.0.17:5555")]},
        {"10.0.0.17:5555", [android_device("10.0.0.17:5555"), android_device("10.0.0.17:4444")]}
      ]

      for {id, devices} <- cases do
        ref = make_ref()

        callbacks = [
          android_lister: fn -> devices end,
          ios_lister: fn -> [] end,
          orchestrator: fn opts, platforms, device_id ->
            send(parent, {ref, :orchestration_called, opts, platforms, device_id})
            :orchestrated
          end
        ]

        assert Deploy.run(["--android", "--ios", "--native", "--device", id], callbacks) ==
                 :orchestrated

        assert_received {^ref, :orchestration_called, opts, [:android], ^id}
        assert opts[:native]
      end
    end
  end

  describe "with_android_native_host_lock/3" do
    test "ordinary native Android deploy excludes a concurrent recovery operation" do
      bundle = MobDev.Config.bundle_id()

      assert :ordinary_complete =
               Deploy.with_android_native_host_lock(true, [:android], fn ->
                 assert {:error, :recovery_host_lock_unavailable} =
                          Task.async(fn ->
                            MobDev.AndroidDeployRecoveryProof.with_host_lock(bundle, fn ->
                              :unexpected_recovery
                            end)
                          end)
                          |> Task.await()

                 :ordinary_complete
               end)
    end

    test "non-native and iOS-only operations do not claim the Android host lock" do
      operation = fn -> :unlocked end
      assert Deploy.with_android_native_host_lock(false, [:android], operation) == :unlocked
      assert Deploy.with_android_native_host_lock(true, [:ios], operation) == :unlocked
    end
  end

  # ── combine_beam_flags/2 ──────────────────────────────────────────────────────

  describe "combine_beam_flags/2" do
    test "nil/nil returns nil (read cached value from mob.exs)" do
      assert Deploy.combine_beam_flags(nil, nil) == nil
    end

    test "schedulers only" do
      assert Deploy.combine_beam_flags(2, nil) == "-S 2:2"
    end

    test "schedulers 0 means BEAM auto-detect (one per core)" do
      assert Deploy.combine_beam_flags(0, nil) == "-S 0:0"
    end

    test "schedulers 1 pins to single scheduler" do
      assert Deploy.combine_beam_flags(1, nil) == "-S 1:1"
    end

    test "flags string only" do
      assert Deploy.combine_beam_flags(nil, "-sbwt none") == "-sbwt none"
    end

    test "trims whitespace from flags string" do
      assert Deploy.combine_beam_flags(nil, "  -sbwt none  ") == "-sbwt none"
    end

    test "schedulers + flags combined" do
      assert Deploy.combine_beam_flags(4, "-A 4") == "-S 4:4 -A 4"
    end

    test "schedulers + flags trims the flags string" do
      assert Deploy.combine_beam_flags(2, "  -A 2  ") == "-S 2:2 -A 2"
    end
  end

  # ── update_beam_flags_in_config/2 ────────────────────────────────────────────

  describe "update_beam_flags_in_config/2" do
    test "appends beam_flags line when key is absent" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 2:2")
      assert updated =~ ~s(config :mob_dev, beam_flags: "-S 2:2")
      assert updated =~ ~r/mob_dir:/
    end

    test "replaces existing beam_flags value" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob",
        beam_flags: "-S 1:1"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 4:4")
      assert updated =~ ~s(beam_flags: "-S 4:4")
      refute updated =~ "-S 1:1"
    end

    test "replace preserves other keys on surrounding lines" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob",
        beam_flags: "-S 1:1",
        elixir_lib: "/path/to/elixir"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 0:0")
      assert updated =~ ~r/mob_dir:/
      assert updated =~ ~r/elixir_lib:/
      assert updated =~ ~s(beam_flags: "-S 0:0")
      refute updated =~ "-S 1:1"
    end

    test "does not create a duplicate beam_flags key on repeated calls" do
      content = """
      import Config

      config :mob_dev,
        beam_flags: "-S 1:1"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 2:2")
      count = updated |> String.split("beam_flags:") |> length() |> Kernel.-(1)
      assert count == 1
    end

    test "flags value is properly quoted with inspect/1" do
      updated = Deploy.update_beam_flags_in_config("config :mob_dev,\n  x: 1\n", "-S 2:2 -A 4")
      assert updated =~ ~s(beam_flags: "-S 2:2 -A 4")
    end
  end

  # ── format_summary/4 — deploy report rendering ────────────────────────────────
  #
  # Pin the report shape against regressions. Original bug: devices
  # without the app installed were tallied as "Failed on N device(s)"
  # in red. The fix introduced a separate "Skipped on N device(s)"
  # bucket; these tests assert that the three categories render
  # distinctly, that skipped never bleeds into failed (or vice-versa),
  # and that the empty-everything case still emits the right hint.

  describe "format_summary/4" do
    defp device(name, error \\ nil),
      do: %MobDev.Device{name: name, serial: name, platform: :android, error: error}

    defp strip_ansi(line), do: String.replace(line, ~r/\e\[[0-9;]*m/, "")

    test "all three buckets empty → 'No devices found' hint" do
      lines = Deploy.format_summary([], [], [])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "No devices found."
      assert joined =~ "mix mob.devices"
      refute joined =~ "Deployed"
      refute joined =~ "Skipped"
      refute joined =~ "Failed"
    end

    test "only deployed → green deployed header + restart hint when :restart true" do
      lines = Deploy.format_summary([device("iPhone")], [], [], restart: true)

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Apps restarted"
      assert joined =~ "mix mob.connect"
      refute joined =~ "Skipped"
      refute joined =~ "Failed"
    end

    test "only deployed with :restart false → nl(MyModule) hint" do
      lines = Deploy.format_summary([device("iPhone")], [], [], restart: false)
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "BEAMs pushed"
      assert joined =~ "nl(MyModule)"
      refute joined =~ "Apps restarted"
    end

    test "only skipped → yellow informational, NOT counted as failed" do
      # Regression: this case used to print "Failed on 1 device(s)" in red.
      skip = device("emulator-5554", "com.example not installed on emulator-5554")
      lines = Deploy.format_summary([], [], [skip])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Skipped on 1 device(s)"
      assert joined =~ "app not installed"
      assert joined =~ "build for that platform with --android / --ios"
      refute joined =~ "Failed on", "skipped must NOT trigger the Failed header"
    end

    test "only failed → red Failed header with x markers per device" do
      lines = Deploy.format_summary([], [device("buggy", "push timed out")], [])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Failed on 1 device(s)"
      assert joined =~ "✗ buggy: push timed out"
      refute joined =~ "Skipped"
    end

    test "mixed: deployed + skipped + failed all render in distinct blocks" do
      ok = device("iPhone")
      skip = device("emulator-5554", "not installed")
      fail = device("emulator-5556", "adb push failed: broken pipe")

      lines = Deploy.format_summary([ok], [fail], [skip])
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Skipped on 1 device(s)"
      assert joined =~ "Failed on 1 device(s)"
      assert joined =~ "✗ emulator-5556"
      # Skipped row uses the — marker, not ✗ — pin that distinction.
      assert joined =~ "— emulator-5554: not installed"
    end

    test "5-androids-skipped scenario from the original bug report" do
      # The flow that surfaced this: `mix mob.deploy --native` auto-
      # detected iPhone, built iOS only, swept BEAM push to all
      # connected devices. Five Androids didn't have the app and
      # showed up as failures.
      iphone = device("iPhone")
      androids = for i <- 1..5, do: device("emulator-#{i}", "not installed (ABI mismatch)")

      lines = Deploy.format_summary([iphone], [], androids)
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Skipped on 5 device(s)"
      refute joined =~ "Failed", "Bug fix: 5 not-installed devices must NOT count as failed"
    end
  end

  describe "execute_native_deploy!/6" do
    test "mixed native work commits and releases Android before building or mutating iOS" do
      {:ok, events} = Agent.start_link(fn -> [] end)
      serial = "serial-a"
      ios_id = "00000000-0000000000000000"
      ios_target = physical_ios_device(ios_id)

      record = fn event -> Agent.update(events, &(&1 ++ [event])) end

      builder = fn opts ->
        record.({:build, opts})

        case opts[:platforms] do
          [:android] -> native_outcome([serial])
          [:ios] -> native_outcome([])
        end
      end

      deployer = fn opts ->
        record.({:deploy, opts})

        case opts[:platforms] do
          [:android] ->
            committed_result(
              {[
                 %MobDev.Device{platform: :android, serial: serial, status: :connected}
               ], [], []},
              [serial]
            )

          [:ios] ->
            {[ios_target], [], []}
        end
      end

      finalizer = fn lock ->
        record.({:release, lock})
        :ok
      end

      cleanup = fn plan ->
        record.({:cleanup, plan})
        :ok
      end

      assert {deployed, [], []} =
               Deploy.execute_native_deploy!(
                 [:android, :ios],
                 nil,
                 ios_id,
                 [
                   slim: false,
                   android_preinstall: fn _context -> :unused end,
                   android_preinstall_cleanup: fn _plan -> :unused end
                 ],
                 [
                   restart: true,
                   force_fs: true,
                   ios_lister: fn -> [ios_target] end
                 ],
                 builder: builder,
                 deployer: deployer,
                 finalizer: finalizer,
                 cleanup: cleanup
               )

      assert Enum.map(deployed, &{&1.platform, &1.serial}) == [
               {:android, serial},
               {:ios, ios_id}
             ]

      assert [
               {:build, android_build_opts},
               {:deploy, android_deploy_opts},
               {:release, released_lock},
               {:cleanup, cleaned_plan},
               {:build, ios_build_opts},
               {:deploy, ios_deploy_opts}
             ] = Agent.get(events, & &1)

      assert %{
               platforms: [:android],
               device: nil,
               device_phase: true,
               preinstall_arity: {:arity, 1},
               deploy_platforms: [:android],
               deploy_device: nil,
               has_ios_device?: false
             } == %{
               platforms: android_build_opts[:platforms],
               device: android_build_opts[:device],
               device_phase: android_build_opts[:android_device_phase],
               preinstall_arity: Function.info(android_build_opts[:android_preinstall], :arity),
               deploy_platforms: android_deploy_opts[:platforms],
               deploy_device: android_deploy_opts[:device],
               has_ios_device?: Keyword.has_key?(android_deploy_opts, :ios_device)
             }

      assert released_lock == committed_lock([serial])
      assert cleaned_plan == payload_plan([serial])

      assert %{
               build_platforms: [:ios],
               build_device: ios_id,
               device_phase: false,
               has_preinstall?: false,
               has_preinstall_cleanup?: false,
               deploy_platforms: [:ios],
               deploy_ios_device: ios_id,
               deploy_device: nil,
               has_android_serials?: false,
               has_android_lock?: false,
               has_android_payload?: false
             } == %{
               build_platforms: ios_build_opts[:platforms],
               build_device: ios_build_opts[:device],
               device_phase: ios_build_opts[:android_device_phase],
               has_preinstall?: Keyword.has_key?(ios_build_opts, :android_preinstall),
               has_preinstall_cleanup?:
                 Keyword.has_key?(ios_build_opts, :android_preinstall_cleanup),
               deploy_platforms: ios_deploy_opts[:platforms],
               deploy_ios_device: ios_deploy_opts[:ios_device],
               deploy_device: ios_deploy_opts[:device],
               has_android_serials?:
                 Keyword.has_key?(ios_deploy_opts, :canonical_android_serials),
               has_android_lock?: Keyword.has_key?(ios_deploy_opts, :android_deploy_lock),
               has_android_payload?: Keyword.has_key?(ios_deploy_opts, :android_payload_plan)
             }
    end

    test "cleanup errors and exceptions turn Android non-green before every iOS callback" do
      events = start_supervised!({Agent, fn -> [] end})
      serial = "serial-a"

      for cleanup_failure <- [:error, :raise] do
        Agent.update(events, fn _events -> [] end)
        record = fn event -> Agent.update(events, &(&1 ++ [event])) end

        builder = fn opts ->
          record.({:build, opts[:platforms]})
          native_outcome([serial])
        end

        deployer = fn opts ->
          record.({:deploy, opts[:platforms]})

          committed_result(
            {[
               %MobDev.Device{platform: :android, serial: serial, status: :connected}
             ], [], []},
            [serial]
          )
        end

        finalizer = fn lock ->
          record.({:release, lock.phase})
          :ok
        end

        cleanup = fn plan ->
          record.({:cleanup, plan.attempt_id})

          case cleanup_failure do
            :error -> {:error, :injected_cleanup_failure}
            :raise -> raise "injected cleanup failure"
          end
        end

        assert {[], [%MobDev.Device{serial: ^serial, status: :error} = failure], []} =
                 Deploy.execute_native_deploy!(
                   [:android, :ios],
                   nil,
                   "ios-device",
                   [],
                   [restart: true],
                   builder: builder,
                   deployer: deployer,
                   finalizer: finalizer,
                   cleanup: cleanup
                 )

        assert failure.error == "Native Android payload cleanup failed"

        assert Agent.get(events, & &1) == [
                 {:build, [:android]},
                 {:deploy, [:android]},
                 {:release, :final_committed},
                 {:cleanup, "0123456789abcdef"}
               ]
      end
    end

    test "a malformed cleanup result makes an Android-only deploy non-green exactly once" do
      parent = self()
      serial = "serial-a"

      builder = fn _opts -> native_outcome([serial]) end

      deployer = fn _opts ->
        committed_result(
          {[
             %MobDev.Device{platform: :android, serial: serial, status: :connected}
           ], [], []},
          [serial]
        )
      end

      cleanup = fn plan ->
        send(parent, {:cleanup, plan.attempt_id})
        :malformed_cleanup_reply
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.execute_native_deploy!(
                 [:android],
                 nil,
                 nil,
                 [],
                 [restart: true],
                 builder: builder,
                 deployer: deployer,
                 finalizer: &successful_finalizer/1,
                 cleanup: cleanup
               )

      assert_received {:cleanup, "0123456789abcdef"}
      refute_received {:cleanup, _attempt_id}
    end

    test "Android failures and exceptions clean once without masking the primary failure" do
      parent = self()
      serial = "serial-a"
      builder = fn _opts -> native_outcome([serial]) end

      failed_deployer = fn _opts ->
        {
          {[],
           [
             %MobDev.Device{
               platform: :android,
               serial: serial,
               status: :error,
               error: "primary Android failure"
             }
           ], []},
          native_lock([serial], %{state: :retained_failure})
        }
      end

      failed_cleanup = fn plan ->
        send(parent, {:failed_cleanup, plan.attempt_id})
        {:error, :secondary_cleanup_failure}
      end

      assert {[], [%MobDev.Device{error: "primary Android failure"}], []} =
               Deploy.execute_native_deploy!(
                 [:android, :ios],
                 nil,
                 "ios-device",
                 [],
                 [restart: true],
                 builder: builder,
                 deployer: failed_deployer,
                 finalizer: fn _lock -> flunk("failed Android must not release") end,
                 cleanup: failed_cleanup
               )

      assert_received {:failed_cleanup, "0123456789abcdef"}
      refute_received {:failed_cleanup, _attempt_id}

      raising_deployer = fn _opts -> raise "primary deploy exception" end

      raising_cleanup = fn plan ->
        send(parent, {:raising_cleanup, plan.attempt_id})
        raise "secondary cleanup exception"
      end

      assert_raise RuntimeError, "primary deploy exception", fn ->
        Deploy.execute_native_deploy!(
          [:android, :ios],
          nil,
          "ios-device",
          [],
          [restart: true],
          builder: builder,
          deployer: raising_deployer,
          finalizer: fn _lock -> flunk("raising Android must not release") end,
          cleanup: raising_cleanup
        )
      end

      assert_received {:raising_cleanup, "0123456789abcdef"}
      refute_received {:raising_cleanup, _attempt_id}
    end

    test "an uncommitted Android result suppresses every iOS callback" do
      parent = self()
      serial = "serial-a"

      builder = fn opts ->
        send(parent, {:build, opts[:platforms]})
        native_outcome([serial])
      end

      deployer = fn opts ->
        send(parent, {:deploy, opts[:platforms]})

        {
          {[],
           [
             %MobDev.Device{
               platform: :android,
               serial: serial,
               status: :error,
               error: "injected failure"
             }
           ], []},
          native_lock([serial], %{state: :retained_failure})
        }
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.execute_native_deploy!(
                 [:android, :ios],
                 nil,
                 "ios-device",
                 [],
                 [restart: true],
                 builder: builder,
                 deployer: deployer,
                 finalizer: fn _lock -> flunk("uncommitted lease must not release") end,
                 cleanup: fn _plan -> :ok end
               )

      assert_received {:build, [:android]}
      assert_received {:deploy, [:android]}
      refute_received {:build, [:ios]}
      refute_received {:deploy, [:ios]}
    end

    test "an explicitly not-attempted Android phase permits the independent iOS lane" do
      {:ok, events} = Agent.start_link(fn -> [] end)
      ios_id = "ios-device"
      ios_target = physical_ios_device(ios_id)

      builder = fn opts ->
        Agent.update(events, &(&1 ++ [{:build, opts[:platforms]}]))

        case opts[:platforms] do
          [:android] ->
            %{
              ok?: false,
              android_device_disposition: :not_attempted,
              android_serials: [],
              android_deploy_lock: nil,
              android_payload_plan: nil
            }

          [:ios] ->
            native_outcome([])
        end
      end

      deployer = fn opts ->
        Agent.update(events, &(&1 ++ [{:deploy, opts[:platforms]}]))

        {[ios_target], [], []}
      end

      assert {[%MobDev.Device{platform: :ios, serial: ^ios_id}], [], []} =
               Deploy.execute_native_deploy!(
                 [:android, :ios],
                 nil,
                 ios_id,
                 [],
                 [restart: true, ios_lister: fn -> [ios_target] end],
                 builder: builder,
                 deployer: deployer,
                 finalizer: fn _lock -> flunk("no Android authority exists to release") end,
                 cleanup: fn _plan -> :ok end
               )

      assert Agent.get(events, & &1) == [
               {:build, [:android]},
               {:build, [:ios]},
               {:deploy, [:ios]}
             ]
    end

    test "iOS target selection is frozen before the native builder runs" do
      parent = self()
      full_id = "78354490-EF38-44D7-A437-DD941C20524D"
      target = ios_simulator(full_id)

      lister = fn ->
        send(parent, :original_ios_lister_called)
        [target]
      end

      builder = fn opts ->
        send(parent, {:builder_called, opts})
        native_outcome([])
      end

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        assert opts[:ios_lister].() == [target]
        {[target], [], []}
      end

      assert {[^target], [], []} =
               Deploy.execute_native_deploy!(
                 [:ios],
                 nil,
                 "78354490",
                 [],
                 [restart: true, ios_lister: lister],
                 builder: builder,
                 deployer: deployer,
                 finalizer: fn _lock -> flunk("iOS must not release Android state") end,
                 cleanup: fn _plan -> flunk("iOS must not clean Android state") end
               )

      assert_received :original_ios_lister_called
      refute_received :original_ios_lister_called

      assert_received {:builder_called, builder_opts}
      assert builder_opts[:device] == full_id
      assert builder_opts[:platforms] == [:ios]

      assert_received {:deployer_called, deployer_opts}
      assert deployer_opts[:ios_device] == full_id
      assert deployer_opts[:device] == nil
    end

    test "ambiguous iOS target selection fails before native build or deploy mutation" do
      parent = self()

      first = ios_simulator("78354490-EF38-44D7-A437-DD941C20524D")
      second = ios_simulator("78354490-A111-4D7A-B222-DD941C20524D")

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.execute_native_deploy!(
            [:ios],
            nil,
            "78354490",
            [],
            [restart: true, ios_lister: fn -> [first, second] end],
            builder: fn _opts -> send(parent, :builder_called) end,
            deployer: fn _opts -> send(parent, :deployer_called) end,
            finalizer: fn _lock -> send(parent, :finalizer_called) end,
            cleanup: fn _plan -> send(parent, :cleanup_called) end
          )
        end)
      end

      refute_received :builder_called
      refute_received :deployer_called
      refute_received :finalizer_called
      refute_received :cleanup_called
    end
  end

  describe "deploy_after_native_build!/4" do
    test "aggregate native failure raises before the final Deployer pass" do
      parent = self()

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        {[], [], []}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            %{ok?: false, android_serials: []},
            [device: "serial-a"],
            deployer
          )
        end)
      end

      refute_received {:deployer_called, _}
    end

    test "missing native result also fails closed before the final Deployer pass" do
      parent = self()

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        {[], [], []}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(true, nil, [device: "serial-a"], deployer)
        end)
      end

      refute_received {:deployer_called, _}
    end

    test "changing discovery snapshot cannot widen the canonical Android allowlist" do
      parent = self()
      discovered_after_build = ["serial-a", "serial-b", "late-device"]

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        deployed =
          discovered_after_build
          |> Enum.filter(&(&1 in opts[:canonical_android_serials]))
          |> Enum.map(&%MobDev.Device{serial: &1, platform: :android, status: :connected})

        committed_result({deployed, [], []}, ["serial-a", "serial-b"])
      end

      assert {deployed, [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome(["serial-a", "serial-b"]),
                 [platforms: [:android], device: nil, restart: true],
                 deployer,
                 &successful_finalizer/1,
                 fn _plan -> :ok end
               )

      assert Enum.map(deployed, & &1.serial) == ["serial-a", "serial-b"]

      assert_receive {:deployer_called, android_opts}
      assert android_opts[:platforms] == [:android]
      assert android_opts[:canonical_android_serials] == ["serial-a", "serial-b"]
      refute Keyword.has_key?(android_opts, :device)
      assert android_opts[:restart]

      refute_received {:deployer_called, _}
    end

    test "unsorted implicit ADB discovery stays canonical through held outcome and release" do
      parent = self()

      runner = fn "adb", ["devices"] ->
        {"List of devices attached\nserial-b\tdevice\nserial-a\tdevice\n", 0}
      end

      assert {:ok, ["serial-a", "serial-b"] = serials} =
               MobDev.NativeBuild.resolve_android_update_targets(nil, runner)

      native_outcome =
        MobDev.NativeBuild.build_outcome([
          {:ok, "Android",
           %{
             serials: serials,
             deploy_lock: native_lock(serials),
             payload_plan: payload_plan(serials)
           }}
        ])

      assert native_outcome.android_device_disposition == :held
      assert native_outcome.android_serials == serials

      deployer = fn opts ->
        send(parent, {:canonical_serials, opts[:canonical_android_serials]})

        devices =
          Enum.map(opts[:canonical_android_serials], fn serial ->
            %MobDev.Device{platform: :android, serial: serial, status: :connected}
          end)

        committed_result({devices, [], []}, serials)
      end

      finalizer = fn lock ->
        send(parent, {:released_serials, lock.serials})
        :ok
      end

      assert {deployed, [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome,
                 [platforms: [:android], restart: true],
                 deployer,
                 finalizer,
                 fn _plan -> :ok end
               )

      assert Enum.map(deployed, & &1.serial) == serials
      assert_received {:canonical_serials, ^serials}
      assert_received {:released_serials, ^serials}
    end

    test "canonical WiFi serial replaces the user alias in the final Android pass" do
      parent = self()

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        serials = opts[:canonical_android_serials]

        committed_result(
          {[
             %MobDev.Device{
               serial: hd(serials),
               platform: :android,
               status: :connected
             }
           ], [], []},
          serials
        )
      end

      assert {[%MobDev.Device{serial: "10.0.0.17:5555"}], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome(["10.0.0.17:5555"]),
                 [platforms: [:android], device: "10.0.0.17"],
                 deployer,
                 &successful_finalizer/1,
                 fn _plan -> :ok end
               )

      assert_receive {:deployer_called, opts}
      assert opts[:platforms] == [:android]
      assert opts[:canonical_android_serials] == ["10.0.0.17:5555"]
      refute Keyword.has_key?(opts, :device)

      refute_received {:deployer_called, _}
    end

    test "canonical native Android skip or missing result becomes a failure" do
      skipped = %MobDev.Device{
        serial: "serial-a",
        platform: :android,
        status: :skipped,
        error: "app absent"
      }

      for result <- [{[], [], [skipped]}, {[], [], []}] do
        deployer = fn _opts -> result end

        assert {[], [%MobDev.Device{serial: "serial-a", status: :error} = failed], []} =
                 Deploy.deploy_after_native_build!(
                   true,
                   native_outcome(["serial-a"]),
                   [platforms: [:android]],
                   deployer,
                   &successful_finalizer/1
                 )

        assert failed.error =~ "Native Android target"
      end
    end

    test "canonical native Android rejects duplicate, wrong-platform, and extra results" do
      canonical = %MobDev.Device{serial: "serial-a", platform: :android, status: :connected}
      duplicate = %{canonical | name: "duplicate"}
      wrong_platform = %MobDev.Device{serial: "serial-a", platform: :ios, status: :connected}
      extra = %MobDev.Device{serial: "serial-b", platform: :android, status: :connected}

      for result <- [
            {[canonical, duplicate], [], []},
            {[wrong_platform], [], []},
            {[canonical, extra], [], []}
          ] do
        deployer = fn _opts -> result end

        {_deployed, failed, []} =
          Deploy.deploy_after_native_build!(
            true,
            native_outcome(["serial-a"]),
            [platforms: [:android]],
            deployer,
            &successful_finalizer/1
          )

        assert failed != []
        assert Enum.all?(failed, &(&1.status == :error))
      end
    end

    test "malformed callback bucket members become accounted failures without release" do
      parent = self()
      serial = "serial-a"

      deployer = fn _opts -> {{[:not_a_device], [], []}, committed_lock([serial])} end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [platforms: [:android], restart: true],
                 deployer,
                 finalizer,
                 fn _plan -> :ok end
               )

      refute_received :finalizer_called
    end

    test "improper Android result buckets become accounted failures without release or iOS" do
      parent = self()
      serial = "serial-a"

      deployed = %MobDev.Device{
        platform: :android,
        serial: serial,
        status: :connected,
        error: nil
      }

      failed = %{deployed | status: :error, error: "reported target error"}
      skipped = %{deployed | status: :skipped, error: "reported target skip"}

      improper_results = [
        {:deployed, {[deployed | :malformed_tail], [], []}},
        {:failed, {[], [failed | :malformed_tail], []}},
        {:skipped, {[], [], [skipped | :malformed_tail]}}
      ]

      Enum.each(improper_results, fn {bucket, result} ->
        Enum.each([:plain, :wrapped], fn shape ->
          attempt = make_ref()

          deployer = fn opts ->
            case opts[:platforms] do
              [:android] ->
                send(parent, {attempt, :android_deployed, bucket, shape})

                if shape == :wrapped,
                  do: {result, committed_lock([serial])},
                  else: result

              [:ios] ->
                send(parent, {attempt, :ios_deployed})
                {[], [], []}
            end
          end

          finalizer = fn lock ->
            send(parent, {attempt, :released, lock})
            :ok
          end

          cleanup = fn plan ->
            send(parent, {attempt, :cleaned, plan})
            :ok
          end

          assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
                   Deploy.deploy_after_native_build!(
                     true,
                     native_outcome([serial]),
                     [platforms: [:android, :ios], restart: true, ios_device: "ios-device"],
                     deployer,
                     finalizer,
                     cleanup
                   )

          assert_receive {^attempt, :android_deployed, ^bucket, ^shape}
          refute_receive {^attempt, :released, _lock}
          refute_receive {^attempt, :ios_deployed}
          assert_receive {^attempt, :cleaned, cleaned_plan}
          assert cleaned_plan == payload_plan([serial])
          refute_receive {^attempt, :cleaned, _plan}
        end)
      end)
    end

    test "an error-status device in the deployed bucket cannot release or start iOS" do
      parent = self()
      serial = "serial-a"

      deployer = fn opts ->
        case opts[:platforms] do
          [:android] ->
            committed_result(
              {[
                 %MobDev.Device{
                   serial: serial,
                   platform: :android,
                   status: :error,
                   error: "injected failure"
                 }
               ], [], []},
              [serial]
            )

          [:ios] ->
            send(parent, :ios_deployed)
            {[], [], []}
        end
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [platforms: [:android, :ios], restart: true],
                 deployer,
                 finalizer,
                 fn _plan -> :ok end
               )

      refute_received :finalizer_called
      refute_received :ios_deployed
    end

    test "authoritative Android deployed statuses release the exact held lease" do
      parent = self()
      serial = "serial-a"

      for status <- [:discovered, :connected, :tunneled] do
        attempt = make_ref()

        deployer = fn _opts ->
          committed_result(
            {[
               %MobDev.Device{
                 serial: serial,
                 platform: :android,
                 status: status,
                 error: nil
               }
             ], [], []},
            [serial]
          )
        end

        finalizer = fn lock ->
          send(parent, {attempt, :released, lock})
          :ok
        end

        cleanup = fn plan ->
          send(parent, {attempt, :cleaned, plan})
          :ok
        end

        assert {[%MobDev.Device{serial: ^serial, status: ^status, error: nil}], [], []} =
                 Deploy.deploy_after_native_build!(
                   true,
                   native_outcome([serial]),
                   [platforms: [:android], restart: true],
                   deployer,
                   finalizer,
                   cleanup
                 )

        assert_receive {^attempt, :released, released_lock}
        assert released_lock == committed_lock([serial])
        assert_receive {^attempt, :cleaned, cleaned_plan}
        assert cleaned_plan == payload_plan([serial])
        refute_receive {^attempt, _, _}
      end
    end

    test "malformed Android deployed statuses fail closed before release or iOS" do
      parent = self()
      serial = "serial-a"

      invalid_results = [
        %{status: nil, error: nil},
        %{status: :unauthorized, error: nil},
        %{status: :arbitrary_success, error: nil},
        %{status: :error, error: "reported target error"},
        %{status: :skipped, error: "reported target skip"},
        %{status: :connected, error: "stale error on a success status"}
      ]

      Enum.each(invalid_results, fn invalid ->
        attempt = make_ref()

        deployer = fn opts ->
          case opts[:platforms] do
            [:android] ->
              committed_result(
                {[
                   %MobDev.Device{
                     serial: serial,
                     platform: :android,
                     status: invalid.status,
                     error: invalid.error
                   }
                 ], [], []},
                [serial]
              )

            [:ios] ->
              send(parent, {attempt, :ios_deployed})
              {[], [], []}
          end
        end

        finalizer = fn lock ->
          send(parent, {attempt, :released, lock})
          :ok
        end

        cleanup = fn plan ->
          send(parent, {attempt, :cleaned, plan})
          :ok
        end

        assert {[], [%MobDev.Device{serial: ^serial, status: :error} = failed], []} =
                 Deploy.deploy_after_native_build!(
                   true,
                   native_outcome([serial]),
                   [platforms: [:android, :ios], restart: true],
                   deployer,
                   finalizer,
                   cleanup
                 )

        assert failed.error =~ "Native Android target"
        refute_receive {^attempt, :released, _lock}
        refute_receive {^attempt, :ios_deployed}
        assert_receive {^attempt, :cleaned, cleaned_plan}
        assert cleaned_plan == payload_plan([serial])
        refute_receive {^attempt, :cleaned, _plan}
      end)
    end

    test "a partial Android set failure reports no target deployed before commit" do
      parent = self()
      serials = ["serial-a", "serial-b"]

      deployer = fn opts ->
        case opts[:platforms] do
          [:android] ->
            {
              {[
                 %MobDev.Device{
                   serial: "serial-a",
                   platform: :android,
                   status: :connected
                 }
               ],
               [
                 %MobDev.Device{
                   serial: "serial-b",
                   platform: :android,
                   status: :error,
                   error: "injected target failure"
                 }
               ], []},
              native_lock(serials, %{state: :retained_failure})
            }

          [:ios] ->
            send(parent, :ios_deployed)
            {[], [], []}
        end
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      assert {[], failed, []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome(serials),
                 [platforms: [:android, :ios], restart: true],
                 deployer,
                 finalizer,
                 fn _plan -> :ok end
               )

      assert Enum.map(failed, & &1.serial) == serials
      assert Enum.all?(failed, &(&1.status == :error))
      refute_received :finalizer_called
      refute_received :ios_deployed
    end

    test "native Android requires an exact held lease before the final pass" do
      parent = self()

      deployer = fn _opts ->
        send(parent, :deployer_called)
        {[], [], []}
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      invalid_outcomes = [
        native_outcome(["serial-a"], %{android_device_disposition: :failed}),
        native_outcome(["serial-a"], %{android_device_disposition: :retained}),
        native_outcome(["serial-a"], %{android_device_disposition: :artifact_only}),
        native_outcome(["serial-a"]) |> Map.delete(:android_device_disposition),
        native_outcome(["serial-a"], %{android_deploy_lock: nil}),
        native_outcome(["serial-a"], %{android_payload_plan: nil}),
        native_outcome(["serial-a"], %{
          android_deploy_lock: native_lock(["serial-b"])
        }),
        native_outcome(["serial-a"], %{
          android_deploy_lock: native_lock(["serial-a"], %{state: :retained_failure})
        }),
        native_outcome(["serial-a"], %{
          android_deploy_lock: native_lock(["serial-a"], %{phase: :acquired})
        }),
        native_outcome(["serial-a"], %{
          android_deploy_lock:
            native_lock(["serial-a"], %{target_digest: String.duplicate("0", 64)})
        }),
        native_outcome(["serial-a"], %{
          android_deploy_lock: native_lock(["serial-a"], %{owner: "bad"})
        }),
        native_outcome([], %{android_device_disposition: :held})
      ]

      for outcome <- invalid_outcomes do
        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              outcome,
              [platforms: [:android]],
              deployer,
              finalizer
            )
          end)
        end
      end

      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "a forged partial-update disposition uses the generic fail-closed path" do
      parent = self()
      serials = ["serial-a"]

      forged = %{
        ok?: false,
        android_device_disposition: :partial_update,
        android_serials: serials,
        android_deploy_lock: native_lock(serials),
        android_payload_plan: nil
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, "Native build failed", fn ->
            Deploy.deploy_after_native_build!(
              true,
              forged,
              [platforms: [:android]],
              fn _opts -> send(parent, :deployer_called) end,
              fn _lock -> send(parent, :finalizer_called) end
            )
          end
        end)

      refute output =~ "APK update completed before runtime delivery failed"
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "a retained partial-update lease for another bundle uses the generic fail-closed path" do
      parent = self()
      serials = ["serial-a"]

      cross_bundle = %{
        ok?: false,
        android_device_disposition: :partial_update,
        android_serials: serials,
        android_deploy_lock:
          native_lock(serials, %{
            bundle_id: "com.other.app",
            phase: :acquired,
            state: :retained_failure
          }),
        android_payload_plan: nil
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, "Native build failed", fn ->
            Deploy.deploy_after_native_build!(
              true,
              cross_bundle,
              [platforms: [:android]],
              fn _opts -> send(parent, :deployer_called) end,
              fn _lock -> send(parent, :finalizer_called) end
            )
          end
        end)

      refute output =~ "APK update completed before runtime delivery failed"
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "a retained partial-update outcome in an iOS-only deploy uses the generic fail-closed path" do
      parent = self()
      serials = ["serial-a"]

      outcome = %{
        ok?: false,
        android_device_disposition: :partial_update,
        android_serials: serials,
        android_deploy_lock: native_lock(serials, %{phase: :acquired, state: :retained_failure}),
        android_payload_plan: nil
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, "Native build failed", fn ->
            Deploy.deploy_after_native_build!(
              true,
              outcome,
              [platforms: [:ios]],
              fn _opts -> send(parent, :deployer_called) end,
              fn _lock -> send(parent, :finalizer_called) end
            )
          end
        end)

      refute output =~ "APK update completed before runtime delivery failed"
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "a partial Android update fails closed with recovery guidance" do
      parent = self()
      serials = ["serial-a"]
      retained = native_lock(serials, %{phase: :acquired, state: :retained_ambiguous})

      outcome = %{
        ok?: false,
        android_device_disposition: :partial_update,
        android_serials: serials,
        android_deploy_lock: retained,
        android_payload_plan: nil
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, "Android native deploy partially applied", fn ->
            Deploy.deploy_after_native_build!(
              true,
              outcome,
              [platforms: [:android]],
              fn _opts -> send(parent, :deployer_called) end,
              fn _lock -> send(parent, :finalizer_called) end
            )
          end
        end)

      assert output =~ "APK update completed before runtime delivery failed"
      assert output =~ "mix mob.deploy_lock --device <exact-serial>"
      assert output =~ "Do not retry blindly, uninstall, or clear app data"
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "native Android releases only after every canonical final result succeeds" do
      parent = self()
      serial = "serial-a"

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        committed_result(
          {[
             %MobDev.Device{serial: serial, platform: :android, status: :connected}
           ], [], []},
          [serial]
        )
      end

      finalizer = fn lock ->
        send(parent, {:finalizer_called, lock})
        :ok
      end

      cleanup = fn plan ->
        send(parent, {:payload_cleaned, plan})
        :ok
      end

      assert {[%MobDev.Device{serial: ^serial}], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [platforms: [:android], restart: true],
                 deployer,
                 finalizer,
                 cleanup
               )

      assert_receive {:deployer_called, deploy_opts}
      assert deploy_opts[:android_deploy_lock] == native_lock([serial])
      assert deploy_opts[:android_payload_plan] == payload_plan([serial])
      assert_receive {:finalizer_called, lock}
      assert lock == committed_lock([serial])
      assert_receive {:payload_cleaned, plan}
      assert plan == payload_plan([serial])
      refute_received {:payload_cleaned, _}
    end

    test "a successful device result cannot release the original native-ready lease" do
      parent = self()
      serial = "serial-a"

      deployer = fn _opts ->
        {
          {[
             %MobDev.Device{serial: serial, platform: :android, status: :connected}
           ], [], []},
          native_lock([serial])
        }
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      cleanup = fn _plan ->
        send(parent, :payload_cleaned)
        :ok
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [platforms: [:android], restart: true],
                 deployer,
                 finalizer,
                 cleanup
               )

      refute_received :finalizer_called
      assert_receive :payload_cleaned
      refute_received :payload_cleaned
    end

    test "ambiguous Android lease release fails and stops the later iOS pass" do
      parent = self()
      serial = "serial-a"

      deployer = fn opts ->
        case opts[:platforms] do
          [:android] ->
            send(parent, :android_deployed)

            committed_result(
              {[
                 %MobDev.Device{serial: serial, platform: :android, status: :connected}
               ], [], []},
              [serial]
            )

          [:ios] ->
            send(parent, :ios_deployed)
            {[], [], []}
        end
      end

      finalizer = fn lock ->
        send(parent, :release_attempted)
        {:error, "ambiguous", %{lock | state: :release_ambiguous}}
      end

      cleanup = fn plan ->
        send(parent, {:payload_cleaned, plan})
        :ok
      end

      assert {[], [%MobDev.Device{serial: ^serial, status: :error}], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [platforms: [:android, :ios], restart: true],
                 deployer,
                 finalizer,
                 cleanup
               )

      assert_receive :android_deployed
      assert_receive :release_attempted
      assert_receive {:payload_cleaned, _plan}
      refute_received {:payload_cleaned, _}
      refute_received :ios_deployed
    end

    test "the task cleans the staged payload exactly once on validation and callback failures" do
      parent = self()
      outcome = native_outcome(["serial-a"])

      cleanup = fn plan ->
        send(parent, {:payload_cleaned, plan})
        :ok
      end

      never_deploy = fn _opts ->
        send(parent, :deployer_called)
        {{[], [], []}, nil}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            outcome,
            %{},
            never_deploy,
            &successful_finalizer/1,
            cleanup
          )
        end)
      end

      assert_receive {:payload_cleaned, plan}
      assert plan == payload_plan(["serial-a"])
      refute_received {:payload_cleaned, _}
      refute_received :deployer_called

      raising_deployer = fn _opts -> raise "injected deploy failure" end

      assert_raise RuntimeError, "injected deploy failure", fn ->
        Deploy.deploy_after_native_build!(
          true,
          outcome,
          [platforms: [:android], restart: true],
          raising_deployer,
          &successful_finalizer/1,
          cleanup
        )
      end

      assert_receive {:payload_cleaned, ^plan}
      refute_received {:payload_cleaned, _}

      malformed_outcome = %{ok?: true, android_payload_plan: plan}

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            malformed_outcome,
            [platforms: [:android]],
            never_deploy,
            &successful_finalizer/1,
            cleanup
          )
        end)
      end

      assert_receive {:payload_cleaned, ^plan}
      refute_received {:payload_cleaned, _}
      refute_received :deployer_called
    end

    test "an improper Android serial list cleans the held payload once and fails closed" do
      parent = self()
      plan = payload_plan(["serial-a"])

      outcome =
        ["serial-a"]
        |> native_outcome()
        |> Map.put(:android_serials, ["serial-a" | :malformed_tail])

      cleanup = fn received_plan ->
        send(parent, {:payload_cleaned, received_plan})
        raise "secondary cleanup failure"
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            outcome,
            [platforms: [:android, :ios], restart: true],
            fn _opts -> send(parent, :deployer_called) end,
            fn _lock -> send(parent, :finalizer_called) end,
            cleanup
          )
        end)
      end

      assert_receive {:payload_cleaned, ^plan}
      refute_received {:payload_cleaned, _}
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "an improper platform list cleans the held payload once and fails closed" do
      parent = self()
      outcome = native_outcome(["serial-a"])
      plan = payload_plan(["serial-a"])

      cleanup = fn received_plan ->
        send(parent, {:payload_cleaned, received_plan})
        {:error, :secondary_cleanup_failure}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            outcome,
            [platforms: [:android | :malformed_tail], restart: true],
            fn _opts -> send(parent, :deployer_called) end,
            fn _lock -> send(parent, :finalizer_called) end,
            cleanup
          )
        end)
      end

      assert_receive {:payload_cleaned, ^plan}
      refute_received {:payload_cleaned, _}
      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "an untrusted payload shape cannot mask the primary native-build failure" do
      parent = self()

      cleanup = fn _plan ->
        send(parent, :cleanup_called)
        :ok
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        Deploy.deploy_after_native_build!(
          true,
          native_outcome(["serial-a"], %{android_payload_plan: :forged}),
          [platforms: [:android], restart: true],
          fn _opts -> flunk("deployer must not run") end,
          fn _lock -> flunk("finalizer must not run") end,
          cleanup
        )
      end

      refute_received :cleanup_called
    end

    test "invalid or duplicated native platforms fail before any callback" do
      parent = self()

      deployer = fn _opts ->
        send(parent, :deployer_called)
        {[], [], []}
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      for platforms <- [[], [:android, :android], [:android, :other], "android"] do
        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              native_outcome(["serial-a"]),
              [platforms: platforms],
              deployer,
              finalizer
            )
          end)
        end
      end

      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "malformed native deploy options and restart values fail before any callback" do
      parent = self()

      deployer = fn _opts ->
        send(parent, :deployer_called)
        {[], [], []}
      end

      finalizer = fn _lock ->
        send(parent, :finalizer_called)
        :ok
      end

      for deploy_opts <- [
            %{},
            [platforms: [:android], restart: nil],
            [platforms: [:android], restart: "true"],
            [platforms: [:android], restart: 1]
          ] do
        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              native_outcome(["serial-a"]),
              deploy_opts,
              deployer,
              finalizer
            )
          end)
        end
      end

      refute_received :deployer_called
      refute_received :finalizer_called
    end

    test "the remaining iOS pass receives no Android lease metadata" do
      parent = self()
      serial = "serial-a"
      ios_id = "ios-device"
      ios_target = physical_ios_device(ios_id)

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        case opts[:platforms] do
          [:android] ->
            committed_result(
              {[
                 %MobDev.Device{serial: serial, platform: :android, status: :connected}
               ], [], []},
              [serial]
            )

          [:ios] ->
            {[ios_target], [], []}
        end
      end

      assert {deployed, [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [
                   platforms: [:android, :ios],
                   restart: true,
                   ios_device: ios_id,
                   ios_lister: fn -> [ios_target] end,
                   canonical_android_serials: ["stale"],
                   android_deploy_lock: %{stale: true}
                 ],
                 deployer,
                 &successful_finalizer/1,
                 fn _plan -> :ok end
               )

      assert Enum.map(deployed, &{&1.platform, &1.serial}) == [
               {:android, serial},
               {:ios, ios_id}
             ]

      assert_receive {:deployer_called, android_opts}
      assert android_opts[:platforms] == [:android]
      assert android_opts[:canonical_android_serials] == [serial]
      assert android_opts[:android_deploy_lock] == native_lock([serial])
      assert android_opts[:android_payload_plan] == payload_plan([serial])

      assert_receive {:deployer_called, ios_opts}
      assert ios_opts[:platforms] == [:ios]
      refute Keyword.has_key?(ios_opts, :canonical_android_serials)
      refute Keyword.has_key?(ios_opts, :android_deploy_lock)
      refute Keyword.has_key?(ios_opts, :android_payload_plan)
    end

    test "authoritative production iOS deployed identities remain green" do
      devices = [
        physical_ios_device("physical-ios-device"),
        ios_simulator("78354490-EF38-44D7-A437-DD941C20524D")
      ]

      Enum.each(devices, fn device ->
        requested_id =
          if device.type == :simulator, do: MobDev.Device.display_id(device), else: device.serial

        deployer = fn _opts -> {[device], [], []} end

        assert {[^device], [], []} =
                 Deploy.deploy_after_native_build!(
                   true,
                   native_outcome([]),
                   [
                     platforms: [:ios],
                     restart: true,
                     ios_device: requested_id,
                     ios_lister: fn -> [device] end
                   ],
                   deployer
                 )
      end)
    end

    test "the supported nil iOS auto-target stays green only for one authoritative device" do
      device = ios_simulator("78354490-EF38-44D7-A437-DD941C20524D")

      assert {[^device], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([]),
                 [
                   platforms: [:ios],
                   restart: true,
                   ios_device: nil,
                   ios_lister: fn -> [device] end
                 ],
                 fn _opts -> {[device], [], []} end
               )
    end

    test "invalid iOS discovery fails before deployer or device mutation callbacks" do
      parent = self()
      device = physical_ios_device("ios-device")

      invalid_listers = [
        {:empty, fn -> [] end},
        {:malformed_member, fn -> [:not_a_device] end},
        {:improper, fn -> [device | :malformed_tail] end},
        {:raised, fn -> raise "discovery failed" end},
        {:thrown, fn -> throw(:discovery_failed) end},
        {:not_callable, :not_a_lister}
      ]

      Enum.each(invalid_listers, fn {scenario, ios_lister} ->
        attempt = make_ref()

        device_deployer = fn target ->
          send(parent, {attempt, :device_mutated, target})
          {:ok, target}
        end

        deployer = fn opts ->
          send(parent, {attempt, :deployer_called, opts})
          opts[:device_deployer].(device)
          {[device], [], []}
        end

        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              native_outcome([]),
              [
                platforms: [:ios],
                restart: true,
                ios_device: nil,
                ios_lister: ios_lister,
                device_deployer: device_deployer
              ],
              deployer
            )
          end)
        end

        refute_receive {^attempt, :deployer_called, _opts},
                       0,
                       "deployer ran for #{scenario} discovery"

        refute_receive {^attempt, :device_mutated, _target},
                       0,
                       "device callback ran for #{scenario} discovery"
      end)
    end

    test "an explicit iOS prefix collision fails before deployer or device mutation" do
      parent = self()
      first = ios_simulator("78354490-EF38-44D7-A437-DD941C20524D")
      second = ios_simulator("78354490-AAAA-BBBB-CCCC-DDDDEEEEFFFF")

      device_deployer = fn target ->
        send(parent, {:device_mutated, target})
        {:ok, target}
      end

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        opts[:device_deployer].(first)
        {[first], [], []}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            native_outcome([]),
            [
              platforms: [:ios],
              restart: true,
              ios_device: "78354490",
              ios_lister: fn -> [first, second] end,
              device_deployer: device_deployer
            ],
            deployer
          )
        end)
      end

      refute_received {:deployer_called, _opts}
      refute_received {:device_mutated, _target}
    end

    test "explicit iOS selection freezes the exact target before the deploy callback" do
      parent = self()
      selected = ios_simulator("78354490-EF38-44D7-A437-DD941C20524D")
      unrelated = ios_simulator("AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFFFFFF")
      selected_serial = selected.serial

      ios_lister = fn ->
        send(parent, :original_ios_lister_called)
        [selected, unrelated]
      end

      device_deployer = fn target ->
        send(parent, {:device_mutated, target})
        {:ok, target}
      end

      deployer = fn opts ->
        frozen_devices = opts[:ios_lister].()
        send(parent, {:frozen_ios_opts, opts[:ios_device], frozen_devices})

        deployed =
          Enum.map(frozen_devices, fn target ->
            assert {:ok, ^target} = opts[:device_deployer].(target)
            target
          end)

        {deployed, [], []}
      end

      assert {[selected], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([]),
                 [
                   platforms: [:ios],
                   restart: true,
                   ios_device: MobDev.Device.display_id(selected),
                   ios_lister: ios_lister,
                   device_deployer: device_deployer
                 ],
                 deployer
               )

      assert_received :original_ios_lister_called
      refute_received :original_ios_lister_called
      assert_received {:frozen_ios_opts, ^selected_serial, [^selected]}
      assert_received {:device_mutated, ^selected}
      refute_received {:device_mutated, _other}
    end

    test "non-authoritative iOS deployed identities make the native command non-green" do
      selected = physical_ios_device("ios-device")

      invalid_devices = [
        %{type: :physical, status: nil, error: nil},
        %{type: :physical, status: :unauthorized, error: nil},
        %{type: :physical, status: :arbitrary_success, error: nil},
        %{type: :physical, status: :error, error: "reported target error"},
        %{type: :physical, status: :skipped, error: "reported target skip"},
        %{type: :physical, status: :discovered, error: "stale success error"},
        %{type: :simulator, status: :booted, error: "stale success error"},
        %{type: :physical, status: :connected, error: nil},
        %{type: :physical, status: :tunneled, error: nil},
        %{type: :physical, status: :booted, error: nil},
        %{type: :simulator, status: :discovered, error: nil},
        %{type: nil, status: :discovered, error: nil}
      ]

      Enum.each(invalid_devices, fn invalid ->
        device =
          struct!(MobDev.Device,
            platform: :ios,
            serial: "ios-device",
            type: invalid.type,
            status: invalid.status,
            error: invalid.error
          )

        deployer = fn _opts -> {[device], [], []} end

        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              native_outcome([]),
              [
                platforms: [:ios],
                restart: true,
                ios_device: "ios-device",
                ios_lister: fn -> [selected] end
              ],
              deployer
            )
          end)
        end
      end)
    end

    test "incomplete or ambiguous iOS accounting makes the native command non-green" do
      requested = physical_ios_device("ios-device")

      other = %{requested | serial: "other-ios-device"}

      wrong_platform = %{
        requested
        | platform: :android,
          type: :physical,
          status: :discovered
      }

      skipped = %{requested | status: :skipped, error: "target disappeared"}

      invalid_results = [
        {[], [], []},
        {[], [], [skipped]},
        {[wrong_platform], [], []},
        {[other], [], []},
        {[requested, requested], [], []},
        {[requested, other], [], []}
      ]

      Enum.each(invalid_results, fn result ->
        assert_raise Mix.Error, "Native build failed", fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Deploy.deploy_after_native_build!(
              true,
              native_outcome([]),
              [
                platforms: [:ios],
                restart: true,
                ios_device: requested.serial,
                ios_lister: fn -> [requested] end
              ],
              fn _opts -> result end
            )
          end)
        end
      end)

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            native_outcome([]),
            [
              platforms: [:ios],
              restart: true,
              ios_device: nil,
              ios_lister: fn -> [requested] end
            ],
            fn _opts -> {[requested, other], [], []} end
          )
        end)
      end
    end

    test "improper iOS result buckets raise a controlled native failure" do
      device = physical_ios_device("ios-device")

      failed = %{device | status: :error, error: "reported target error"}
      skipped = %{device | status: :skipped, error: "reported target skip"}

      improper_results = [
        {[device | :malformed_tail], [], []},
        {[], [failed | :malformed_tail], []},
        {[], [], [skipped | :malformed_tail]}
      ]

      Enum.each(improper_results, fn result ->
        Enum.each([:plain, :wrapped], fn shape ->
          deployer = fn _opts ->
            if shape == :wrapped, do: {result, %{opaque: :lease}}, else: result
          end

          assert_raise Mix.Error, "Native build failed", fn ->
            ExUnit.CaptureIO.capture_io(fn ->
              Deploy.deploy_after_native_build!(
                true,
                native_outcome([]),
                [
                  platforms: [:ios],
                  restart: true,
                  ios_device: device.serial,
                  ios_lister: fn -> [device] end
                ],
                deployer
              )
            end)
          end
        end)
      end)
    end

    test "native Android with no successful update target fails before the final pass" do
      parent = self()

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        {[], [], []}
      end

      assert_raise Mix.Error, "Native build failed", fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Deploy.deploy_after_native_build!(
            true,
            native_outcome([]),
            [platforms: [:android], device: nil],
            deployer
          )
        end)
      end

      refute_received {:deployer_called, _}
    end

    test "a successful iOS build still deploys when unavailable Android was skipped" do
      parent = self()

      ios_device = physical_ios_device("ios-device")

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        {[ios_device], [], []}
      end

      assert {[^ios_device], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([]),
                 [
                   platforms: [:android, :ios],
                   device: nil,
                   ios_lister: fn -> [ios_device] end
                 ],
                 deployer
               )

      assert_receive {:deployer_called, opts}
      assert opts[:platforms] == [:ios]
      refute Keyword.has_key?(opts, :canonical_android_serials)
      refute_received {:deployer_called, _}
    end
  end

  describe "ensure_deploy_succeeded!/1" do
    test "raises when the final deployer reports any failed device" do
      failed = device("serial-a", "runtime verification failed")

      assert_raise Mix.Error, "Deploy failed on 1 device(s)", fn ->
        Deploy.ensure_deploy_succeeded!({[], [failed], []})
      end
    end

    test "the production reporter prints the summary and raises after any failure" do
      failed = device("serial-a", "runtime verification failed")
      parent = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          try do
            Deploy.report_deploy_result!({[], [failed], []})
          rescue
            error in Mix.Error -> send(parent, {:report_error, error})
          end
        end)

      assert output =~ "Failed on 1 device(s)"
      assert_receive {:report_error, %Mix.Error{message: "Deploy failed on 1 device(s)"}}
    end

    test "preserves successful, skipped-only, and no-device outcomes" do
      deployed = device("serial-a")
      skipped = device("serial-b", "app not installed")

      assert :ok = Deploy.ensure_deploy_succeeded!({[deployed], [], []})
      assert :ok = Deploy.ensure_deploy_succeeded!({[], [], [skipped]})
      assert :ok = Deploy.ensure_deploy_succeeded!({[], [], []})
    end
  end
end
