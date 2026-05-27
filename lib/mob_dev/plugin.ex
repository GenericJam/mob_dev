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
end
