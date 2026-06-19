defmodule Mix.Tasks.Mob.Adopt.Native.AndroidTest do
  # NOT async: copy_static_binaries writes to the project CWD via File.copy!
  # (see the native installer's deliberate divergence from Igniter for
  # binary assets), so two test runs would race on android/gradlew.
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    # Each test runs in its own temp cwd so the binary-copy side effects
    # don't leak into the repo root or between tests.
    cwd = File.cwd!()

    tmp =
      System.tmp_dir!() |> Path.join("mob_adopt_native_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.cd!(tmp)
    on_exit(fn -> File.cd!(cwd) end)
    {:ok, tmp: tmp}
  end

  describe "mob.adopt.native.android" do
    test "creates AndroidManifest and build.gradle for the app" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.native.android")
        |> apply_igniter!()

      assert Rewrite.has_source?(
               igniter.rewrite,
               "android/app/src/main/AndroidManifest.xml"
             )

      assert Rewrite.has_source?(igniter.rewrite, "android/app/build.gradle")
    end

    test "MainActivity.kt is templated with the app name", %{tmp: _tmp} do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.native.android")
        |> apply_igniter!()

      path = "android/app/src/main/java/com/example/test/MainActivity.kt"
      source = Rewrite.source!(igniter.rewrite, path)
      content = Rewrite.Source.get(source, :content)
      assert content =~ "com.example.test"
    end
  end
end
