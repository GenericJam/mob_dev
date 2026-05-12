defmodule Mix.Tasks.Mob.UninstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Uninstall
  alias MobDev.{Device, Uninstaller}

  defp android(name), do: %Device{name: name, serial: name, platform: :android}

  defp result(device, bundle_id, outcome, reason \\ nil) do
    %{device: device, bundle_id: bundle_id, outcome: outcome, reason: reason}
  end

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")

  # ── format_summary/3 ────────────────────────────────────────────────────

  describe "format_summary/3" do
    test "all three buckets empty → no-op message" do
      [line] = Uninstall.format_summary([], [], [])
      assert line =~ "No-op — nothing to uninstall"
    end

    test "only uninstalled → green Uninstalled header" do
      lines = Uninstall.format_summary([result(android("a"), "com.x", :uninstalled)], [], [])
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "Uninstalled: 1"
      assert flat =~ "✓ a: com.x"
      refute flat =~ "Failed"
      refute flat =~ "Skipped"
    end

    test "only skipped → yellow Skipped header (not Failed)" do
      # Regression: the skipped-not-installed case is NOT a failure.
      # mirrors the same fix in Mix.Tasks.Mob.Deploy.format_summary/4.
      skip = result(android("a"), "com.x", :skipped, "not installed")
      lines = Uninstall.format_summary([], [], [skip])
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "Skipped (not installed): 1"
      assert flat =~ "— a: com.x (not installed)"
      refute flat =~ "Failed"
    end

    test "only failed → red Failed header" do
      fail = result(android("a"), "com.x", :error, "adb timeout")
      lines = Uninstall.format_summary([], [fail], [])
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "Failed: 1"
      assert flat =~ "✗ a: com.x (adb timeout)"
    end

    test "mixed three-way result renders all blocks distinctly" do
      ok = result(android("a"), "com.x", :uninstalled)
      fail = result(android("b"), "com.x", :error, "adb timeout")
      skip = result(android("c"), "com.x", :skipped, "not installed")

      lines = Uninstall.format_summary([ok], [fail], [skip])
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "Uninstalled: 1"
      assert flat =~ "Skipped (not installed): 1"
      assert flat =~ "Failed: 1"
      # Each result uses its category-specific marker.
      assert flat =~ "✓ a"
      assert flat =~ "— c"
      assert flat =~ "✗ b"
    end

    test "nuke-everything: 5 androids × 3 apps with mixed outcomes" do
      # The scenario the user explicitly asked for — clear out every
      # test app on every emulator. Some weren't there (skipped),
      # some had stale state requiring re-install (uninstalled), no
      # errors expected. Pin the shape.
      devices = for i <- 1..5, do: android("emu-#{i}")

      results =
        for d <- devices, app <- ~w(com.example.a com.example.b com.example.c) do
          # First app present on every device; second on only the
          # first two; third on none.
          cond do
            app == "com.example.a" ->
              result(d, app, :uninstalled)

            app == "com.example.b" and d.name in ["emu-1", "emu-2"] ->
              result(d, app, :uninstalled)

            true ->
              result(d, app, :skipped, "not installed")
          end
        end

      {u, f, s} = Uninstaller.categorize_results(results)
      lines = Uninstall.format_summary(u, f, s)
      flat = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert flat =~ "Uninstalled: 7"
      assert flat =~ "Skipped (not installed): 8"
      refute flat =~ "Failed"
    end
  end

  # ── --help / -h ─────────────────────────────────────────────────────────

  describe "--help integration" do
    test "--help prints the @moduledoc and exits cleanly" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Uninstall.run(["--help"])
        end)

      # @moduledoc covers the user-facing surface. Pin stable
      # substrings so the test isn't brittle to wording.
      assert output =~ "Uninstall a Mob app"
      assert output =~ "--all-devices"
      assert output =~ "--all-apps"
      assert output =~ "--bundle-id"
    end

    test "-h is treated the same as --help" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Uninstall.run(["-h"])
        end)

      assert output =~ "Uninstall a Mob app"
    end

    test "--help short-circuits before parsing other flags" do
      # Important: even invalid flag combos should print help, not
      # crash, when --help is present.
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Uninstall.run(["--help", "--obviously-not-a-real-flag"])
        end)

      assert output =~ "Uninstall a Mob app"
    end
  end
end
