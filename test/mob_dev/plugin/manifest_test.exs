defmodule MobDev.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Manifest

  @valid %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}

  describe "load/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mob_manifest_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "priv"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns nil when no manifest file exists (tier-0 plugin)", %{dir: dir} do
      assert {:ok, nil} = Manifest.load(dir)
    end

    test "reads and returns a manifest map", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(@valid))
      assert {:ok, %{name: :mob_demo}} = Manifest.load(dir)
    end

    test "errors when the file does not evaluate to a map", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), ":not_a_map")
      assert {:error, msg} = Manifest.load(dir)
      assert msg =~ "must evaluate to a map"
    end

    test "errors (does not raise) on a malformed manifest file", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "%{name: :x,,,}")
      assert {:error, msg} = Manifest.load(dir)
      assert msg =~ "failed to evaluate"
    end
  end

  describe "validate/1 android.manifest_application_snippets + res_files" do
    test "accepts well-formed snippets and res_files" do
      m =
        Map.put(@valid, :android, %{
          manifest_application_snippets: [~s(<service android:name="io.x.Svc"/>)],
          res_files: ["priv/native/android/res/xml/svc.xml"]
        })

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects non-list / non-string snippets" do
      assert {:error, errs} =
               Manifest.validate(
                 Map.put(@valid, :android, %{manifest_application_snippets: "<x/>"})
               )

      assert Enum.any?(errs, &(&1 =~ "manifest_application_snippets"))

      assert {:error, errs2} =
               Manifest.validate(
                 Map.put(@valid, :android, %{manifest_application_snippets: ["", :nope]})
               )

      assert Enum.any?(errs2, &(&1 =~ "manifest_application_snippets"))
    end

    test "rejects res_files without a res segment (dest can't be derived)" do
      assert {:error, errs} =
               Manifest.validate(Map.put(@valid, :android, %{res_files: ["priv/xml/svc.xml"]}))

      assert Enum.any?(errs, &(&1 =~ "res"))
    end

    test "rejects a non-list res_files" do
      assert {:error, errs} =
               Manifest.validate(Map.put(@valid, :android, %{res_files: "res/xml/x.xml"}))

      assert Enum.any?(errs, &(&1 =~ "res_files"))
    end

    test "rejects a res_files path containing .. (path traversal)" do
      assert {:error, errs} =
               Manifest.validate(
                 Map.put(@valid, :android, %{res_files: ["x/res/../../../build.gradle"]})
               )

      assert Enum.any?(errs, &(&1 =~ ".." or &1 =~ "traversal"))
    end
  end

  describe "validate/1" do
    test "nil (no manifest) is valid" do
      assert {:ok, nil} = Manifest.validate(nil)
    end

    test "accepts a manifest with the three required fields" do
      assert {:ok, @valid} = Manifest.validate(@valid)
    end

    test "rejects a missing/invalid name" do
      assert {:error, errs} = Manifest.validate(Map.delete(@valid, :name))
      assert Enum.any?(errs, &(&1 =~ ":name"))
    end

    test "rejects an invalid mob_version requirement" do
      assert {:error, errs} = Manifest.validate(%{@valid | mob_version: "not a req"})
      assert Enum.any?(errs, &(&1 =~ ":mob_version"))
    end

    test "rejects an unsupported plugin_spec_version" do
      assert {:error, errs} = Manifest.validate(%{@valid | plugin_spec_version: 99})
      assert Enum.any?(errs, &(&1 =~ "plugin_spec_version"))
    end

    test "accepts spec version 2 (code-generated plugins)" do
      m = %{@valid | plugin_spec_version: 2}
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "reports every problem at once, not just the first" do
      assert {:error, errs} = Manifest.validate(%{plugin_spec_version: "nope"})
      assert length(errs) == 3
      assert Enum.any?(errs, &(&1 =~ ":name"))
      assert Enum.any?(errs, &(&1 =~ ":mob_version"))
      assert Enum.any?(errs, &(&1 =~ "plugin_spec_version"))
    end

    test "rejects a non-map manifest" do
      assert {:error, _} = Manifest.validate("nope")
    end

    test "accepts a permissions list with capability + optional ios handler" do
      m =
        Map.put(@valid, :permissions, [
          %{capability: :location, ios: %{handler: "mob_location_request_permission"}},
          %{capability: :sensors}
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects permissions that isn't a list" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :permissions, %{capability: :x}))
      assert Enum.any?(errs, &(&1 =~ "permissions must be a list"))
    end

    test "rejects a permissions entry without a :capability atom" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :permissions, [%{ios: %{}}]))
      assert Enum.any?(errs, &(&1 =~ ":capability"))
    end

    test "rejects a permissions entry whose :ios lacks a :handler string" do
      m = Map.put(@valid, :permissions, [%{capability: :location, ios: %{}}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ ":handler"))
    end

    test "accepts nif entries with a valid :platform (cross-platform plugin)" do
      m =
        Map.put(@valid, :nifs, [
          %{module: :mob_location_nif, native_dir: "priv/native/ios", platform: :ios},
          %{
            module: :mob_location_nif,
            native_dir: "priv/native/jni",
            lang: :zig,
            platform: :android
          },
          %{module: :shared_nif}
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a nif entry with an invalid :platform" do
      m = Map.put(@valid, :nifs, [%{module: :x, platform: :windows}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ ":platform must be :ios or :android"))
    end

    test "rejects a nif entry that is not a map" do
      m = Map.put(@valid, :nifs, ["not_a_map"])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "nifs entry #0 must be a map"))
    end

    test "accepts a valid lang: :cpp_archive nif entry" do
      m =
        Map.put(@valid, :nifs, [
          %{
            module: :nx_eigen,
            lang: :cpp_archive,
            sources: ["c_src/nx_eigen_nif.cpp", "c_src/nx_eigen_fft_eigen.cpp"],
            includes: ["c_src", {:dep, :nx_eigen, "eigen-3.4.0"}],
            cxxflags: ["-std=c++17", "-O3"],
            nm_symbol: "nx_eigen_nif_init"
          }
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "accepts a cpp_archive entry with only the required fields" do
      m =
        Map.put(@valid, :nifs, [
          %{module: :foo, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "foo_nif_init"}
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a cpp_archive whose nm_symbol disagrees with <module>_nif_init" do
      # The exact bug device-verify caught: driver table derives nx_eigen_nif_init
      # from the module, archive exports a different symbol → link failure.
      m =
        Map.put(@valid, :nifs, [
          %{
            module: :nx_eigen_nif,
            lang: :cpp_archive,
            sources: ["a.cpp"],
            nm_symbol: "nx_eigen_nif_init"
          }
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "must be \"nx_eigen_nif_nif_init\""))
    end

    test "rejects a cpp_archive entry missing :sources" do
      m = Map.put(@valid, :nifs, [%{module: :x, lang: :cpp_archive, nm_symbol: "x_init"}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires a non-empty :sources"))
    end

    test "rejects a cpp_archive entry with an empty :sources list" do
      m =
        Map.put(@valid, :nifs, [
          %{module: :x, lang: :cpp_archive, sources: [], nm_symbol: "x_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires a non-empty :sources"))
    end

    test "accepts {:dep, name, subpath} source tokens (dep-sourced C++)" do
      m =
        Map.put(@valid, :nifs, [
          %{
            module: :nx_eigen,
            lang: :cpp_archive,
            sources: [{:dep, :nx_eigen, "c_src/nx_eigen_nif.cpp"}, "c_src/fft.cpp"],
            nm_symbol: "nx_eigen_nif_init"
          }
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a cpp_archive entry with a bogus source entry" do
      m =
        Map.put(@valid, :nifs, [
          %{module: :x, lang: :cpp_archive, sources: [:nope], nm_symbol: "x_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "path strings or {:dep"))
    end

    test "rejects a cpp_archive entry missing :nm_symbol" do
      m = Map.put(@valid, :nifs, [%{module: :x, lang: :cpp_archive, sources: ["a.cpp"]}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires an :nm_symbol"))
    end

    test "rejects a cpp_archive entry missing :module" do
      # Without :module, Merge.static_archives silently drops the entry (its
      # comprehension guards on is_atom(nif[:module])) — fail-open. Catch it.
      m =
        Map.put(@valid, :nifs, [
          %{lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "x_nif_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires a lowercase :module atom"))
    end

    test "rejects a cpp_archive entry with a non-atom :module" do
      # A non-atom :module is dropped at merge; nil would build libnil.a.
      m =
        Map.put(@valid, :nifs, [
          %{module: "x", lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "x_nif_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires a lowercase :module atom"))
    end

    test "rejects a cpp_archive entry with a nil :module" do
      m =
        Map.put(@valid, :nifs, [
          %{module: nil, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "x_nif_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "cpp_archive requires a lowercase :module atom"))
    end

    test "rejects a cpp_archive entry with an aliased (uppercase) :module" do
      # Foo.Bar would yield a wrong-named libElixir.Foo.Bar.a downstream.
      m =
        Map.put(@valid, :nifs, [
          %{module: Foo.Bar, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "x_nif_init"}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "lowercase NIF atom"))
    end
  end

  describe "tier/1" do
    test "no manifest is tier 0" do
      assert Manifest.tier(nil) == 0
    end

    test "minimal manifest (no capability sections) is the tier-1 floor" do
      assert Manifest.tier(@valid) == 1
    end

    test "NIFs are tier 1" do
      assert Manifest.tier(Map.put(@valid, :nifs, [])) == 1
    end

    test "ui_components are tier 2" do
      assert Manifest.tier(Map.put(@valid, :ui_components, [])) == 2
    end

    test "permissions are tier 1 (native capability)" do
      assert Manifest.tier(Map.put(@valid, :permissions, [%{capability: :location}])) == 1
    end

    test "screens are tier 3" do
      assert Manifest.tier(Map.put(@valid, :screens, [])) == 3
    end

    test "screens_generator (spec 2) is tier 3" do
      assert Manifest.tier(Map.put(@valid, :screens_generator, {M, :f, []})) == 3
    end

    test "lifecycle is tier 4" do
      assert Manifest.tier(Map.put(@valid, :lifecycle, %{})) == 4
    end

    test "highest matching section wins" do
      m = @valid |> Map.put(:nifs, []) |> Map.put(:ui_components, []) |> Map.put(:lifecycle, %{})
      assert Manifest.tier(m) == 4
    end
  end

  describe "hot_pushable/1" do
    test "no manifest (pure Elixir tier 0) is hot-pushable" do
      assert Manifest.hot_pushable(nil) == true
    end

    test "minimal manifest with no native sections is hot-pushable" do
      assert Manifest.hot_pushable(@valid) == true
    end

    test "NIF plugin is not hot-pushable" do
      assert Manifest.hot_pushable(Map.put(@valid, :nifs, [])) == false
    end

    test "a NATIVE-backed visual plugin is not hot-pushable" do
      native = [%{tag: "Sig", atom: :sig, ios: %{view_module: "Sig_View"}}]
      assert Manifest.hot_pushable(Map.put(@valid, :ui_components, native)) == false
    end

    test "an expand-only (pure-Elixir composite) visual plugin IS hot-pushable" do
      comps = [%{tag: "Card", atom: :card, expand: {Kit, :card}}]
      assert Manifest.hot_pushable(Map.put(@valid, :ui_components, comps)) == true
      # …and still classifies as tier 2 (visual).
      assert Manifest.tier(Map.put(@valid, :ui_components, comps)) == 2
    end

    test "native + Elixir screens is partial" do
      m = @valid |> Map.put(:nifs, []) |> Map.put(:screens, [])
      assert Manifest.hot_pushable(m) == :partial
    end

    test "pure-Elixir screens (no native) is hot-pushable" do
      assert Manifest.hot_pushable(Map.put(@valid, :screens, [])) == true
    end
  end

  describe "validate/1 — tier 3 sections" do
    @v2 %{name: :p, mob_version: "~> 0.6", plugin_spec_version: 2}

    test "accepts a valid static screens list" do
      m = Map.put(@valid, :screens, [%{module: MyPlugin.ListScreen, default_route: "/p/list"}])
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a screen entry missing module or default_route" do
      m = Map.put(@valid, :screens, [%{module: MyPlugin.ListScreen}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "screens entry"))
    end

    test "rejects screens that is not a list" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :screens, :nope))
      assert Enum.any?(errs, &(&1 =~ "screens must be a list"))
    end

    test "accepts a screens_generator MFA on spec v2" do
      m = Map.put(@v2, :screens_generator, {MyPlugin.Gen, :generate, []})
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects screens_generator on spec v1 (needs v2)" do
      m = Map.put(@valid, :screens_generator, {MyPlugin.Gen, :generate, []})
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "requires plugin_spec_version: 2"))
    end

    test "rejects declaring both static screens and a generator" do
      m =
        @v2
        |> Map.put(:screens, [%{module: A, default_route: "/a"}])
        |> Map.put(:screens_generator, {G, :g, []})

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "mutually exclusive"))
    end

    test "rejects a malformed screens_generator (not an MFA)" do
      m = Map.put(@v2, :screens_generator, "Gen.generate")
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "must be an {Module, :function, args} tuple"))
    end

    test "accepts valid migrations" do
      m =
        Map.put(@valid, :migrations, %{
          repo_namespace: "p_",
          migrations_dir: "priv/repo/migrations"
        })

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects migrations missing keys" do
      m = Map.put(@valid, :migrations, %{repo_namespace: "p_"})
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "migrations must be a map"))
    end

    test "accepts assets with font and image path lists" do
      m = Map.put(@valid, :assets, %{fonts: ["priv/assets/x.ttf"], images: ["priv/assets/y.png"]})
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects assets with a non-string path" do
      m = Map.put(@valid, :assets, %{fonts: [:not_a_path]})
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "assets.fonts must be a list of path strings"))
    end
  end

  describe "validate/1 — tier 4 sections" do
    test "accepts a full lifecycle map" do
      lc = %{
        on_start: {P, :start, []},
        supervised: [P.Worker, {P.Other, []}],
        on_resume: {P, :on_resume, []},
        on_background: {P, :on_background, []}
      }

      m = Map.put(@valid, :lifecycle, lc)
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a non-MFA lifecycle.on_start" do
      m = Map.put(@valid, :lifecycle, %{on_start: :start})
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "lifecycle.on_start"))
    end

    test "rejects a non-list lifecycle.supervised" do
      m = Map.put(@valid, :lifecycle, %{supervised: P.Worker})
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "lifecycle.supervised must be a list"))
    end

    test "accepts a valid settings schema with editor screen" do
      settings = %{
        schema: [
          %{key: :sound, type: :boolean, default: true},
          %{key: :channel, type: :string, default: "#general"}
        ],
        editor_screen: P.SettingsScreen
      }

      m = Map.put(@valid, :settings, settings)
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects an unsupported setting type" do
      settings = %{schema: [%{key: :x, type: :float, default: 1.0}]}
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :settings, settings))
      assert Enum.any?(errs, &(&1 =~ ":type must be one of"))
    end

    test "rejects a setting entry without a default" do
      settings = %{schema: [%{key: :x, type: :integer}]}
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :settings, settings))
      assert Enum.any?(errs, &(&1 =~ "requires a :default"))
    end

    test "accepts notification handlers with map and predicate-MFA matches" do
      notes = %{
        handlers: [
          %{match: %{type: "chat"}, handler: {P.Notif, :handle, 1}},
          %{match: {P.Notif, :matches?, 1}, handler: {P.Notif, :catch_all, 1}}
        ]
      }

      m = Map.put(@valid, :notifications, notes)
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a notification handler whose handler is an args-MFA not arity" do
      notes = %{handlers: [%{match: %{type: "x"}, handler: {P, :h, []}}]}
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :notifications, notes))
      assert Enum.any?(errs, &(&1 =~ ":handler must be a {Module, :function, arity} tuple"))
    end

    test "rejects a notification handler with a bad match" do
      notes = %{handlers: [%{match: "chat", handler: {P, :h, 1}}]}
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :notifications, notes))

      assert Enum.any?(
               errs,
               &(&1 =~ ":match must be a map or a {Module, :function, arity} predicate")
             )
    end
  end

  describe "host_requirements" do
    test "accepts a list of non-empty strings (optional key)" do
      m = Map.put(@valid, :host_requirements, ["add <service .../> to AndroidManifest"])
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "rejects a non-list" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :host_requirements, "oops"))
      assert Enum.any?(errs, &(&1 =~ "host_requirements must be a list"))
    end

    test "rejects empty or non-string entries" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :host_requirements, ["ok", ""]))
      assert Enum.any?(errs, &(&1 =~ "non-empty strings"))

      assert {:error, errs} =
               Manifest.validate(Map.put(@valid, :host_requirements, [:not_a_string]))

      assert Enum.any?(errs, &(&1 =~ "non-empty strings"))
    end
  end

  describe "ui_components validation (native XOR expand)" do
    test "a native-backed entry validates" do
      m =
        Map.put(@valid, :ui_components, [
          %{tag: "Sig", atom: :sig, ios: %{view_module: "Sig_View"}}
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "an expand entry ({Module, :function}) validates" do
      m =
        Map.put(@valid, :ui_components, [
          %{tag: "MishkaCombobox", atom: :mishka_combobox, expand: {Mishka.Combobox, :expand}}
        ])

      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "neither native nor expand is an error" do
      m = Map.put(@valid, :ui_components, [%{tag: "X", atom: :x}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "needs native backing"))
    end

    test "mixing expand with native backing is an error" do
      m =
        Map.put(@valid, :ui_components, [
          %{tag: "X", atom: :x, expand: {M, :f}, ios: %{view_module: "V"}}
        ])

      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "pick one"))
    end

    test "a malformed expand value is an error" do
      m = Map.put(@valid, :ui_components, [%{tag: "X", atom: :x, expand: :nope}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ "must be {Module, :function}"))
    end

    test "a tag-less entry is an error" do
      m = Map.put(@valid, :ui_components, [%{atom: :x, expand: {M, :f}}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ ":tag string"))
    end
  end
end
