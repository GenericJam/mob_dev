defmodule MobDev.AppConfig do
  @moduledoc """
  Ships the project's application config to the device as the generated
  Erlang module `mob_app_config`.

  A Mob app boots from `<app>:start()` rather than an OTP release, so nothing
  loads `config/*.exs` on the device and `Application.get_env/3` returns nil
  for everything except `compile_env` values. mob_dev therefore evaluates the
  config on the host and compiles it into a module:

      mob_app_config:config() :: [{App :: atom(), [{Key :: atom(), Value :: term()}]}]

  `Mob.App.start/0` (mob 0.9.6 and later) loads it first thing and applies it
  with `Application.put_all_env/2`.

  ## What goes in

    * `config/config.exs` (the project's `:config_path`), read with
      `Config.Reader` for the build's `Mix.env()` and `Mix.target()`, so its
      `import_config` and `config_env()`/`config_target()` branches resolve as
      they do on the host.
    * `config/runtime.exs` next to it, when present, merged on top.
      **It is evaluated on the host, at build time**, not on the device at
      boot: `System.get_env/1` there reads the developer's environment.
    * minus `:mob_dev`, which is host tooling configuration.

  The config is embedded with `:erlang.term_to_binary/2` and decoded by
  `config/0`, so values `Macro.escape/1` can't turn into literals (tuples of
  references to modules, large nested maps, ...) survive. Values that can't
  mean anything on another VM (local funs such as `fn` literals in a config
  file, pids, ports, references, which includes compiled regexes) are dropped
  per key with a warning; external funs (`&Mod.fun/1`) are kept.

  ## Where it goes

  `write!/0` puts `mob_app_config.beam` into the app's own compile path, next
  to `<app>.beam`. Every path that ships the app's BEAMs copies that
  directory, so the module rides along with no per-platform step: the
  filesystem and dist pushes of `mix mob.deploy` (through
  `MobDev.HotPush.runtime_beam_dirs/0`), the iOS simulator and device builds,
  and the Android and iOS release builds. The file is only rewritten when its
  bytes change, so `mix mob.watch` doesn't push it on every save.

  A config change reaches a running app on its next start: a hot push loads the
  new module but does not re-apply it.
  """

  @module :mob_app_config

  # Host-only applications whose config must never reach the device.
  @host_only_apps [:mob_dev]

  @typedoc "`{app, key}` of a value dropped as non-portable, with the reason."
  @type skipped :: {atom(), atom(), String.t()}

  @doc "The generated module's name."
  @spec module() :: atom()
  def module, do: @module

  @doc """
  Evaluates the project config for the device.

  Options: `:config_path` (default: the project's `:config_path`), `:env`
  (default `Mix.env()`), `:target` (default `Mix.target()`).

  Returns `{config, skipped}`; `skipped` lists the keys dropped because their
  value is non-portable.
  """
  @spec read(keyword()) :: {[{atom(), keyword()}], [skipped()]}
  def read(opts \\ []) do
    config_path = Keyword.get_lazy(opts, :config_path, &project_config_path/0)
    env = Keyword.get_lazy(opts, :env, &Mix.env/0)
    target = Keyword.get_lazy(opts, :target, &Mix.target/0)
    runtime_path = Path.join(Path.dirname(config_path), "runtime.exs")

    config_path
    |> read_file(env, target)
    |> Config.Reader.merge(read_file(runtime_path, env, target))
    |> Keyword.drop(@host_only_apps)
    |> portable()
  end

  @doc """
  Compiles `config` into the `mob_app_config` module's BEAM bytes.

  Deterministic: the same config always produces the same bytes. `env` and
  `target` are recorded as the `mob_app_config` module attribute so a device
  can tell which build produced its config.
  """
  @spec compile([{atom(), keyword()}], keyword()) :: binary()
  def compile(config, meta \\ []) do
    encoded = :erlang.term_to_binary(config, [:deterministic])

    forms = [
      {:attribute, 1, :module, @module},
      {:attribute, 1, :export, [config: 0]},
      {:attribute, 1, @module, meta},
      {:function, 1, :config, 0,
       [
         {:clause, 1, [], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :binary_to_term}},
             [
               {:bin, 1,
                [
                  {:bin_element, 1, {:string, 1, :binary.bin_to_list(encoded)}, :default,
                   :default}
                ]}
             ]}
          ]}
       ]}
    ]

    {:ok, @module, beam} = :compile.forms(forms, [:deterministic, :return_errors])
    beam
  end

  @doc """
  Generates `mob_app_config.beam` into `ebin` (default: the project's compile
  path) and returns its path. Warns about each dropped key, once per run
  (`mix mob.watch` regenerates on every save).

  The file is left untouched when its content would not change.
  """
  @spec write!(Path.t(), keyword()) :: Path.t()
  def write!(ebin \\ Mix.Project.compile_path(), opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &Mix.env/0)
    target = Keyword.get_lazy(opts, :target, &Mix.target/0)
    {config, skipped} = read(Keyword.merge(opts, env: env, target: target))

    warned = :persistent_term.get({__MODULE__, :warned}, MapSet.new())
    new = for s <- skipped, not MapSet.member?(warned, {ebin, s}), do: s

    Enum.each(new, fn {app, key, reason} ->
      IO.puts(
        "  #{IO.ANSI.yellow()}⚠  config :#{app}, #{inspect(key)} not shipped to the device: " <>
          "#{reason}#{IO.ANSI.reset()}"
      )
    end)

    if new != [],
      do:
        :persistent_term.put(
          {__MODULE__, :warned},
          MapSet.union(warned, MapSet.new(new, &{ebin, &1}))
        )

    beam = compile(config, env: env, target: target)
    path = Path.join(ebin, "#{@module}.beam")

    if File.read(path) != {:ok, beam} do
      File.mkdir_p!(ebin)
      File.write!(path, beam)
    end

    path
  end

  defp project_config_path do
    Mix.Project.config()[:config_path] || "config/config.exs"
  end

  # A missing file is an empty config; a file that fails to evaluate raises,
  # because shipping a partial config would boot the app with settings silently
  # missing.
  defp read_file(path, env, target) do
    if File.regular?(path),
      do: Config.Reader.read!(path, env: env, target: target),
      else: []
  end

  defp portable(config) do
    {kept, skipped} =
      Enum.map_reduce(config, [], fn {app, kvs}, skipped ->
        {keep, drop} = Enum.split_with(kvs, fn {_key, value} -> non_portable(value) == nil end)
        dropped = for {key, value} <- drop, do: {app, key, non_portable(value)}
        {{app, keep}, skipped ++ dropped}
      end)

    {Enum.reject(kept, fn {_app, kvs} -> kvs == [] end), skipped}
  end

  # nil when the term means the same thing on another VM, else why it doesn't.
  defp non_portable(term) when is_function(term) do
    case Function.info(term, :type) do
      {:type, :external} -> nil
      {:type, :local} -> "it contains an anonymous function (use &Mod.fun/arity)"
    end
  end

  defp non_portable(term) when is_pid(term), do: "it contains a pid"
  defp non_portable(term) when is_port(term), do: "it contains a port"

  defp non_portable(term) when is_reference(term),
    do: "it contains a reference (a compiled regex is one; store the source string)"

  defp non_portable(term) when is_tuple(term), do: term |> Tuple.to_list() |> first_non_portable()

  defp non_portable(term) when is_map(term),
    do: term |> Map.to_list() |> first_non_portable()

  defp non_portable(term) when is_list(term), do: first_non_portable(term)
  defp non_portable(_term), do: nil

  # Walks proper and improper lists alike.
  defp first_non_portable([]), do: nil

  defp first_non_portable([head | tail]),
    do: non_portable(head) || first_non_portable(tail)

  defp first_non_portable(tail), do: non_portable(tail)
end
