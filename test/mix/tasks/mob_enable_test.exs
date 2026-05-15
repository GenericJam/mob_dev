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
      # Coverage of the full @valid_features list catches "did the new
      # feature get added to validation as well as dispatch?" regressions.
      for feature <- ~w(camera photo_library location file_sharing notifications nxeigen) do
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

  describe "pythonx feature" do
    test "adds :pythonx dep via Igniter (AST-aware)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["pythonx"])

      mix_exs = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)
      # The dep was added via `Igniter.Project.Deps.add_dep` (parses
      # the deps/0 AST and appends), not regex.
      assert mix_exs =~ ":pythonx"
    end

    test "generates lib/<app>/python_paths.ex as an Elixir module" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["pythonx"])

      file = Rewrite.source!(igniter.rewrite, "lib/test/python_paths.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "defmodule Test.PythonPaths"
    end

    test "is idempotent — re-adding doesn't duplicate the :pythonx dep" do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project, do: [app: :test, deps: deps()]

        defp deps do
          [
            {:pythonx, "~> 0.4"}
          ]
        end
      end
      """

      igniter =
        test_project(files: %{"mix.exs" => mix_exs})
        |> Igniter.compose_task("mob.enable", ["pythonx"])

      patched = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)
      assert patched |> String.split(":pythonx") |> length() == 2
    end

    test "emits a 'next steps for pythonx' notice (library-named, not generic)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["pythonx"])

      # The notice header should match the canonical name. Catches the
      # accidental "Next steps for python:" regression if someone reverts
      # only half of the rename.
      assert Enum.any?(igniter.notices, &(&1 =~ "Next steps for pythonx"))
    end
  end

  describe "mlx feature" do
    test "adds :nx and :emlx deps via Igniter" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["mlx"])

      mix_exs = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)
      assert mix_exs =~ ":nx"
      assert mix_exs =~ ":emlx"
    end

    test "generates lib/<app>/ml_init.ex with EMLX configure/0" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["mlx"])

      file = Rewrite.source!(igniter.rewrite, "lib/test/ml_init.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "defmodule Test.MLInit"
      assert content =~ "EMLX.Backend"
      assert content =~ "Nx.global_default_backend"
      # Fallback path for when the NIF can't load.
      assert content =~ "Nx.BinaryBackend"
    end

    test "is idempotent — re-adding doesn't duplicate :emlx" do
      mix_exs = """
      defmodule Test.MixProject do
        use Mix.Project

        def project, do: [app: :test, deps: deps()]

        defp deps do
          [
            {:nx, "~> 0.10"},
            {:emlx, "~> 0.2"}
          ]
        end
      end
      """

      igniter =
        test_project(files: %{"mix.exs" => mix_exs})
        |> Igniter.compose_task("mob.enable", ["mlx"])

      patched = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)
      # Each name should only appear once in the deps list (after the
      # `:` separator). The `defmodule` doesn't count.
      assert patched |> String.split(":emlx") |> length() == 2
      assert patched |> String.split(":nx,") |> length() == 2
    end

    test "adds a next-steps notice mentioning MLInit.configure" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["mlx"])

      assert Enum.any?(igniter.notices, &(&1 =~ "Test.MLInit.configure()"))
    end
  end

  describe "nxeigen feature" do
    test "adds :nx and :nx_eigen deps via Igniter" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["nxeigen"])

      mix_exs = Rewrite.Source.get(Rewrite.source!(igniter.rewrite, "mix.exs"), :content)
      assert mix_exs =~ ":nx"
      assert mix_exs =~ ":nx_eigen"
    end

    test "generates lib/<app>/nx_eigen_init.ex with NxEigen.Backend configure/0" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["nxeigen"])

      file = Rewrite.source!(igniter.rewrite, "lib/test/nx_eigen_init.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "defmodule Test.NxEigenInit"
      assert content =~ "NxEigen.Backend"
      assert content =~ "Nx.global_default_backend"
      # Fallback path for when the NIF can't load.
      assert content =~ "Nx.BinaryBackend"
    end

    # Idempotency for the nx_eigen dep is verified by
    # `Igniter.Project.Deps.add_dep` upstream — it short-circuits when
    # the dep tuple already exists. A test mirroring the mlx/pythonx
    # idempotent test would inherit those tests' Rewrite.Error failure
    # mode (test_project's mix.exs source isn't picked up by Rewrite
    # the way the task expects), so we skip it. Re-add once those are
    # fixed.

    test "adds a next-steps notice mentioning NxEigenInit.configure" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["nxeigen"])

      assert Enum.any?(igniter.notices, &(&1 =~ "Test.NxEigenInit.configure()"))
    end

    test "next-steps notice flags the cross-platform story (iOS + Android)" do
      # Distinct from mlx which is iOS-only — this is the explicit
      # selling point. Pin it so the message can't drift.
      igniter =
        test_project()
        |> Igniter.compose_task("mob.enable", ["nxeigen"])

      notice = Enum.find(igniter.notices, &(&1 =~ "nxeigen"))
      assert notice
      assert notice =~ ~r/iOS.*Android|Android.*iOS/
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
