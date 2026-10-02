defmodule MobDev.ToolchainXcodeTest do
  use ExUnit.Case, async: true

  alias MobDev.Toolchain
  alias Mix.Tasks.Mob.Doctor

  describe "parse_xcodebuild_version/1" do
    test "Xcode 27.0 release" do
      assert {:ok, %{version: {27, 0, 0}, build: "27A266a", beta?: false}} =
               Toolchain.parse_xcodebuild_version("Xcode 27.0\nBuild version 27A266a\n")
    end

    test "Xcode 27.1 (the build on GitHub's xcode-27 image)" do
      assert {:ok, %{version: {27, 1, 0}, build: "27A9269"}} =
               Toolchain.parse_xcodebuild_version("Xcode 27.1\nBuild version 27A9269\n")
    end

    test "a beta build: plain version line, beta build number" do
      assert {:ok, %{version: {27, 2, 0}, build: "27B5019j", beta?: false}} =
               Toolchain.parse_xcodebuild_version("Xcode 27.2\nBuild version 27B5019j\n")
    end

    test "a version line that names the beta" do
      assert {:ok, %{version: {27, 1, 0}, beta?: true}} =
               Toolchain.parse_xcodebuild_version("Xcode 27.1 beta 3\nBuild version 27B5001e")
    end

    test "patch versions and a single-number version" do
      assert {:ok, %{version: {26, 4, 1}}} =
               Toolchain.parse_xcodebuild_version("Xcode 26.4.1\nBuild version 17E202")

      assert {:ok, %{version: {16, 0, 0}}} =
               Toolchain.parse_xcodebuild_version("Xcode 16\nBuild version 16A242d")
    end

    test "tolerates noise lines before the version (CRLF, warnings)" do
      out =
        "2026-10-01 xcodebuild[123] [MT] DVTPlugInLoading: warning\r\nXcode 27.0\r\nBuild version 27A266a\r\n"

      assert {:ok, %{version: {27, 0, 0}, build: "27A266a"}} =
               Toolchain.parse_xcodebuild_version(out)
    end

    test "rejects output without an Xcode version" do
      assert :error =
               Toolchain.parse_xcodebuild_version(
                 "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer " <>
                   "directory '/Library/Developer/CommandLineTools' is a command line tools instance"
               )

      assert :error = Toolchain.parse_xcodebuild_version("Xcode abc\nBuild version 1")
    end
  end

  describe "parse_version/1" do
    test "SDK versions" do
      assert {:ok, {27, 0, 0}} = Toolchain.parse_version("27.0\n")
      assert {:ok, {27, 1, 0}} = Toolchain.parse_version("27.1")
      assert {:ok, {26, 5, 0}} = Toolchain.parse_version("26.5")
      assert {:ok, {27, 1, 2}} = Toolchain.parse_version("27.1.2.9")
    end

    test "rejects non-versions" do
      assert :error = Toolchain.parse_version("")
      assert :error = Toolchain.parse_version("27.x")
      assert :error = Toolchain.parse_version("xcrun: error: SDK \"iphoneos\" cannot be located")
    end
  end

  describe "parse_sdk_version/1" do
    test "plain xcrun output" do
      assert {:ok, {27, 0, 0}} = Toolchain.parse_sdk_version("27.0\n")
      assert {:ok, {26, 5, 0}} = Toolchain.parse_sdk_version("26.5")
    end

    test "skips warnings xcrun prints before the version (stderr is merged)" do
      out =
        "2026-10-01 xcrun[42:7] [MT] DVTSDK: Warning: SDK path collision for path 'x': SDK 27.0\n" <>
          "27.0\n"

      assert {:ok, {27, 0, 0}} = Toolchain.parse_sdk_version(out)
    end

    test "rejects output with no version line" do
      assert :error =
               Toolchain.parse_sdk_version("xcrun: error: SDK \"iphoneos\" cannot be located\n")

      assert :error = Toolchain.parse_sdk_version("")
    end
  end

  describe "duo_supported?/2" do
    test "27.1 and later, by numeric (not string) comparison" do
      assert Toolchain.duo_supported?({27, 1, 0}, {27, 1, 0})
      assert Toolchain.duo_supported?({27, 10, 0}, {27, 10, 0})
      assert Toolchain.duo_supported?({28, 0, 0}, {28, 0, 0})
      refute Toolchain.duo_supported?({27, 0, 9}, {27, 0, 0})
      refute Toolchain.duo_supported?({26, 6, 0}, {26, 5, 0})
    end

    test "both the Xcode and its iOS SDK must qualify, and be known" do
      refute Toolchain.duo_supported?({27, 1, 0}, {27, 0, 0})
      refute Toolchain.duo_supported?({27, 1, 0}, nil)
      refute Toolchain.duo_supported?(nil, {27, 1, 0})
    end
  end

  describe "Doctor.__xcode_checks__/1" do
    defp probe(xcodebuild, sdk, dir \\ "/Applications/Xcode-27.0.app/Contents/Developer") do
      %{xcodebuild: xcodebuild, ios_sdk: sdk, developer_dir: dir}
    end

    test "Xcode 27.0: reports both versions and warns that Duo is unsupported" do
      rows =
        Doctor.__xcode_checks__(probe({"Xcode 27.0\nBuild version 27A266a\n", 0}, {"27.0\n", 0}))

      assert [
               {:ok, "Xcode", "27.0 (27A266a) — /Applications/Xcode-27.0.app", nil},
               {:ok, "iOS SDK", "27.0", nil},
               {:warn, "iPhone Duo", duo, fix}
             ] = rows

      assert duo =~ "unsupported (needs Xcode 27.1+)"
      assert duo =~ "Xcode 27.0, iOS SDK 27.0"
      assert fix =~ "DEVELOPER_DIR"
    end

    test "Xcode 26.6 selected through DEVELOPER_DIR" do
      rows =
        Doctor.__xcode_checks__(
          probe(
            {"Xcode 26.6\nBuild version 17F113\n", 0},
            {"26.5\n", 0},
            "/Applications/Xcode-26.6.app/Contents/Developer"
          )
        )

      assert [
               {:ok, "Xcode", "26.6 (17F113) — /Applications/Xcode-26.6.app", nil},
               {:ok, "iOS SDK", "26.5", nil},
               {:warn, "iPhone Duo", duo, _}
             ] = rows

      assert duo =~ "Xcode 26.6, iOS SDK 26.5"
    end

    test "Xcode 27.1 with the 27.1 SDK supports Duo" do
      rows =
        Doctor.__xcode_checks__(
          probe(
            {"Xcode 27.1\nBuild version 27A9269\n", 0},
            {"27.1\n", 0},
            "/Applications/Xcode.app/Contents/Developer"
          )
        )

      assert [
               {:ok, "Xcode", _, nil},
               {:ok, "iOS SDK", "27.1", nil},
               {:ok, "iPhone Duo", duo, nil}
             ] = rows

      assert duo =~ "supported"
    end

    test "a selected Xcode-beta.app is labelled beta" do
      rows =
        Doctor.__xcode_checks__(
          probe(
            {"Xcode 27.1\nBuild version 27B5001e\n", 0},
            {"27.1\n", 0},
            "/Applications/Xcode-beta.app/Contents/Developer"
          )
        )

      assert [
               {:ok, "Xcode", "27.1 beta (27B5001e) — /Applications/Xcode-beta.app", nil},
               _,
               {:ok, "iPhone Duo", _, _}
             ] =
               rows
    end

    test "the 27.1 Xcode with an older SDK still warns" do
      rows = Doctor.__xcode_checks__(probe({"Xcode 27.1\nBuild version 27A9269", 0}, {"27.0", 0}))
      assert {:warn, "iPhone Duo", _, _} = List.last(rows)
    end

    test "Xcode older than 15 still fails" do
      assert [{:fail, "Xcode", detail, _}, _, {:warn, "iPhone Duo", _, _}] =
               Doctor.__xcode_checks__(
                 probe({"Xcode 14.3\nBuild version 14E222b", 0}, {"16.4", 0})
               )

      assert detail =~ "Xcode 14.3 found — Xcode 15 or later required"
    end

    test "a missing iOS platform warns but never fails" do
      rows =
        Doctor.__xcode_checks__(
          probe(
            {"Xcode 27.0\nBuild version 27A266a", 0},
            {"xcrun: error: SDK \"iphoneos\" cannot be located", 1}
          )
        )

      assert [
               {:ok, "Xcode", _, nil},
               {:warn, "iOS SDK", detail, fix},
               {:warn, "iPhone Duo", duo, _}
             ] = rows

      assert detail =~ "cannot be located"
      assert fix =~ "-downloadPlatform iOS"
      assert duo =~ "selected: Xcode 27.0"
    end

    test "Xcode 27.1 without a readable iOS SDK is not reported as Duo-ready" do
      rows =
        Doctor.__xcode_checks__(
          probe(
            {"Xcode 27.1\nBuild version 27A9269", 0},
            {"xcrun: error: SDK \"iphoneos\" cannot be located", 1}
          )
        )

      assert {:warn, "iPhone Duo", duo, nil} = List.last(rows)
      assert duo =~ "unconfirmed — iOS SDK version unreadable (selected: Xcode 27.1)"
    end

    test "command line tools only: warnings, no Duo row" do
      clt =
        "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory"

      assert [{:warn, "Xcode", _, _}, {:warn, "iOS SDK", _, _}] =
               Doctor.__xcode_checks__(
                 probe({clt, 1}, {clt, 1}, "/Library/Developer/CommandLineTools")
               )
    end

    test "no Xcode row ever fails for a modern Xcode" do
      for {xcode, sdk} <- [{"26.6", "26.5"}, {"27.0", "27.0"}, {"27.1", "27.1"}, {"27.2", "27.2"}] do
        rows = Doctor.__xcode_checks__(probe({"Xcode #{xcode}\nBuild version X", 0}, {sdk, 0}))
        refute Enum.any?(rows, &match?({:fail, _, _, _}, &1)), inspect(rows)
      end
    end
  end
end
