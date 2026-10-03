defmodule Mix.Tasks.Mob.Plugins do
  use Mix.Task

  @shortdoc "List installed Mob plugins and their activation status"

  @moduledoc """
  Lists the Mob plugins this project depends on, with tier, hot-push status,
  and whether each is activated.

      mix mob.plugins

  A dependency is shown as a plugin if it ships a `priv/mob_plugin.exs`
  manifest, or if it is named in `config :mob, :plugins` in `mob.exs`.
  Tier-0 plugins (pure Elixir, no manifest) are indistinguishable from
  ordinary libraries until activated, so they appear only once listed in
  `config :mob, :plugins`.

  A manifest whose signature doesn't verify is not loaded (its tier shows as
  `?`); its row says what is wrong with the signature and how to fix it.

  Activation is two-step by design (see [`MOB_PLUGINS.md`](https://github.com/GenericJam/mob/blob/master/MOB_PLUGINS.md)): adding a plugin to
  `deps` makes it *installed*; adding it to `config :mob, :plugins` makes it
  *activated* — only then are its contributions merged into the build.

  Exits non-zero when activated plugins collide (same component atom, native
  view key, NIF module, ...), naming each plugin's `priv/mob_plugin.exs`.
  """

  alias MobDev.Plugin.{Report, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")

    deps =
      load_manifests(Mix.Project.deps_paths(), MobDev.Plugin.SignatureGate.acknowledged_unsafe())

    activated = activated_plugins()
    dep_dirs = Mix.Project.deps_paths()

    deps
    |> Report.rows(activated)
    |> Report.with_vetting(dep_dirs)
    |> Report.render()
    |> then(&IO.puts("\n" <> &1 <> "\n"))

    # Refused manifests ({:unverified, _}) were never loaded; nothing to check.
    activated_manifests =
      for {name, manifest} <- deps,
          name in activated,
          not match?({:unverified, _}, manifest),
          do: {dep_dirs[name], manifest}

    # Exits non-zero on a collision so CI and scripts can't miss it (MOB-170);
    # the native build runs the same check before codegen.
    Validator.raise_on_cross_plugin_conflicts!(activated_manifests)
  end

  @doc false
  # Loads each dependency's manifest the way the build does
  # (`MobDev.Plugin.activated_with_verify/0`): a plugin listed in
  # `acknowledge_unsafe_plugins` is loaded unsigned. Without that, an
  # acknowledged plugin dropped out as nil and the collision check above
  # passed a configuration the native build rejects (release review).
  #
  # A manifest that fails verification is never evaluated; it comes back as
  # `{:unverified, reason}` so its row says why and how to fix it (MOB-332)
  # instead of passing for a tier-0 dep with no manifest.
  @spec load_manifests(%{atom() => Path.t()}, [atom()]) ::
          [{atom(), map() | nil | {:unverified, term()}}]
  def load_manifests(deps_paths, acknowledged) do
    Enum.map(deps_paths, fn {app, path} ->
      opts = if app in acknowledged, do: [acknowledged_unsafe: true], else: []

      case MobDev.Plugin.Verify.load_verified(path, opts) do
        {:ok, manifest} -> {app, manifest}
        {:error, reason} -> {app, {:unverified, reason}}
      end
    end)
  end

  # `config :mob, :plugins`, read exactly as the build reads it — a broken
  # mob.exs raises instead of listing every plugin as inactive (MOB-280).
  defp activated_plugins, do: normalize_activated(MobDev.Plugin.activated_names())

  @doc false
  # Pure kernel: coerces a `config :mob, :plugins` value into a clean list of
  # atom plugin names. A misconfigured value (a non-list, or a list carrying
  # non-atom entries like a stray string typo `"mob_haptic"`) must not crash
  # `mix mob.plugins` — `name in activated` raises Protocol.UndefinedError on a
  # non-list, and downstream `name in activated` silently mismatches string
  # entries. Non-list → `[]`; lists are filtered down to their atom entries.
  @spec normalize_activated(term()) :: [atom()]
  def normalize_activated(plugins) when is_list(plugins),
    do: Enum.filter(plugins, &is_atom/1)

  def normalize_activated(_other), do: []
end
