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

    test "is idempotent (does not double-namespace)" do
      assert Assets.namespaced_filename("kv_", "20260101_kv_create.exs") ==
               "20260101_kv_create.exs"
    end

    test "falls back to a plain prefix when there is no numeric version" do
      assert Assets.namespaced_filename("kv_", "seed.exs") == "kv_seed.exs"
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
  end
end
