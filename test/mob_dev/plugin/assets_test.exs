defmodule MobDev.Plugin.AssetsTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Assets

  describe "migration_copies/2" do
    test "namespaces each plugin migration into the host migrations dir, preserving the version" do
      plugin_migrations = [
        %{repo_namespace: "kv_", files: ["/p/priv/repo/migrations/20260101_create.exs"]},
        %{repo_namespace: "iap_", files: ["/q/migrations/20260102_add.exs"]}
      ]

      assert Assets.migration_copies(plugin_migrations, "/host/priv/repo/migrations") == [
               {"/p/priv/repo/migrations/20260101_create.exs",
                "/host/priv/repo/migrations/20260101_kv_create.exs"},
               {"/q/migrations/20260102_add.exs",
                "/host/priv/repo/migrations/20260102_iap_add.exs"}
             ]
    end
  end

  describe "namespaced_filename/2" do
    test "inserts the namespace into the name part, keeping the version prefix for Ecto" do
      assert Assets.namespaced_filename("kv_", "20260101_create.exs") == "20260101_kv_create.exs"
    end

    test "always inserts the namespace, even when the description starts with it" do
      # No "already namespaced?" guard: a description that coincidentally begins
      # with the namespace text must NOT lose its namespace (that caused
      # cross-vendor collisions). Double-prefixing here is intentional + unique.
      assert Assets.namespaced_filename("kv_", "20260101_kv_create.exs") ==
               "20260101_kv_kv_create.exs"
    end

    test "falls back to a plain prefix when there is no numeric version" do
      assert Assets.namespaced_filename("kv_", "seed.exs") == "kv_seed.exs"
    end
  end

  describe "migration_copies/2 destination uniqueness" do
    test "two sources whose descriptions differ only by the namespace text stay distinct" do
      # Regression for the namespace-drop bug: 20260101_kv_create.exs and
      # 20260101_create.exs under ns "kv_" used to BOTH map to ...kv_create.exs.
      plugin_migrations = [
        %{
          repo_namespace: "kv_",
          files: ["/a/20260101_kv_create.exs", "/a/20260101_create.exs"]
        }
      ]

      dests =
        plugin_migrations
        |> Assets.migration_copies("/host")
        |> Enum.map(fn {_src, dest} -> Path.basename(dest) end)

      assert dests == ["20260101_kv_kv_create.exs", "20260101_kv_create.exs"]
      assert length(Enum.uniq(dests)) == 2
    end

    test "raises a clear error if two distinct sources collide on one destination" do
      # Only reachable if two plugins share a repo_namespace (cross-validation
      # rejects that) — defensive guard against silent clobber.
      plugin_migrations = [
        %{repo_namespace: "kv_", files: ["/a/20260101_create.exs"]},
        %{repo_namespace: "kv_", files: ["/b/20260101_create.exs"]}
      ]

      assert_raise RuntimeError, ~r/migration filename collision/, fn ->
        Assets.migration_copies(plugin_migrations, "/host")
      end
    end
  end

  describe "android_font_resource_name/1" do
    test "lowercases, drops the extension, and underscores non-alnum" do
      assert Assets.android_font_resource_name("Georgia.ttf") == "georgia"
      assert Assets.android_font_resource_name("Inter-Regular.otf") == "inter_regular"
      assert Assets.android_font_resource_name("My Font 2.ttf") == "my_font_2"
    end

    test "prefixes a non-letter leading char so it is a valid resource id" do
      assert Assets.android_font_resource_name("123Sans.ttf") == "f_123sans"
    end
  end

  describe "plan_ios_font_bundle/1" do
    test "maps each font to its bundle basename" do
      assert Assets.plan_ios_font_bundle(["/p/Georgia.ttf", "/q/Inter.otf"]) ==
               {:ok, [{"/p/Georgia.ttf", "Georgia.ttf"}, {"/q/Inter.otf", "Inter.otf"}]}
    end

    test "dedups an identical source path" do
      assert {:ok, [{"/p/X.ttf", "X.ttf"}]} =
               Assets.plan_ios_font_bundle(["/p/X.ttf", "/p/X.ttf"])
    end

    test "errors when two distinct sources share a basename (silent-overwrite bug)" do
      assert {:error, {:font_basename_collision, "Icons.ttf", srcs}} =
               Assets.plan_ios_font_bundle(["/p1/Icons.ttf", "/p2/Icons.ttf"])

      assert "/p1/Icons.ttf" in srcs and "/p2/Icons.ttf" in srcs
    end
  end

  describe "plan_android_font_copies/1" do
    test "maps each font to its normalised resource filename" do
      assert Assets.plan_android_font_copies(["/p/Georgia.ttf"]) ==
               {:ok, [{"/p/Georgia.ttf", "georgia.ttf"}]}
    end

    test "errors when two sources normalise to the same resource name" do
      # Inter-Regular.ttf and Inter_Regular.ttf both → inter_regular.ttf
      assert {:error, {:font_resource_collision, "inter_regular.ttf", srcs}} =
               Assets.plan_android_font_copies(["/p/Inter-Regular.ttf", "/q/Inter_Regular.ttf"])

      assert length(srcs) == 2
    end
  end

  describe "image_bundle_path/2" do
    test "maps plugin + basename to the conventional bundle path" do
      assert Assets.image_bundle_path(:kv, "icon.png") == "assets/plugin/kv/icon.png"
    end
  end

  describe "merge_ui_app_fonts/2" do
    @plist """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    \t<key>CFBundleName</key>
    \t<string>App</string>
    </dict>
    </plist>
    """

    test "no fonts leaves the plist unchanged" do
      assert Assets.merge_ui_app_fonts(@plist, []) == @plist
    end

    test "creates the UIAppFonts array when absent" do
      out = Assets.merge_ui_app_fonts(@plist, ["icons.ttf"])
      assert out =~ "<key>UIAppFonts</key>"
      assert out =~ "<string>icons.ttf</string>"
      assert Assets.parse_ui_app_fonts(out) == ["icons.ttf"]
    end

    test "merges into an existing array and de-dups" do
      with_array = Assets.merge_ui_app_fonts(@plist, ["a.ttf"])
      out = Assets.merge_ui_app_fonts(with_array, ["a.ttf", "b.ttf"])
      assert Assets.parse_ui_app_fonts(out) == ["a.ttf", "b.ttf"]
    end

    test "a font basename containing a regex backreference is emitted verbatim (create path)" do
      out = Assets.merge_ui_app_fonts(@plist, ["x\\1y.ttf"])
      # The \1 must NOT be expanded into the captured </dict></plist> closing.
      assert Assets.parse_ui_app_fonts(out) == ["x\\1y.ttf"]
      assert out =~ "</dict>\n</plist>"
      refute out =~ "<string>x\n"
    end

    test "a font basename containing a regex backreference is emitted verbatim (replace path)" do
      with_array = Assets.merge_ui_app_fonts(@plist, ["a.ttf"])
      out = Assets.merge_ui_app_fonts(with_array, ["b\\1c.ttf"])
      assert Assets.parse_ui_app_fonts(out) == ["a.ttf", "b\\1c.ttf"]
    end
  end
end
