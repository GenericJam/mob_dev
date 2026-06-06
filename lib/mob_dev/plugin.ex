defmodule MobDev.Plugin do
  @moduledoc """
  Compile-time host-config surface for code-generated plugins.

  Spec-v2 plugins that generate their contributions from the host app's
  configuration — e.g. a `mob_ash` plugin reading the host's registered
  Ash domains, or a `mob_ecto` plugin reading its schemas — read that
  config through this function rather than calling `Application.get_env/3`
  directly. Routing every host-config read through one named surface is
  what later lets the plugin audit (see `MOB_PLUGINS.md` and
  `MOB_PLUGIN_SECURITY.md`) verify exactly which keys a generator touches.

  When a generator runs under `with_host_config_audit/3` (which the
  build-time generator runner uses), every read is checked against the
  plugin's declared `:host_config_keys` and recorded; an undeclared read
  fails the build loudly. Outside an audit scope (e.g. in tests) it is a
  plain `Application.get_env/3`.
  """

  # Process-dictionary key holding the active host-config audit scope, if any.
  @audit_key :"$mob_plugin_host_config_audit"

  @doc """
  Reads `key` from the host application's environment, returning `default`
  when the key is unset.

  `otp_app` is the host app's OTP application name — the atom under which it
  registers `config :my_app, ...`. Code-generated plugins call this during
  the compile step:

      domains = MobDev.Plugin.host_config(:my_app, :ash_domains, [])

  Under an audit scope, reading a key the plugin didn't declare in its
  manifest `:host_config_keys` raises — the generator must declare what it
  touches so `mix mob.audit_plugins` can verify it.
  """
  @spec host_config(atom(), atom(), term()) :: term()
  def host_config(otp_app, key, default \\ nil)
      when is_atom(otp_app) and is_atom(key) do
    case Process.get(@audit_key) do
      nil ->
        :ok

      %{plugin: plugin, allowed: allowed} = ctx ->
        unless key in allowed do
          raise ArgumentError,
                "plugin #{inspect(plugin)} read host config key #{inspect(key)} not declared in its " <>
                  "manifest :host_config_keys (declared: #{inspect(allowed)}). Add it to the manifest."
        end

        Process.put(@audit_key, %{ctx | reads: [{otp_app, key} | ctx.reads]})
    end

    Application.get_env(otp_app, key, default)
  end

  @doc """
  Runs `fun` with host-config auditing scoped to `plugin` (allowing only the
  keys in `allowed`, the plugin's manifest `:host_config_keys`). Returns
  `{result, reads}` where `reads` is the ordered list of `{otp_app, key}` the
  generator actually touched. Nested scopes restore the prior one on exit.
  """
  @spec with_host_config_audit(atom(), [atom()], (-> result)) :: {result, [{atom(), atom()}]}
        when result: term()
  def with_host_config_audit(plugin, allowed, fun)
      when is_atom(plugin) and is_list(allowed) and is_function(fun, 0) do
    prev = Process.get(@audit_key)
    Process.put(@audit_key, %{plugin: plugin, allowed: allowed, reads: []})

    try do
      result = fun.()
      %{reads: reads} = Process.get(@audit_key)
      {result, Enum.reverse(reads)}
    after
      if prev, do: Process.put(@audit_key, prev), else: Process.delete(@audit_key)
    end
  end

  @doc """
  The activated plugin names — `config :mob, :plugins` from `mob.exs`.

  Activation is the second opt-in step (see `MOB_PLUGINS.md`): a plugin in
  `deps` contributes nothing until it appears here. Falls back to the loaded
  Application env, then `[]`.
  """
  @spec activated_names() :: [atom()]
  def activated_names do
    config_file = Path.join(File.cwd!(), "mob.exs")

    if File.exists?(config_file) do
      config_file
      |> Config.Reader.read!()
      |> Keyword.get(:mob, [])
      |> Keyword.get(:plugins, [])
    else
      Application.get_env(:mob, :plugins, [])
    end
  rescue
    _ -> Application.get_env(:mob, :plugins, [])
  end

  @doc """
  The activated plugins as `{plugin_dir, manifest}` pairs, ready for
  `MobDev.Plugin.Merge`.

  Resolves each activated name to its dependency directory and loads its
  manifest (nil for a tier-0 plugin). Activated names that don't resolve to a
  dep are skipped — `mix mob.plugins` is where that mismatch surfaces to users.
  """
  @spec activated() :: [{Path.t(), map() | nil}]
  def activated do
    deps = Mix.Project.deps_paths()

    for name <- activated_names(), dir = deps[name], not is_nil(dir) do
      case MobDev.Plugin.Manifest.load(dir) do
        {:ok, manifest} -> {dir, manifest}
        {:error, _reason} -> {dir, nil}
      end
    end
  end
end
