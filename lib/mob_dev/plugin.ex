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
  manifest via `MobDev.Plugin.Verify.load_verified/1` — signature and
  file-integrity checks run **before** `Code.eval_file` (MOB-74), so a
  plugin that fails verification never has its `priv/mob_plugin.exs`
  executed. Failed plugins come back as `{dir, nil}` here; callers that
  need to distinguish "tier-0 plugin (no manifest)" from "verify failed"
  should use `activated_with_verify/0` — that's the shape
  `SignatureGate.check_activated/1` consumes to produce friendly
  build-blocking errors. Activated names that don't resolve to a dep
  are skipped — `mix mob.plugins` is where that mismatch surfaces
  to users.
  """
  @spec activated() :: [{Path.t(), map() | nil}]
  def activated do
    for {dir, manifest, _status} <- activated_with_verify(), do: {dir, manifest}
  end

  @typedoc """
  Verification status returned from `activated_with_verify/0`. `:ok` means the
  manifest was loaded after a passing signature + tamper check; `:unsigned`
  means there was no manifest at all (tier-0 plugin — no signature required);
  `{:error, reason}` means the plugin failed verification and its manifest
  bytes were never eval'd. Reasons come from `MobDev.Plugin.Verify.verify_error/0`.
  """
  @type verify_status ::
          :ok
          | :unsigned
          | {:error, MobDev.Plugin.Verify.verify_error()}

  @typedoc "One entry in `activated_with_verify/0`'s return list."
  @type activated_entry :: {Path.t(), map() | nil, verify_status()}

  @doc """
  Same as `activated/0` but also returns the verification status per plugin.

  `SignatureGate.check_activated/1` consumes this shape so it can produce a
  clear build-blocking error naming the failed plugin — without needing to
  re-load or re-verify anything. A plugin that failed verification appears as
  `{dir, nil, {:error, reason}}`; a tier-0 plugin (no `priv/mob_plugin.exs`
  and no signature required) appears as `{dir, nil, :unsigned}`.
  """
  @spec activated_with_verify() :: [activated_entry()]
  def activated_with_verify do
    deps = Mix.Project.deps_paths()

    for name <- activated_names(), dir = deps[name], not is_nil(dir) do
      case MobDev.Plugin.Verify.load_verified(dir) do
        {:ok, nil} -> {dir, nil, :unsigned}
        {:ok, manifest} -> {dir, manifest, :ok}
        {:error, reason} -> {dir, nil, {:error, reason}}
      end
    end
  end
end
