defmodule Mix.Tasks.Mob.EnableTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # The mob.enable task is now Igniter-driven (Phase 4 iter 1). It dispatches
  # per-feature handlers in `MobDev.Enable.Igniter`. These tests exercise the
  # task's validation + dispatch surface; per-handler text-mutation logic is
  # covered in `MobDev.EnableTest`.

  describe "argument validation" do
    test "no features → issue" do
      enable([])
      |> assert_has_issue(&(&1 =~ "Usage:"))
    end

    test "unknown feature → issue" do
      enable(["typescript"])
      |> assert_has_issue(&(&1 =~ "Unknown feature"))
    end

    test "all valid features are accepted (no validation issue)" do
      # We only assert that validation passes — most handlers issue notices
      # because the test project has no ios/, android/, assets/ etc. dirs.
      for feature <- ~w(camera photo_library location file_sharing notifications) do
        igniter = enable([feature])
        assert igniter.issues == [], "feature #{feature} was rejected: #{inspect(igniter.issues)}"
      end
    end
  end

  describe "camera feature" do
    test "patches Info.plist + AndroidManifest.xml when both exist" do
      igniter =
        test_project(
          files: %{
            "ios/Test/Info.plist" => plist_skeleton(),
            "android/app/src/main/AndroidManifest.xml" => android_manifest_skeleton()
          }
        )
        |> Igniter.compose_task("mob.enable", ["camera"])

      plist =
        Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "ios/Test/Info.plist"), :content)

      manifest =
        Rewrite.Source.get(
          Rewrite.source!(igniter.rewrite, "android/app/src/main/AndroidManifest.xml"),
          :content
        )

      assert plist =~ "NSCameraUsageDescription"
      assert plist =~ "This app uses the camera."
      assert manifest =~ ~s(android:name="android.permission.CAMERA")
    end

    test "skips Info.plist patch when key is already present" do
      plist =
        plist_skeleton()
        |> String.replace(
          "</dict>",
          "<key>NSCameraUsageDescription</key>\n    <string>existing</string>\n</dict>"
        )

      igniter =
        test_project(files: %{"ios/Test/Info.plist" => plist})
        |> Igniter.compose_task("mob.enable", ["camera"])

      patched =
        Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "ios/Test/Info.plist"), :content)

      # The existing description survives; the task did not append a duplicate.
      assert patched =~ "existing"
      refute patched =~ "This app uses the camera."
    end
  end

  describe "photo_library feature" do
    test "patches Info.plist only; notice about Android" do
      igniter =
        test_project(files: %{"ios/Test/Info.plist" => plist_skeleton()})
        |> Igniter.compose_task("mob.enable", ["photo_library"])

      plist =
        Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "ios/Test/Info.plist"), :content)

      assert plist =~ "NSPhotoLibraryAddUsageDescription"

      assert Enum.any?(igniter.notices, &(&1 =~ "no Android manifest change needed"))
    end
  end

  describe "missing platform dirs" do
    test "no ios/ → adds a notice instead of failing" do
      igniter =
        test_project(
          files: %{"android/app/src/main/AndroidManifest.xml" => android_manifest_skeleton()}
        )
        |> Igniter.compose_task("mob.enable", ["camera"])

      assert igniter.issues == []
      assert Enum.any?(igniter.notices, &(&1 =~ "no Info.plist"))
      # Android manifest still got patched.
      manifest =
        Rewrite.Source.get(
          Rewrite.source!(igniter.rewrite, "android/app/src/main/AndroidManifest.xml"),
          :content
        )

      assert manifest =~ "android.permission.CAMERA"
    end

    test "no android/ → adds a notice instead of failing" do
      igniter =
        test_project(files: %{"ios/Test/Info.plist" => plist_skeleton()})
        |> Igniter.compose_task("mob.enable", ["camera"])

      assert igniter.issues == []
      assert Enum.any?(igniter.notices, &(&1 =~ "no AndroidManifest.xml"))
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp enable(features) do
    test_project()
    |> Igniter.compose_task("mob.enable", features)
  end

  defp plist_skeleton do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.example.test</string>
    </dict>
    </plist>
    """
  end

  defp android_manifest_skeleton do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <manifest xmlns:android="http://schemas.android.com/apk/res/android"
        package="com.example.test">

        <application
            android:label="Test"
            android:icon="@mipmap/ic_launcher">
        </application>
    </manifest>
    """
  end
end
