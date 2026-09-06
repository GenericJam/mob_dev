defmodule MobDev.IOSInstallWiringTest do
  @moduledoc """
  Pins the two call sites the MOB-70 kill scope depends on.

  Source-asserted, following the convention this repo already uses for
  behaviour that cannot be executed in a test: both sites live inside
  functions that shell out to `xcrun devicectl` against a physical device.

  This exists because the first attempt at pinning them did not. Helper
  functions were made public and tested, which felt like coverage — but
  deleting the line that *calls* them left the whole suite green and the
  feature silently disabled: the registry stays empty for ever, so nothing is
  ever recognised as ours, so nothing is ever cleared off EPMD 4369, and every
  second Mob app on a device fails to boot. Nothing crashes. It just stops
  working, which is exactly the failure mode MOB-70's fix is supposed to make
  impossible.
  """
  use ExUnit.Case, async: true

  @native_build Path.expand("../../lib/mob_dev/native_build.ex", __DIR__)
  @uninstaller Path.expand("../../lib/mob_dev/uninstaller.ex", __DIR__)

  defp code_only(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r|^\s*#.*$|, &1, ""))
  end

  test "a successful physical install records the app" do
    body = function_body(code_only(@native_build), "defp devicectl_install(")

    assert body =~ "MobDev.IOSInstalls.record(",
           """
           devicectl_install/2 no longer records what it installed.

           The kill scope reads that registry to decide what is ours. Without
           the record it stays empty, nothing is ever recognised, and other Mob
           apps are never cleared off EPMD 4369 — so the second app on a device
           never boots, with no error anywhere.
           """
  end

  test "a successful physical uninstall forgets the app" do
    body =
      function_body(
        code_only(@uninstaller),
        "defp uninstall_one(%Device{platform: :ios, type: :physical"
      )

    assert body =~ "MobDev.IOSInstalls.forget(",
           """
           The physical-device uninstall path no longer forgets the app.

           Matching is by app NAME, so a stale entry is not inert: it stays
           killable for ever, and a third-party app that later takes that name
           inherits it — MOB-70 in miniature.
           """
  end

  test "the record is keyed on the iOS bundle id, not the Android one" do
    # They legitimately differ (Apple forbids underscores), and the launcher
    # looks the app up by its iOS id. Recording the other one makes every
    # entry unmatchable.
    assert code_only(@native_build) =~
             "def bundle_id_for(_app_path), do: MobDev.Config.ios_bundle_id()"
  end

  defp function_body(src, marker) do
    [_, rest] = String.split(src, marker, parts: 2)
    rest |> String.split("\n  end", parts: 2) |> hd()
  end
end
