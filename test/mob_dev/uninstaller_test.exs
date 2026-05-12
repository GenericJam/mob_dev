defmodule MobDev.UninstallerTest do
  use ExUnit.Case, async: true

  alias MobDev.{Device, Uninstaller}

  doctest Uninstaller

  defp android(name), do: %Device{name: name, serial: name, platform: :android}
  defp ios(name), do: %Device{name: name, serial: name, platform: :ios}

  defp result(device, bundle_id, outcome, reason \\ nil) do
    %{device: device, bundle_id: bundle_id, outcome: outcome, reason: reason}
  end

  # ── categorize_results/1 ────────────────────────────────────────────────

  describe "categorize_results/1" do
    test "buckets each outcome correctly" do
      ok = result(android("a"), "com.x", :uninstalled)
      err = result(android("b"), "com.x", :error, "adb timeout")
      skip = result(android("c"), "com.x", :skipped, "not installed")

      {u, f, s} = Uninstaller.categorize_results([ok, err, skip])
      assert u == [ok]
      assert f == [err]
      assert s == [skip]
    end

    test "empty input → three empty lists" do
      assert {[], [], []} = Uninstaller.categorize_results([])
    end

    test "skipped never bleeds into failed (regression pin)" do
      # Same invariant as MobDev.Deployer.categorize_results/1: an
      # app-not-installed result is informational, not a failure.
      skips = Enum.map(1..5, fn i -> result(android("emu-#{i}"), "com.x", :skipped) end)
      {u, f, s} = Uninstaller.categorize_results(skips)
      assert u == []
      assert f == []
      assert length(s) == 5
    end
  end

  # ── filter_devices_by_id/2 ──────────────────────────────────────────────

  describe "filter_devices_by_id/2" do
    test "empty ids → returns all devices unfiltered" do
      devices = [android("a"), ios("b")]
      assert Uninstaller.filter_devices_by_id(devices, []) == devices
    end

    test "matches by exact serial" do
      a = android("a")
      b = ios("b")
      assert Uninstaller.filter_devices_by_id([a, b], ["a"]) == [a]
    end

    test "matches multiple ids in one call" do
      a = android("a")
      b = ios("b")
      c = android("c")
      assert Uninstaller.filter_devices_by_id([a, b, c], ["a", "c"]) == [a, c]
    end

    test "non-matching ids → empty list" do
      devices = [android("a"), ios("b")]
      assert Uninstaller.filter_devices_by_id(devices, ["nope"]) == []
    end
  end

  # ── interpret_adb_uninstall/2 ───────────────────────────────────────────

  describe "interpret_adb_uninstall/2" do
    test "exit 0 + 'Success' → :uninstalled" do
      assert {:uninstalled, nil} = Uninstaller.interpret_adb_uninstall("Success\n", 0)
    end

    test "'Unknown package' → :skipped regardless of exit code" do
      # Real adb output for an uninstall of a missing package:
      #   "Failure [DELETE_FAILED_INTERNAL_ERROR: Unknown package: com.x]"
      out = "Failure [DELETE_FAILED_INTERNAL_ERROR: Unknown package: com.x]\n"
      assert {:skipped, "not installed"} = Uninstaller.interpret_adb_uninstall(out, 0)
    end

    test "non-zero exit without 'Unknown package' → :error with full output" do
      out = "Failure [INSTALL_PARSE_FAILED_NOT_APK]\n"
      assert {:error, msg} = Uninstaller.interpret_adb_uninstall(out, 1)
      assert msg =~ "INSTALL_PARSE_FAILED_NOT_APK"
    end

    test "exit 0 but no 'Success' marker → :error (conservative)" do
      # adb can return exit 0 with garbage output; don't claim success
      # unless we see the Success marker.
      assert {:error, "weird"} = Uninstaller.interpret_adb_uninstall("weird\n", 0)
    end
  end

  # ── interpret_devicectl_uninstall/2 ─────────────────────────────────────

  describe "interpret_devicectl_uninstall/2" do
    test "exit 0 → :uninstalled" do
      assert {:uninstalled, nil} = Uninstaller.interpret_devicectl_uninstall("ok\n", 0)
    end

    test "'ContainerLookupErrorDomain' → :skipped (app not on device)" do
      # devicectl shape for a bundle id that isn't installed on the
      # device — same pattern as the install error path elsewhere
      # in mob_dev's deployer.
      out = """
      Failed to load provisioning paramter list ...
      ERROR: ContainerLookupErrorDomain code 1004 -- App not installed
      """

      assert {:skipped, "not installed"} = Uninstaller.interpret_devicectl_uninstall(out, 1)
    end

    test "'not installed' phrase → :skipped (alternate wording)" do
      out = "App with bundle id com.example.foo is not installed\n"
      assert {:skipped, "not installed"} = Uninstaller.interpret_devicectl_uninstall(out, 1)
    end

    test "other non-zero exit → :error with trimmed output" do
      out = "device not paired with this host\n"
      assert {:error, msg} = Uninstaller.interpret_devicectl_uninstall(out, 1)
      assert msg =~ "not paired"
      refute msg =~ "\n"
    end

    test "real-world Xcode 15+ devicectl error doesn't accidentally match skipped" do
      # Make sure a transient devicectl error (e.g. tunnel disconnect)
      # surfaces as :error, not as :skipped — the user needs to see it.
      out = """
      14:32:56 Acquired tunnel connection to device.
      ERROR: connection lost mid-operation
      """

      assert {:error, _} = Uninstaller.interpret_devicectl_uninstall(out, 1)
    end
  end

  # ── parse_package_list/1 ────────────────────────────────────────────────

  describe "parse_package_list/1" do
    test "extracts package names, strips prefix, sorts" do
      out = "package:com.example.b\npackage:com.example.a\n"
      assert Uninstaller.parse_package_list(out) == ["com.example.a", "com.example.b"]
    end

    test "ignores non-package lines" do
      out = "package:com.example.a\nstderr noise\n"
      assert Uninstaller.parse_package_list(out) == ["com.example.a"]
    end

    test "empty → empty list" do
      assert Uninstaller.parse_package_list("") == []
    end

    test "no matches → empty list" do
      assert Uninstaller.parse_package_list("garbage\nmore garbage\n") == []
    end
  end

  # ── simctl_listapps_with_prefix/2 ───────────────────────────────────────

  describe "simctl_listapps_with_prefix/2" do
    test "extracts bundle ids and filters by prefix" do
      # Minimal simctl-listapps-shaped output. Real output is plist-
      # ish; we just scan for the quoted bundle id followed by `= {`.
      output = """
          "com.example.foo" =     {
              ApplicationType = User;
          };
          "com.example.bar" =     {
              ApplicationType = User;
          };
          "com.other.baz" =     {
              ApplicationType = User;
          };
      """

      assert Uninstaller.simctl_listapps_with_prefix(output, "com.example.") ==
               ["com.example.bar", "com.example.foo"]
    end

    test "empty output → empty list" do
      assert Uninstaller.simctl_listapps_with_prefix("", "com.example.") == []
    end

    test "no matches → empty list" do
      output = ~s("com.other.foo" =     {\n};\n)
      assert Uninstaller.simctl_listapps_with_prefix(output, "com.example.") == []
    end
  end

  # ── classify_simctl_error/1 ─────────────────────────────────────────────

  describe "classify_simctl_error/1" do
    test "'No such application' → :not_installed" do
      output = "An error was encountered processing the command: No such application"
      assert Uninstaller.classify_simctl_error(output) == :not_installed
    end

    test "'not installed' phrase → :not_installed" do
      assert Uninstaller.classify_simctl_error("App is not installed") == :not_installed
    end

    test "other error → :error" do
      assert Uninstaller.classify_simctl_error("device not booted") == :error
    end
  end

  # ── preview_lines/1 ─────────────────────────────────────────────────────

  describe "preview_lines/1" do
    defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")

    test "empty plan → 'nothing to do' message" do
      [line] = Uninstaller.preview_lines([])
      assert strip_ansi(line) =~ "nothing to do"
    end

    test "renders one device with its bundle list" do
      lines = Uninstaller.preview_lines([{android("emu-5554"), ["com.x", "com.y"]}])
      flat = Enum.map(lines, &strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "About to uninstall"
      assert flat =~ "emu-5554"
      assert flat =~ "android"
      assert flat =~ "- com.x"
      assert flat =~ "- com.y"
    end

    test "renders multiple devices with their bundles" do
      lines =
        Uninstaller.preview_lines([
          {android("emu-5554"), ["com.x"]},
          {ios("iPhone 17"), ["com.x", "com.y"]}
        ])

      flat = Enum.map(lines, &strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "emu-5554"
      assert flat =~ "iPhone 17"
      # Each bundle line is its own row.
      lines_count =
        flat |> String.split("\n", trim: true) |> Enum.count(&String.contains?(&1, "- "))

      assert lines_count == 3
    end
  end

  # ── plan/1 happy paths via DI through opts ──────────────────────────────
  #
  # The hardware-touching pieces (Discovery.{Android,IOS}.list_devices/0,
  # System.cmd) aren't stubbable without dependency injection. The plan/1
  # error paths exercise the device-resolution logic; the happy path
  # validation lives in the Mix task's tests where we mock the chain.

  describe "plan/1 — error shapes" do
    test "no devices connected → {:error, :no_devices, %{detected: 0}}" do
      # platforms: [] forces list_all_devices to return [].
      assert {:error, :no_devices, %{detected: 0}} =
               Uninstaller.plan(platforms: [], device_ids: [])
    end
  end
end
