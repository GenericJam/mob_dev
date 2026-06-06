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
  end

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

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
end
