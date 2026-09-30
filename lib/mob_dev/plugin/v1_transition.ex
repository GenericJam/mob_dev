defmodule MobDev.Plugin.V1Transition do
  @moduledoc """
  Transitional acceptance of legacy v1 plugin signature envelopes (MOB-287).

  Every first-party plugin published before mob_dev shipped envelope v2
  (MOB-74) is v1-signed. v1 signatures cover the *evaluated* manifest map,
  so verifying one means running `Code.eval_file` on `priv/mob_plugin.exs`
  first — arbitrary code execution for a malicious manifest. This module
  therefore evaluates a v1 manifest only after its provenance is established
  **without** evaluating anything:

  1. The plugin is a Hex dependency from the public `hexpm` repository:
     Mix resolves it through `Hex.SCM` right now (not a path or git
     dependency, including a path override pointing into `deps/`), the
     project's `mix.lock` pins it to `hexpm`, and its directory is the Hex
     checkout in the project's deps path. Hex package-name ownership fixes
     who published it; Hex verifies the tarball checksum on fetch; and the
     package's own `mix.exs` and compile step already execute during
     `mix compile`, so evaluating its manifest grants it nothing it did not
     already have.
  2. The public key in `priv/mob_plugin.pub` has the fingerprint trusted for
     that plugin name in `config :mob, :trusted_plugins`.

  Only then is the manifest evaluated and the v1 signature checked against
  it (3). Any failure reports `:envelope_v1_unsupported`, the same refusal
  every other v1 envelope gets.

  Delete this module — and its two call sites in `Verify.load_verified/2`
  and `SignatureGate` — once every first-party plugin is republished with a
  v2 signature. See decisions/2026-09-30-v1-envelope-transition.md.
  """

  alias MobDev.Plugin.{Crypto, Manifest, Sign, TrustStore, Verify}

  @signature_file "priv/mob_plugin.sig"
  @manifest_file "priv/mob_plugin.exs"

  @typedoc """
  Provenance inputs. Each defaults to the current Mix project's value:

  - `:scms` — each dependency's active SCM (`Mix.Project.deps_scms/0`).
  - `:lock` — the parsed `mix.lock` map (`Mix.Dep.Lock.read/0`).
  - `:deps_path` — the project's deps directory (`Mix.Project.deps_path/0`).
  - `:trust_map` — `config :mob, :trusted_plugins`
    (`TrustStore.load_trusted_plugins/0`).
  """
  @type opts :: [
          scms: %{optional(atom()) => module()},
          lock: map(),
          deps_path: Path.t(),
          trust_map: TrustStore.trust_map()
        ]

  @doc """
  Loads the manifest of a v1-signed plugin when the transition rule allows it.

  The manifest is evaluated only after the plugin passes the Hex-provenance
  and trusted-fingerprint checks; a plugin failing either is refused without
  evaluation. Returns `{:error, :envelope_v1_unsupported}` on any failure.
  """
  @spec load(Path.t(), opts()) :: {:ok, map()} | {:error, :envelope_v1_unsupported}
  def load(plugin_dir, opts \\ []) do
    with {:ok, pub} <- provenance(plugin_dir, opts),
         {:ok, manifest} when is_map(manifest) <- Manifest.load(plugin_dir),
         :ok <- verify_signature(plugin_dir, manifest, pub) do
      {:ok, manifest}
    else
      _ -> {:error, :envelope_v1_unsupported}
    end
  end

  @doc """
  Whether an already-loaded `manifest` for a v1-signed plugin satisfies the
  transition rule. Never evaluates anything — used by `SignatureGate`, which
  receives manifests `MobDev.Plugin.activated/0` already loaded.
  """
  @spec accepted?(Path.t(), map() | nil, opts()) :: boolean()
  def accepted?(plugin_dir, manifest, opts \\ [])

  def accepted?(plugin_dir, manifest, opts) when is_map(manifest) do
    case provenance(plugin_dir, opts) do
      {:ok, pub} -> verify_signature(plugin_dir, manifest, pub) == :ok
      :error -> false
    end
  end

  def accepted?(_plugin_dir, nil, _opts), do: false

  @doc """
  The one-line build notice for an accepted v1 plugin.
  """
  @spec notice(Path.t(), opts()) :: String.t()
  def notice(plugin_dir, opts \\ []) do
    name = Path.basename(plugin_dir)

    vsn =
      case hexpm_lock_entry(name, Keyword.get_lazy(opts, :lock, &Mix.Dep.Lock.read/0)) do
        {:ok, vsn} -> vsn
        :error -> "(unknown version)"
      end

    "#{name} #{vsn} uses a legacy v1 signature, accepted during the v2 transition " <>
      "(MOB-287); it will be refused once re-signed releases ship"
  end

  # Checks (1) and (2) of the moduledoc — they read only the resolved
  # dependency SCMs, mix.lock, the dep's location, and priv/mob_plugin.pub.
  # Returns the verified public key so the signature check uses the exact key
  # whose fingerprint was trusted.
  defp provenance(plugin_dir, opts) do
    name = Path.basename(plugin_dir)
    scms = Keyword.get_lazy(opts, :scms, &Mix.Project.deps_scms/0)
    lock = Keyword.get_lazy(opts, :lock, &Mix.Dep.Lock.read/0)
    deps_path = Keyword.get_lazy(opts, :deps_path, &Mix.Project.deps_path/0)
    trust_map = Keyword.get_lazy(opts, :trust_map, &TrustStore.load_trusted_plugins/0)

    # A dep switched to `path:`/`git:` keeps its old hexpm line in mix.lock
    # (Mix does not prune it), so the lock alone does not prove Hex — the
    # active SCM does.
    with Hex.SCM <- find_by_name(scms, name),
         {:ok, _vsn} <- hexpm_lock_entry(name, lock),
         true <- Path.expand(plugin_dir) == Path.expand(Path.join(deps_path, name)),
         {:ok, pub} <- Verify.load_pubkey(plugin_dir),
         true <- find_by_name(trust_map, name) == Crypto.fingerprint(pub) do
      {:ok, pub}
    else
      _ -> :error
    end
  end

  # Lock keys are atoms; compare by string so an arbitrary dep-directory
  # basename never creates one.
  defp hexpm_lock_entry(name, lock) do
    Enum.find_value(lock, :error, fn
      {key, {:hex, pkg, vsn, _inner, _managers, _deps, "hexpm", _outer}}
      when is_atom(key) and is_atom(pkg) and is_binary(vsn) ->
        Atom.to_string(key) == name and Atom.to_string(pkg) == name and {:ok, vsn}

      _ ->
        false
    end)
  end

  # Keys are atoms; compare by string so an arbitrary dep-directory basename
  # never creates one.
  defp find_by_name(map, name) do
    Enum.find_value(map, fn {key, value} -> to_string(key) == name and value end)
  end

  # The pre-MOB-74 v1 verification: the payload is the evaluated manifest plus
  # the hashes of the files it references (v1 did not hash the manifest file
  # itself; the manifest map was the signed term instead).
  defp verify_signature(plugin_dir, manifest, pub) do
    with {:ok, signature} <- v1_signature(plugin_dir) do
      file_hashes =
        plugin_dir
        |> Sign.compute_file_hashes(manifest)
        |> List.keydelete(@manifest_file, 0)

      payload = %{manifest: manifest, file_hashes: file_hashes, envelope_version: 1}
      Crypto.verify(payload, signature, pub)
    end
  end

  # `Verify` interns :signature and :envelope_version, which a :safe decode of
  # a v1 envelope needs (see decisions/2026-05-31-verify-safe-atom-intern.md).
  defp v1_signature(plugin_dir) do
    _ = Verify.envelope_atoms()

    with {:ok, bytes} <- File.read(Path.join(plugin_dir, @signature_file)),
         %{signature: sig, envelope_version: 1} when byte_size(sig) == 64 <-
           :erlang.binary_to_term(bytes, [:safe]) do
      {:ok, sig}
    else
      _ -> {:error, :envelope_v1_unsupported}
    end
  rescue
    ArgumentError -> {:error, :envelope_v1_unsupported}
  end
end
