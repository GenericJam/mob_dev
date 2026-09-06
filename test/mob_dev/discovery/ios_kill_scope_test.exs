defmodule MobDev.Discovery.IOSKillScopeTest do
  @moduledoc """
  Guards MOB-70: `mix mob.connect` with a personal iPhone attached force-quit
  every third-party app on the phone.

  The old code matched any process under `Bundle/Application/` and killed it.
  Every user app lives there, so a banking app, a messaging app and whatever
  else the owner had open were all terminated to free EPMD 4369.
  """
  use ExUnit.Case, async: true

  alias MobDev.Discovery.IOS

  # Shaped exactly like `xcrun devicectl device info processes` output, which
  # is columnar: pid, whitespace, absolute executable path.
  @processes """
      412   /usr/libexec/backboardd
     7911   /private/var/containers/Bundle/Application/353039DD/DemoOne.app/DemoOne
     7914   /private/var/containers/Bundle/Application/89670CCD/DemoTwo.app/DemoTwo
     7919   /private/var/containers/Bundle/Application/2DE7229A/Ledger Pro.app/Ledger Pro
     7932   /private/var/containers/Bundle/Application/79CF638A/Chatterbox.app/Chatterbox
     7940   /private/var/containers/Bundle/Application/AABBCCDD/TestFlight.app/TestFlight
       35   /System/Library/CoreServices/SpringBoard.app/SpringBoard
       36   /Applications/News.app/News
  """

  describe "only our own apps are killable" do
    test "a third-party app is never selected, however it is spelled" do
      # The bug in one line: these are the apps that were being killed.
      pids = IOS.mob_pids_to_kill(@processes, ["DemoOne", "DemoTwo"], nil)

      assert pids == [7911, 7914]

      refute 7919 in pids, "killed a third-party app (name contains a space)"
      refute 7932 in pids, "killed a third-party app"
      refute 7940 in pids, "killed TestFlight"
    end

    test "an unknown device kills nothing rather than everything" do
      # The whole point. No record of what we installed is not licence to
      # clear the phone; it is the reason to touch none of it.
      assert IOS.mob_pids_to_kill(@processes, [], nil) == []
    end

    test "the app being launched is left alone" do
      # The caller launches it with --terminate-existing straight after, so
      # killing it here is redundant, and racing that is how you get a launch
      # into a process that is still dying.
      pids = IOS.mob_pids_to_kill(@processes, ["DemoOne", "DemoTwo"], "DemoOne")

      assert pids == [7914]
      refute 7911 in pids
    end

    test "a recorded app that is not running contributes no pid" do
      assert IOS.mob_pids_to_kill(@processes, ["NotRunning"], nil) == []
    end

    test "system processes are never matched, even on an exact name collision" do
      # The dangerous case, and the reason the pattern is anchored to
      # Bundle/Application/. `ios_display_name/0` is Macro.camelize of the
      # project name, so a project called :news or :springboard produces
      # exactly the bundle name Apple ships. Name equality alone is not a
      # safety property.
      refute 412 in IOS.mob_pids_to_kill(@processes, ["backboardd", "DemoOne"], nil)
      assert IOS.mob_pids_to_kill(@processes, ["SpringBoard"], nil) == []
      assert IOS.mob_pids_to_kill(@processes, ["News"], nil) == []
    end
  end

  describe "parsing" do
    test "an app name is matched whole, not as a substring" do
      # "Demo" must not match "DemoOne.app" — otherwise a short recorded name
      # silently widens the blast radius to every app sharing its prefix.
      assert IOS.mob_pids_to_kill(@processes, ["Demo"], nil) == []
    end

    test "empty and malformed output are handled without raising" do
      assert IOS.mob_pids_to_kill("", ["DemoOne"], nil) == []
      assert IOS.mob_pids_to_kill("garbage\n\n  \n", ["DemoOne"], nil) == []
    end
  end

  describe "which app is spared" do
    @ours [
      %{bundle_id: "com.example.one", app_name: "DemoOne"},
      %{bundle_id: "com.example.two", app_name: "DemoTwo"}
    ]

    test "the launching app's bundle id resolves to its .app name" do
      assert IOS.except_app_name_for(@ours, "com.example.one") == "DemoOne"
    end

    test "an unknown bundle id spares nothing" do
      assert IOS.except_app_name_for(@ours, "com.example.other") == nil
      assert IOS.except_app_name_for(@ours, nil) == nil
      assert IOS.except_app_name_for([], "com.example.one") == nil
    end

    test "matching on the wrong field would kill the app we are about to launch" do
      # Guards the mutation: comparing app_name instead of bundle_id returns
      # nil here, which puts the target app back in the kill set — mob_dev
      # then --kills it microseconds before devicectl launch targets it.
      refute IOS.except_app_name_for(@ours, "DemoOne") == "DemoOne"
      assert IOS.except_app_name_for(@ours, "DemoOne") == nil
    end

    test "end to end: the launching app survives, its sibling does not" do
      except = IOS.except_app_name_for(@ours, "com.example.one")
      pids = IOS.mob_pids_to_kill(@processes, ["DemoOne", "DemoTwo"], except)

      assert pids == [7914]
    end
  end
end
