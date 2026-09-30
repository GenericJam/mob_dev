defmodule MobDev.AppConfigTest do
  # Loads the generated :mob_app_config into this VM, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias MobDev.AppConfig

  @moduletag :tmp_dir

  defp write_config(dir, name, body) do
    File.mkdir_p!(Path.join(dir, "config"))
    File.write!(Path.join([dir, "config", name]), "import Config\n" <> body)
  end

  defp read(dir, opts) do
    AppConfig.read(Keyword.merge([config_path: Path.join(dir, "config/config.exs")], opts))
  end

  # What a device gets: the generated module, loaded and called.
  defp on_device(beam) do
    {:module, :mob_app_config} = :code.load_binary(:mob_app_config, ~c"mob_app_config.beam", beam)
    # apply/3: the module doesn't exist when this file compiles.
    apply(:mob_app_config, :config, [])
  after
    :code.purge(:mob_app_config)
    :code.delete(:mob_app_config)
    :code.purge(:mob_app_config)
  end

  describe "read/1" do
    test "evaluates config.exs and its imports for the requested env and target", %{tmp_dir: dir} do
      write_config(dir, "config.exs", """
      config :my_app, greeting: "hi", level: :base
      import_config "\#{config_env()}.exs"
      if config_target() == :ios, do: config(:my_app, target_only: true)
      """)

      write_config(dir, "dev.exs", "config :my_app, level: :dev\n")
      write_config(dir, "prod.exs", "config :my_app, level: :prod\n")

      assert {[my_app: kvs], []} = read(dir, env: :prod, target: :host)
      assert kvs[:greeting] == "hi"
      assert kvs[:level] == :prod
      refute Keyword.has_key?(kvs, :target_only)

      assert {[my_app: dev], []} = read(dir, env: :dev, target: :ios)
      assert dev[:level] == :dev
      assert dev[:target_only] == true
    end

    test "runtime.exs is merged over config.exs, deep-merging keyword values", %{tmp_dir: dir} do
      write_config(dir, "config.exs", """
      config :my_app, endpoint: "http://base", nested: [a: 1, b: 2]
      config :other, x: 1
      """)

      write_config(dir, "runtime.exs", """
      if config_env() == :dev do
        config :my_app, endpoint: "http://runtime", nested: [b: 3]
      end
      """)

      {config, []} = read(dir, env: :dev, target: :host)
      assert config[:my_app][:endpoint] == "http://runtime"
      assert config[:my_app][:nested] == [a: 1, b: 3]
      assert config[:other] == [x: 1]

      {prod, []} = read(dir, env: :prod, target: :host)
      assert prod[:my_app][:endpoint] == "http://base"
    end

    test "drops :mob_dev, which is host tooling config", %{tmp_dir: dir} do
      write_config(dir, "config.exs", """
      config :mob_dev, mob_dir: "/Users/me/code/mob"
      config :my_app, greeting: "hi"
      """)

      assert {[my_app: [greeting: "hi"]], []} = read(dir, env: :dev, target: :host)
    end

    test "skips keys holding values that mean nothing on another VM, keeping the rest",
         %{tmp_dir: dir} do
      write_config(dir, "config.exs", """
      config :my_app,
        greeting: "hi",
        callback: fn x -> x end,
        external: &String.upcase/1,
        pattern: ~r/abc/,
        nested: [deep: {:ok, %{f: fn -> 1 end}}]
      config :only_bad, handler: fn -> :ok end
      """)

      {config, skipped} = read(dir, env: :dev, target: :host)

      assert config == [my_app: [greeting: "hi", external: &String.upcase/1]]

      assert [
               {:my_app, :callback, fun_reason},
               {:my_app, :pattern, _},
               {:my_app, :nested, _},
               {:only_bad, :handler, _}
             ] =
               skipped

      assert fun_reason =~ "anonymous function"
    end

    test "no config file is an empty config", %{tmp_dir: dir} do
      assert read(dir, env: :dev, target: :host) == {[], []}
    end

    test "a config file that fails to evaluate raises rather than shipping a partial config",
         %{tmp_dir: dir} do
      write_config(dir, "config.exs", "config :my_app, greeting: undefined_var\n")

      assert_raise CompileError, fn -> read(dir, env: :dev, target: :host) end
    end
  end

  describe "compile/2" do
    test "the module returns the config: nested maps, tuples, external funs" do
      config = [
        my_app: [
          greeting: "hi",
          big: Map.new(1..500, &{&1, "v#{&1}"}),
          mfa: {MyApp.Repo, :start_link, [[pool_size: 2]]},
          external: &String.upcase/1
        ]
      ]

      assert on_device(AppConfig.compile(config)) == config
    end

    test "is deterministic, so an unchanged config produces unchanged bytes" do
      config = [my_app: [a: 1, b: %{c: [1, 2]}]]
      assert AppConfig.compile(config) == AppConfig.compile(config)
      refute AppConfig.compile(config) == AppConfig.compile(my_app: [a: 2, b: %{c: [1, 2]}])
    end
  end

  describe "write!/2" do
    test "writes the module into the ebin and leaves it untouched when nothing changed",
         %{tmp_dir: dir} do
      write_config(dir, "config.exs", "config :my_app, greeting: \"hi\"\n")
      ebin = Path.join(dir, "ebin")
      opts = [config_path: Path.join(dir, "config/config.exs"), env: :dev, target: :host]

      path = AppConfig.write!(ebin, opts)
      assert path == Path.join(ebin, "mob_app_config.beam")
      assert on_device(File.read!(path)) == [my_app: [greeting: "hi"]]

      File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
      AppConfig.write!(ebin, opts)
      assert File.stat!(path).mtime == {{2000, 1, 1}, {0, 0, 0}}

      write_config(dir, "config.exs", "config :my_app, greeting: \"hello\"\n")
      AppConfig.write!(ebin, opts)
      assert on_device(File.read!(path)) == [my_app: [greeting: "hello"]]
    end

    test "warns about each skipped key once, not on every regeneration", %{tmp_dir: dir} do
      write_config(
        dir,
        "config.exs",
        "config :my_app, callback: fn -> :ok end, greeting: \"hi\"\n"
      )

      opts = [config_path: Path.join(dir, "config/config.exs"), env: :dev, target: :host]
      write = fn -> capture_io(fn -> AppConfig.write!(Path.join(dir, "ebin"), opts) end) end

      output = write.()
      assert output =~ "config :my_app, :callback not shipped to the device"
      refute output =~ ":greeting"

      assert write.() == ""
    end
  end
end
