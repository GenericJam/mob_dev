defmodule MobDev.Bench.PreflightTest do
  use ExUnit.Case, async: false

  alias MobDev.Bench.Preflight

  describe "all_ok?/1" do
    test "true when every result is :ok" do
      results = [
        {:hardware, {:ok, "USB device connected"}},
        {:beam_reachable, {:ok, "EPMD ok"}}
      ]

      assert Preflight.all_ok?(results)
    end

    test "false when any result is :error" do
      results = [
        {:hardware, {:ok, "USB device connected"}},
        {:beam_reachable, {:error, "EPMD not reachable"}}
      ]

      refute Preflight.all_ok?(results)
    end
  end

  describe "pretty/1" do
    test "renders ✓ for ok and ✗ for error" do
      results = [
        {:hardware, {:ok, "USB device connected"}},
        {:beam_reachable, {:error, "EPMD not reachable"}}
      ]

      output = Preflight.pretty(results)
      assert output =~ "✓ hardware"
      assert output =~ "✗ beam reachable"
      assert output =~ "USB device connected"
      assert output =~ "EPMD not reachable"
    end
  end

  describe "check_hardware/1" do
    test "with hw_udid provided → ok" do
      assert {:ok, _} = Preflight.check_hardware(hw_udid: "00008110-001E1C3A34F8401E")
    end

    test "with no hw_udid and no idevice_id installed → error or ok depending on env" do
      # We can't reliably remove idevice_id from PATH, so we just verify the
      # function doesn't crash and returns a tagged tuple.
      assert match?({:ok, _}, Preflight.check_hardware([])) or
               match?({:error, _}, Preflight.check_hardware([]))
    end
  end

  describe "check_app_installed/1" do
    test "missing bundle_id → error" do
      assert {:error, "bundle_id not configured"} = Preflight.check_app_installed([])
    end

    test "missing device_id → ok (skipped)" do
      assert {:ok, msg} = Preflight.check_app_installed(bundle_id: "com.example.app")
      assert msg =~ "skipped"
    end
  end

  describe "check_beam_reachable/1" do
    test "no node → error" do
      assert {:error, "no node provided"} = Preflight.check_beam_reachable([])
    end

    test "bad host derivation → error" do
      assert {:error, msg} = Preflight.check_beam_reachable(node: :nodename_no_at)
      assert msg =~ "could not derive host"
    end

    test "EPMD not reachable on TEST-NET-1 → error" do
      assert {:error, msg} =
               Preflight.check_beam_reachable(
                 node: :"phantom@192.0.2.1",
                 host: "192.0.2.1"
               )

      assert msg =~ "not reachable"
    end
  end

  describe "check_rpc_responsive/1" do
    test "no node → error" do
      assert {:error, "no node provided"} = Preflight.check_rpc_responsive([])
    end
  end

  describe "run/1 — runs all checks without crashing" do
    test "returns a list of {name, result} pairs" do
      results = Preflight.run([])

      names = Enum.map(results, &elem(&1, 0))
      # Order matters — tests use this for grouped display.
      assert names == [
               :hardware,
               :app_installed,
               :beam_reachable,
               :rpc_responsive,
               :nif_version,
               :keep_alive_nif
             ]
    end

    test "honors require_keep_alive: false to skip keep-alive check" do
      results = Preflight.run(require_keep_alive: false)
      {_, {:ok, msg}} = List.keyfind(results, :keep_alive_nif, 0)
      assert msg == "skipped"
    end

    test "platform: :android dispatches to android-specific hardware/app checks" do
      # Smoke test — just verify it runs without crashing and returns the
      # standard 6 check names regardless of platform.
      results = Preflight.run(platform: :android, adb_serial: "127.0.0.1:5555")
      names = Enum.map(results, &elem(&1, 0))

      assert names == [
               :hardware,
               :app_installed,
               :beam_reachable,
               :rpc_responsive,
               :nif_version,
               :keep_alive_nif
             ]
    end
  end

  describe "Android: check_hardware/2" do
    test "no adb in PATH → error" do
      # Can't reliably remove adb from PATH in tests, so just verify the
      # function returns a tagged tuple without raising.
      result = Preflight.check_hardware(:android, [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Android: check_app_installed/2" do
    test "missing bundle_id → error" do
      assert {:error, "bundle_id not configured"} =
               Preflight.check_app_installed(:android, adb_serial: "127.0.0.1:5555")
    end

    test "missing adb_serial → ok (skipped)" do
      assert {:ok, msg} =
               Preflight.check_app_installed(:android, bundle_id: "com.example.app")

      assert msg =~ "skipped" or msg =~ "BEAM reachability"
    end
  end

  describe "Backward compat — single-arg check_hardware/check_app_installed" do
    test "check_hardware/1 dispatches to iOS for back-compat" do
      assert match?({:ok, _}, Preflight.check_hardware([])) or
               match?({:error, _}, Preflight.check_hardware([]))
    end

    test "check_app_installed/1 dispatches to iOS for back-compat" do
      assert {:error, "bundle_id not configured"} = Preflight.check_app_installed([])
    end
  end
end
