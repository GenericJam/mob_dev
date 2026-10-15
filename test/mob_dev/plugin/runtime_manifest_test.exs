defmodule MobDev.Plugin.RuntimeManifestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.RuntimeManifest

  # A stand-in spec-v2 screens generator. Reads a host-config key (auditable) and
  # emits one screen per configured entry.
  defmodule FakeGen do
    def generate do
      for name <- MobDev.Plugin.host_config(:demo_app, :sections, [:a, :b]) do
        %{module: Module.concat([Gen, :"#{name}"]), default_route: "/gen/#{name}"}
      end
    end

    def reads_undeclared do
      MobDev.Plugin.host_config(:demo_app, :secret_key, nil)
      []
    end

    # Emits a screen missing :default_route (e.g. a typo'd key) — must be
    # rejected at build time, not silently dropped on device.
    def malformed do
      [%{module: Gen.Ok, default_route: "/ok"}, %{module: Gen.Bad}]
    end

    # Emits a non-map (wrong shape) among otherwise-valid specs.
    def non_map do
      [%{module: Gen.Ok, default_route: "/ok"}, "not a screen"]
    end
  end

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  # A manifest with every map-bearing section, each map keyed partly by `a` and
  # `z` (atoms the caller creates). Keys are written in sorted order here;
  # @reverse_order_writer builds the same manifest with every key reversed.
  defp every_section_manifest(a, z) do
    %{
      composites: [%{:atom => :card, :expand => {P.Card, :expand}, :plugin => :p, a => 1, z => 2}],
      default_font: %{:android => "inter_regular", :ios => "Inter", a => 1, z => 2},
      default_style: :brand,
      lifecycle: [%{:on_start => {P, :start, []}, :plugin => :p, a => 1, z => 2}],
      nifs: [P.Nif],
      notification_handlers: [
        %{:handler => {P, :h, 1}, :match => %{:type => "t", a => 1, z => 2}, :plugin => :p}
      ],
      plugins: [:p],
      screens: [%{:default_route => "/p", :module => P.Home, :plugin => :p, a => 1, z => 2}],
      settings: [
        %{:plugin => :p, :schema => [%{:default => 3, :key => :x, a => 1, z => 2}]}
      ],
      styles: [%{:name => :brand, :theme => %{:colors => %{a => 1, z => 2}, a => 1, z => 2}}]
    }
  end

  # Run in a fresh VM: creates `z` before `a` and writes every map literal in
  # reverse key order, so each atom's creation order is the reverse of this
  # VM's. Prints the written path.
  @reverse_order_writer """
  [root, a_name, z_name] = System.argv()
  z = String.to_atom(z_name)
  a = String.to_atom(a_name)

  manifest = %{
    styles: [%{:theme => %{z => 2, a => 1, :colors => %{z => 2, a => 1}}, :name => :brand}],
    settings: [%{:schema => [%{z => 2, a => 1, :key => :x, :default => 3}], :plugin => :p}],
    screens: [%{z => 2, a => 1, :plugin => :p, :module => P.Home, :default_route => "/p"}],
    plugins: [:p],
    notification_handlers: [
      %{:plugin => :p, :match => %{z => 2, a => 1, :type => "t"}, :handler => {P, :h, 1}}
    ],
    nifs: [P.Nif],
    lifecycle: [%{z => 2, a => 1, :plugin => :p, :on_start => {P, :start, []}}],
    default_style: :brand,
    default_font: %{z => 2, a => 1, :ios => "Inter", :android => "inter_regular"},
    composites: [%{z => 2, a => 1, :plugin => :p, :expand => {P.Card, :expand}, :atom => :card}]
  }

  IO.puts(MobDev.Plugin.RuntimeManifest.write(root, manifest))
  """

  describe "build/1" do
    test "combines static and generated screens, each tagged with its plugin" do
      plugins = [
        {"/a", base(%{name: :a, screens: [%{module: A.Home, default_route: "/a"}]})},
        {"/g",
         base(%{
           name: :g,
           plugin_spec_version: 2,
           screens_generator: {FakeGen, :generate, []},
           host_config_keys: [:sections]
         })}
      ]

      manifest = RuntimeManifest.build(plugins)

      assert Enum.any?(manifest.screens, &match?(%{module: A.Home, plugin: :a}, &1))
      routes = Enum.map(manifest.screens, & &1.default_route)
      assert "/gen/a" in routes
      assert "/gen/b" in routes
    end

    test "a generator reading an undeclared host-config key fails the build" do
      plugins = [
        {"/g",
         base(%{
           name: :g,
           plugin_spec_version: 2,
           screens_generator: {FakeGen, :reads_undeclared, []},
           host_config_keys: []
         })}
      ]

      assert_raise ArgumentError, ~r/not declared in its manifest :host_config_keys/, fn ->
        RuntimeManifest.build(plugins)
      end
    end

    test "a generator emitting a screen missing :default_route fails the build" do
      plugins = [
        {"/g",
         base(%{
           name: :g,
           plugin_spec_version: 2,
           screens_generator: {FakeGen, :malformed, []},
           host_config_keys: []
         })}
      ]

      assert_raise ArgumentError, ~r/produced an invalid screen at index 1/, fn ->
        RuntimeManifest.build(plugins)
      end
    end

    test "a generator emitting a non-map screen spec fails the build" do
      plugins = [
        {"/g",
         base(%{
           name: :g,
           plugin_spec_version: 2,
           screens_generator: {FakeGen, :non_map, []},
           host_config_keys: []
         })}
      ]

      assert_raise ArgumentError, ~r/produced an invalid screen/, fn ->
        RuntimeManifest.build(plugins)
      end
    end

    test "collects lifecycle, settings, and notification_handlers" do
      plugins = [
        {"/p",
         base(%{
           name: :p,
           lifecycle: %{on_start: {P, :start, []}},
           settings: %{schema: [%{key: :x, type: :boolean, default: true}]},
           notifications: %{handlers: [%{match: %{type: "t"}, handler: {P, :h, 1}}]}
         })}
      ]

      manifest = RuntimeManifest.build(plugins)
      assert [%{plugin: :p, on_start: {P, :start, []}}] = manifest.lifecycle
      assert [%{plugin: :p}] = manifest.settings
      assert [%{plugin: :p, handler: {P, :h, 1}}] = manifest.notification_handlers
    end

    test "collects + dedups plugin NIF module atoms (core loads them at boot)" do
      plugins = [
        {"/p",
         base(%{
           name: :p,
           nifs: [
             %{module: :p_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
             %{module: :p_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
           ]
         })},
        {"/q",
         base(%{
           name: :q,
           nifs: [
             %{module: :q_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
           ]
         })}
      ]

      # :p_nif declared for both platforms collapses to one entry.
      assert RuntimeManifest.build(plugins).nifs == [:p_nif, :q_nif]
    end

    test "nifs is empty when no plugin declares a NIF" do
      assert RuntimeManifest.build([{"/p", base(%{name: :p})}]).nifs == []
    end

    test "plugins names every activated plugin's OTP app, in activation order, whatever its tier" do
      plugins = [
        # NIF-only and component-only plugins have no lifecycle entry, so this
        # key is the only thing that tells core to start their application.
        {"/n", base(%{name: :nif_only, nifs: [%{module: :n_nif}]})},
        {"/l", base(%{name: :with_lifecycle, lifecycle: %{on_start: {L, :start, []}}})},
        {"/zero", nil},
        {"/n2", base(%{name: :nif_only})}
      ]

      assert RuntimeManifest.build(plugins).plugins == [:nif_only, :with_lifecycle]
    end

    test "a multi-tier plugin (screens_generator + tier-4 sections) keeps ALL its sections" do
      # Regression for a composition bug: a plugin carrying both a spec-v2
      # screens_generator AND tier-4 lifecycle/settings/notifications must not
      # have the tier-4 sections dropped from the runtime manifest.
      plugins = [
        {"/g",
         base(%{
           name: :g,
           plugin_spec_version: 2,
           screens_generator: {FakeGen, :generate, []},
           host_config_keys: [:sections],
           lifecycle: %{on_start: {G, :start, []}, supervised: [G.Worker]},
           settings: %{schema: [%{key: :verbose, type: :boolean, default: false}]},
           notifications: %{handlers: [%{match: %{type: "g_ping"}, handler: {G, :h, 1}}]}
         })}
      ]

      manifest = RuntimeManifest.build(plugins)
      assert [%{plugin: :g, supervised: [G.Worker]}] = manifest.lifecycle
      assert [%{plugin: :g}] = manifest.settings
      assert [%{plugin: :g, match: %{type: "g_ping"}}] = manifest.notification_handlers
    end
  end

  describe "validate_generated_screens/2" do
    test "passes a list of valid screen specs through unchanged" do
      screens = [%{module: A, default_route: "/a"}, %{module: B, default_route: "/b"}]
      assert RuntimeManifest.validate_generated_screens(screens, :p) == screens
    end

    test "wraps a single bare map" do
      screen = %{module: A, default_route: "/a"}
      assert RuntimeManifest.validate_generated_screens(screen, :p) == [screen]
    end

    test "raises on a map missing :module" do
      assert_raise ArgumentError, ~r/invalid screen at index 0/, fn ->
        RuntimeManifest.validate_generated_screens([%{default_route: "/a"}], :p)
      end
    end

    test "raises on a map missing :default_route" do
      assert_raise ArgumentError, fn ->
        RuntimeManifest.validate_generated_screens([%{module: A}], :p)
      end
    end

    test "raises when :default_route is not a binary" do
      assert_raise ArgumentError, fn ->
        RuntimeManifest.validate_generated_screens([%{module: A, default_route: :x}], :p)
      end
    end

    test "raises when :module is nil" do
      assert_raise ArgumentError, fn ->
        RuntimeManifest.validate_generated_screens([%{module: nil, default_route: "/a"}], :p)
      end
    end

    test "raises on a non-map entry" do
      assert_raise ArgumentError, fn ->
        RuntimeManifest.validate_generated_screens(["nope"], :p)
      end
    end
  end

  describe "render/1 round-trips" do
    test "the rendered .exs evaluates back to the manifest map" do
      manifest = %{
        screens: [%{plugin: :p, module: P.Home, default_route: "/p"}],
        lifecycle: [%{plugin: :p, on_start: {P, :start, []}}],
        settings: [%{plugin: :p, schema: [%{key: :x, type: :integer, default: 3}]}],
        notification_handlers: [%{plugin: :p, match: %{type: "t"}, handler: {P, :h, 1}}]
      }

      {evaluated, _} = Code.eval_string(RuntimeManifest.render(manifest))
      assert evaluated == manifest
    end

    # MOB-383: a map prints its keys in atom-creation order (OTP 26+), so a VM
    # that created the atoms in another order rendered other bytes and
    # `mix mob.regen_plugin_manifest --check` reported drift right after a regen.
    # A fresh VM writes the manifest after creating every atom in reverse; this
    # VM, which created them in forward order, runs the check's comparison.
    test "a manifest written by a VM with another atom order passes the --check comparison" do
      id = System.unique_integer([:positive])
      {a_name, z_name} = {"mob383_alpha_#{id}", "mob383_zeta_#{id}"}
      a = String.to_atom(a_name)
      z = String.to_atom(z_name)
      manifest = every_section_manifest(a, z)

      root = Path.join(System.tmp_dir!(), "mob_rtm_order_#{id}")
      on_exit(fn -> File.rm_rf!(root) end)

      ebin = RuntimeManifest |> :code.which() |> to_string() |> Path.dirname()

      {out, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["-pa", ebin, "-e", @reverse_order_writer, root, a_name, z_name],
          stderr_to_stdout: true
        )

      assert status == 0, out
      path = String.trim(out)

      {written, _} = Code.eval_file(path)
      assert written == manifest
      assert File.read!(path) == RuntimeManifest.render(manifest)
    end
  end

  describe "write/1" do
    test "writes priv/generated/mob_plugins.exs under the host root" do
      root = Path.join(System.tmp_dir!(), "mob_rtm_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      path =
        RuntimeManifest.write(root, %{
          screens: [],
          lifecycle: [],
          settings: [],
          notification_handlers: []
        })

      assert path == Path.join([root, "priv", "generated", "mob_plugins.exs"])
      assert File.exists?(path)
      {evaluated, _} = Code.eval_file(path)
      assert evaluated.screens == []
    end
  end

  describe "with_host_config_audit/3" do
    test "records reads and restores a nil scope afterward" do
      {result, reads} =
        MobDev.Plugin.with_host_config_audit(:p, [:a, :b], fn ->
          MobDev.Plugin.host_config(:app, :a, 1) + MobDev.Plugin.host_config(:app, :b, 2)
        end)

      assert result == 3
      assert reads == [{:app, :a}, {:app, :b}]
      # scope cleared: a bare read no longer enforces
      assert MobDev.Plugin.host_config(:app, :anything, :default) == :default
    end
  end

  describe "composites (the ui_components expand: form)" do
    test "expand entries reach the runtime manifest tagged with their plugin" do
      plugins = [
        {"/kit",
         %{
           name: :mishka_kit,
           ui_components: [
             %{tag: "MishkaCard", atom: :mishka_card, expand: {Mishka.Card, :expand}},
             %{tag: "Native", atom: :native, ios: %{view_module: "N_View"}}
           ]
         }}
      ]

      manifest = RuntimeManifest.build(plugins)

      assert manifest.composites == [
               %{plugin: :mishka_kit, atom: :mishka_card, expand: {Mishka.Card, :expand}}
             ]
    end

    test "no expand entries → empty composites" do
      assert RuntimeManifest.build([]).composites == []
    end
  end
end
