defmodule MobDev.Plugin.MergeTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Merge

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  describe "nifs/1" do
    test "resolves native_dir to an absolute path under the plugin dir" do
      plugins = [{"/abs/plug", base(%{nifs: [%{module: P.Nif, native_dir: "priv/native/jni"}]})}]
      assert [%{module: P.Nif, native_dir: "/abs/plug/priv/native/jni"}] = Merge.nifs(plugins)
    end

    test "combines nifs across plugins and ignores tier-0 (nil) manifests" do
      plugins = [
        {"/a", base(%{nifs: [%{module: A, native_dir: "priv/jni"}]})},
        {"/palette", nil},
        {"/b", base(%{nifs: [%{module: B, native_dir: "priv/jni"}]})}
      ]

      assert [%{module: A}, %{module: B}] = Merge.nifs(plugins)
    end

    test "leaves a nif without native_dir untouched" do
      plugins = [{"/a", base(%{nifs: [%{module: A}]})}]
      assert [%{module: A}] = Merge.nifs(plugins)
    end
  end

  describe "android_permissions/1 + gradle_deps/1 + ios_frameworks/1" do
    test "uniquifies across plugins" do
      plugins = [
        {"/a",
         base(%{
           android: %{permissions: ["P.CAMERA"], gradle_deps: ["g:1"]},
           ios: %{frameworks: ["CoreHaptics"]}
         })},
        {"/b",
         base(%{
           android: %{permissions: ["P.CAMERA", "P.MIC"], gradle_deps: ["g:1", "g:2"]},
           ios: %{frameworks: ["CoreHaptics", "AVFoundation"]}
         })}
      ]

      assert Merge.android_permissions(plugins) == ["P.CAMERA", "P.MIC"]
      assert Merge.gradle_deps(plugins) == ["g:1", "g:2"]
      assert Merge.ios_frameworks(plugins) == ["CoreHaptics", "AVFoundation"]
    end

    test "empty when no plugins declare them" do
      assert Merge.android_permissions([{"/a", base(%{})}]) == []
    end
  end

  describe "swift_files/1 + android_sources/1" do
    test "swift_files are absolute, per plugin" do
      plugins = [
        {"/a", base(%{ios: %{swift_files: ["priv/ios/A.swift"]}})},
        {"/b", base(%{ios: %{swift_files: ["priv/ios/B.swift", "priv/ios/C.swift"]}})}
      ]

      assert Merge.swift_files(plugins) ==
               ["/a/priv/ios/A.swift", "/b/priv/ios/B.swift", "/b/priv/ios/C.swift"]
    end

    test "android_sources gathers bridge, jni, and nif dirs, absolute + unique" do
      plugins = [
        {"/a",
         base(%{
           android: %{bridge_kt: "priv/a/Bridge.kt", jni_source: "priv/a/x.c"},
           nifs: [%{module: A, native_dir: "priv/a/jni"}]
         })}
      ]

      sources = Merge.android_sources(plugins)
      assert "/a/priv/a/Bridge.kt" in sources
      assert "/a/priv/a/x.c" in sources
      assert "/a/priv/a/jni" in sources
    end
  end

  describe "nif_sources/1" do
    test "computes <dir>/<native_dir>/<module>.c for each NIF" do
      plugins = [
        {"/a",
         base(%{
           nifs: [
             %{module: :foo_nif, native_dir: "priv/native/jni"},
             %{module: :bar_nif, native_dir: "priv/native/jni"}
           ]
         })}
      ]

      assert Merge.nif_sources(plugins) ==
               ["/a/priv/native/jni/foo_nif.c", "/a/priv/native/jni/bar_nif.c"]
    end

    test "defaults native_dir to priv/native/jni when omitted" do
      plugins = [{"/a", base(%{nifs: [%{module: :foo_nif}]})}]
      assert Merge.nif_sources(plugins) == ["/a/priv/native/jni/foo_nif.c"]
    end

    test "ignores tier-0 (nil) manifests and entries without a :module atom" do
      plugins = [
        {"/a", nil},
        {"/b", base(%{nifs: [%{native_dir: "priv/jni"}]})}
      ]

      assert Merge.nif_sources(plugins) == []
    end
  end

  describe "plist_keys/1 + ui_components/1" do
    test "plist_keys merge across plugins" do
      plugins = [
        {"/a", base(%{ios: %{plist_keys: %{"K1" => "a"}}})},
        {"/b", base(%{ios: %{plist_keys: %{"K2" => "b"}}})}
      ]

      assert Merge.plist_keys(plugins) == %{"K1" => "a", "K2" => "b"}
    end

    test "ui_components combine across plugins" do
      plugins = [
        {"/a", base(%{ui_components: [%{atom: :chart}]})},
        {"/b", base(%{ui_components: [%{atom: :gauge}]})}
      ]

      assert [%{atom: :chart}, %{atom: :gauge}] = Merge.ui_components(plugins)
    end
  end
end
