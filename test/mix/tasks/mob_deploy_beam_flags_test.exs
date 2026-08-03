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
              {[%MobDev.Device{platform: :android, serial: serial}], [], []},
              [serial]
            )

          [:ios] ->
            {[%MobDev.Device{platform: :ios, serial: ios_id}], [], []}
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
                 [restart: true, force_fs: true],
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
        {[%MobDev.Device{platform: :ios, serial: ios_id}], [], []}
      end

      assert {[%MobDev.Device{platform: :ios, serial: ^ios_id}], [], []} =
               Deploy.execute_native_deploy!(
                 [:android, :ios],
                 nil,
                 ios_id,
                 [],
                 [restart: true],
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
          |> Enum.map(&%MobDev.Device{serial: &1, platform: :android})

        committed_result({deployed, [], []}, ["serial-a", "serial-b"])
      end

      assert {deployed, [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome(["serial-a", "serial-b"]),
                 [platforms: [:android], device: nil, restart: true],
                 deployer,
                 &successful_finalizer/1
               )

      assert Enum.map(deployed, & &1.serial) == ["serial-a", "serial-b"]

      assert_receive {:deployer_called, android_opts}
      assert android_opts[:platforms] == [:android]
      assert android_opts[:canonical_android_serials] == ["serial-a", "serial-b"]
      refute Keyword.has_key?(android_opts, :device)
      assert android_opts[:restart]

      refute_received {:deployer_called, _}
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
               platform: :android
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
                 &successful_finalizer/1
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
      canonical = %MobDev.Device{serial: "serial-a", platform: :android}
      duplicate = %{canonical | name: "duplicate"}
      wrong_platform = %MobDev.Device{serial: "serial-a", platform: :ios}
      extra = %MobDev.Device{serial: "serial-b", platform: :android}

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

    test "a partial Android set failure reports no target deployed before commit" do
      parent = self()
      serials = ["serial-a", "serial-b"]

      deployer = fn opts ->
        case opts[:platforms] do
          [:android] ->
            {
              {[%MobDev.Device{serial: "serial-a", platform: :android}],
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

    test "native Android releases only after every canonical final result succeeds" do
      parent = self()
      serial = "serial-a"

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        committed_result(
          {[%MobDev.Device{serial: serial, platform: :android}], [], []},
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
          {[%MobDev.Device{serial: serial, platform: :android}], [], []},
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
              {[%MobDev.Device{serial: serial, platform: :android}], [], []},
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

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})

        case opts[:platforms] do
          [:android] ->
            committed_result(
              {[%MobDev.Device{serial: serial, platform: :android}], [], []},
              [serial]
            )

          [:ios] ->
            {[], [], []}
        end
      end

      assert {[%MobDev.Device{serial: ^serial}], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([serial]),
                 [
                   platforms: [:android, :ios],
                   restart: true,
                   canonical_android_serials: ["stale"],
                   android_deploy_lock: %{stale: true}
                 ],
                 deployer,
                 &successful_finalizer/1
               )

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

      deployer = fn opts ->
        send(parent, {:deployer_called, opts})
        {[], [], []}
      end

      assert {[], [], []} =
               Deploy.deploy_after_native_build!(
                 true,
                 native_outcome([]),
                 [platforms: [:android, :ios], device: nil],
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
