defmodule MobDev.Plugin.SignatureGate do
  @moduledoc """
  Host-side build-time gate: runs `Verify.verify_plugin/2` + the
  `TrustStore` check across every activated plugin and refuses the
  build on any failure.

  This is the Phase 2 cryptographic counterpart to the capability
  drift check in `Validator`. Both run at the same hook point inside
  `Validator.raise_on_capability_drift!/1` so the iOS-sim, iOS-device,
  and Android paths all enforce them as a one-liner.

  Three distinct failure modes are surfaced (per `MOB_PLUGIN_SECURITY.md`,
  Phase 2):

  - **Missing signature** — author hasn't run `mix mob.plugin.sign`.
    Suppressible per-plugin via `config :mob, :acknowledge_unsafe_plugins`
    with a persistent banner.
  - **Invalid signature** — sig is present but doesn't verify; the
    manifest or sources have been tampered with after signing. Not
    suppressible.
  - **Untrusted fingerprint** — signature verifies but the public key
    isn't in `config :mob, :trusted_plugins` (or is a different key
    from the trusted one, the key-rotation case). Not suppressible;
    user must run `mix mob.plugin.trust <name>`.
  """

  alias MobDev.Plugin.{Crypto, Manifest, TrustStore, Verify}

  @typedoc "Errors `check_plugin/2` can return."
  @type gate_error ::
          {:missing_signature, atom()}
          | {:missing_pubkey, atom()}
          | {:invalid_signature, atom()}
          | {:envelope_v1_unsupported, atom()}
          | {:untrusted, atom(), Crypto.fingerprint(), Crypto.fingerprint() | nil}

  @doc """
  Runs the signature + trust check across `plugins` (the
  `MobDev.Plugin.activated/0` shape — `[{plugin_dir, manifest}]`).

  Returns `:ok` when every plugin verifies AND is trusted (or, for
  missing signatures, is listed in `config :mob, :acknowledge_unsafe_plugins`).
  Returns `{:error, errors}` otherwise — a list of `t:gate_error/0` tagged
  by plugin name.

  Reads the trust map from `mob.exs` (via `TrustStore.load_trusted_plugins/0`)
  and the acknowledgement list from `:mob`'s Application env or `mob.exs`.
  Pass the trust_map + acknowledged list explicitly via
  `check_activated/3` from tests that need isolation.
  """
  @spec check_activated([{Path.t(), map() | nil}]) :: :ok | {:error, [gate_error()]}
  def check_activated(plugins) do
    check_activated(plugins, TrustStore.load_trusted_plugins(), acknowledged_unsafe())
  end

  @doc "Pure variant of `check_activated/1` for tests."
  @spec check_activated([{Path.t(), map() | nil}], TrustStore.trust_map(), [atom()]) ::
          :ok | {:error, [gate_error()]}
  def check_activated(plugins, trust_map, acknowledged) do
    # A `nil` manifest can mean two things after MOB-74:
    #
    # * tier-0 plugin (no `priv/mob_plugin.exs` at all — nothing to sign,
    #   nothing to verify); skip.
    # * tier-1+ plugin whose signature verification failed, so
    #   `Verify.load_verified/1` refused to eval the manifest; the gate
    #   must still surface the failure with a friendly name-and-reason
    #   error, otherwise a tampered plugin silently gets treated like a
    #   tier-0 one.
    #
    # `Manifest.manifest_present?/1` distinguishes the two without eval'ing
    # anything.
    errors =
      for {dir, manifest} <- plugins,
          Manifest.manifest_present?(dir),
          err = check_plugin(dir, manifest, trust_map, acknowledged),
          err != :ok do
        err
      end

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @doc """
  Runs `check_activated/1` and raises a `Mix.raise/1` with a clear,
  actionable message when any plugin fails. No-op on success.
  """
  @spec raise_on_signature_drift!([{Path.t(), map() | nil}]) :: :ok
  def raise_on_signature_drift!(plugins) do
    case check_activated(plugins) do
      :ok ->
        :ok

      {:error, errors} ->
        Mix.raise(format_errors(errors))
    end
  end

  @doc """
  Prints a stderr banner when any activated plugin is allowed only via
  `:acknowledge_unsafe_plugins`. Idempotent within a single Mix invocation
  in spirit — the banner fires every time it's called, so callers should
  invoke it once per build.
  """
  @spec maybe_print_unsafe_banner([{Path.t(), map() | nil}]) :: :ok
  def maybe_print_unsafe_banner(plugins) do
    acknowledged = acknowledged_unsafe()

    unsafe =
      for {dir, manifest} <- plugins,
          is_map(manifest),
          name = manifest[:name],
          name in acknowledged,
          {:error, :missing} <- [Verify.load_signature(dir)] do
        name
      end

    case unsafe do
      [] ->
        :ok

      names ->
        names_str = Enum.map_join(names, ", ", &Atom.to_string/1)

        IO.puts(
          :stderr,
          [
            "\n",
            IO.ANSI.yellow(),
            "⚠  unsigned mob plugins enabled: ",
            names_str,
            "\n    these are not cryptographically verified — disable for production\n",
            IO.ANSI.reset()
          ]
        )

        :ok
    end
  end

  @doc false
  # Public for tests: checks a single plugin against the trust map and
  # acknowledgement list. Returns `:ok` on pass, a gate_error otherwise.
  # `manifest` may be `nil` when `Verify.load_verified/1` refused to eval a
  # plugin whose signature check failed; the error surface still needs a
  # name, so we fall back to the dep-directory basename (which matches the
  # published plugin name by convention).
  @spec check_plugin(Path.t(), map() | nil, TrustStore.trust_map(), [atom()]) ::
          :ok | gate_error()
  def check_plugin(dir, manifest, trust_map, acknowledged) do
    name = manifest_name(dir, manifest)

    case Verify.verify_plugin(dir) do
      :ok ->
        check_trust(dir, name, trust_map)

      {:error, :missing_signature} ->
        if name in acknowledged, do: :ok, else: {:missing_signature, name}

      {:error, :missing_pubkey} ->
        {:missing_pubkey, name}

      {:error, :invalid_signature} ->
        {:invalid_signature, name}

      {:error, :envelope_v1_unsupported} ->
        {:envelope_v1_unsupported, name}
    end
  end

  defp manifest_name(_dir, manifest) when is_map(manifest), do: manifest[:name]

  # `String.to_atom` on unbounded input can exhaust the atom table, but the
  # domain here is the deps-directory basename — one entry per Hex dep in
  # `Mix.Project.deps_paths()`, a small set the consumer controls at
  # dependency-declaration time. No attacker-controlled path reaches this
  # helper.
  defp manifest_name(dir, nil) do
    dir |> Path.basename() |> String.to_atom()
  end

  defp check_trust(dir, name, trust_map) do
    case Verify.load_pubkey(dir) do
      {:ok, pub} ->
        actual_fp = Crypto.fingerprint(pub)
        trusted_fp = Map.get(trust_map, name)

        if trusted_fp == actual_fp do
          :ok
        else
          {:untrusted, name, actual_fp, trusted_fp}
        end

      {:error, _} ->
        {:missing_pubkey, name}
    end
  end

  @doc """
  The list of plugin names the consumer has opted into loading unsigned via
  `:acknowledge_unsafe_plugins` (in `Application` env or `mob.exs`).

  Exposed so `MobDev.Plugin.activated/0` can pass
  `acknowledged_unsafe: true` into `Verify.load_verified/2` for these
  plugins — otherwise a missing signature would silently strip the plugin
  from the build (its manifest fields would never merge into the app),
  producing "acknowledged" plugins that actually contribute nothing.
  See MOB-74's pre-merge review.
  """
  @spec acknowledged_unsafe() :: [atom()]
  def acknowledged_unsafe do
    Application.get_env(:mob, :acknowledge_unsafe_plugins, []) ++
      read_acknowledged_from_mob_exs()
  end

  defp read_acknowledged_from_mob_exs do
    config_file = Path.join(File.cwd!(), "mob.exs")

    if File.exists?(config_file) do
      config_file
      |> Config.Reader.read!()
      |> Keyword.get(:mob, [])
      |> Keyword.get(:acknowledge_unsafe_plugins, [])
    else
      []
    end
  rescue
    _ -> []
  end

  # ── error formatting ──────────────────────────────────────────────────────

  defp format_errors(errors) do
    bullets =
      errors
      |> Enum.uniq()
      |> Enum.map_join("\n\n", &format_error/1)

    "plugin signature check failed — refusing to build (see MOB_PLUGIN_SECURITY.md, Phase 2):\n\n" <>
      bullets
  end

  defp format_error({:missing_signature, name}) do
    "  - plugin #{inspect(name)} is not signed — author must run `mix mob.plugin.sign`.\n" <>
      "    To allow unsigned plugins during development, add\n" <>
      "      config :mob, :acknowledge_unsafe_plugins, [#{inspect(name)}]\n" <>
      "    to mob.exs (a persistent banner will print on every build)."
  end

  defp format_error({:missing_pubkey, name}) do
    "  - plugin #{inspect(name)} is signed but ships no priv/mob_plugin.pub —\n" <>
      "    cannot verify. Re-run `mix mob.plugin.sign` after `mix mob.plugin.keygen`."
  end

  defp format_error({:invalid_signature, name}) do
    "  - signature for plugin #{inspect(name)} is invalid — this can indicate\n" <>
      "    tampering with the plugin's manifest or source files."
  end

  defp format_error({:envelope_v1_unsupported, name}) do
    "  - plugin #{inspect(name)} ships a v1 signature envelope (MOB-74).\n" <>
      "    v1 required evaluating the manifest before verifying it, which\n" <>
      "    let a malicious priv/mob_plugin.exs run arbitrary code at build\n" <>
      "    time. Refused by this mob_dev. Ask the plugin author to re-sign\n" <>
      "    with a mob_dev that produces envelope v2 (`mix mob.plugin.sign`)."
  end

  defp format_error({:untrusted, name, actual_fp, nil}) do
    "  - plugin #{inspect(name)} is signed with key\n" <>
      "      #{actual_fp}\n" <>
      "    but is not trusted. Run `mix mob.plugin.trust #{name}` after reviewing the plugin."
  end

  defp format_error({:untrusted, name, actual_fp, trusted_fp}) do
    "  - plugin #{inspect(name)} key rotation detected:\n" <>
      "      trusted: #{trusted_fp}\n" <>
      "      signed with: #{actual_fp}\n" <>
      "    Run `mix mob.plugin.trust #{name}` again to accept the new key."
  end
end
