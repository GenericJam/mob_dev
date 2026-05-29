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

  alias MobDev.Plugin.{Crypto, TrustStore, Verify}

  @typedoc "Errors `check_plugin/2` can return."
  @type gate_error ::
          {:missing_signature, atom()}
          | {:missing_pubkey, atom()}
          | {:invalid_signature, atom()}
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
    errors =
      for {dir, manifest} <- plugins,
          is_map(manifest),
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
  @spec check_plugin(Path.t(), map(), TrustStore.trust_map(), [atom()]) :: :ok | gate_error()
  def check_plugin(dir, manifest, trust_map, acknowledged) do
    name = manifest[:name]

    case Verify.verify_plugin(dir, manifest) do
      :ok ->
        check_trust(dir, name, trust_map)

      {:error, :missing_signature} ->
        if name in acknowledged, do: :ok, else: {:missing_signature, name}

      {:error, :missing_pubkey} ->
        {:missing_pubkey, name}

      {:error, :invalid_signature} ->
        {:invalid_signature, name}
    end
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

  defp acknowledged_unsafe do
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
