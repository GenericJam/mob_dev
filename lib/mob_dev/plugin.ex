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

  This is currently a thin wrapper over `Application.get_env/3`; the audit
  enforcement (`:host_config_keys` manifest declarations checked against
  actual reads) lands in Phase 2 of the plugin extraction plan.
  """

  @doc """
  Reads `key` from the host application's environment, returning `default`
  when the key is unset.

  `otp_app` is the host app's OTP application name — the atom under which it
  registers `config :my_app, ...`. Code-generated plugins call this during
  the compile step:

      domains = MobDev.Plugin.host_config(:my_app, :ash_domains, [])
  """
  @spec host_config(atom(), atom(), term()) :: term()
  def host_config(otp_app, key, default \\ nil)
      when is_atom(otp_app) and is_atom(key) do
    Application.get_env(otp_app, key, default)
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
