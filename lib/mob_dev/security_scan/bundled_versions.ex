defmodule MobDev.SecurityScan.BundledVersions do
  @moduledoc """
  Loads `priv/security/bundled_versions.exs` — the source-of-truth
  manifest of what versions ship inside the OTP tarballs that
  `MobDev.OtpDownloader` distributes.

  See [`priv/security/bundled_versions.exs`](priv/security/bundled_versions.exs)
  for the full schema and update procedure.

  ## Why a manifest, not a fingerprint-only approach

  Manifest first, fingerprint second. The manifest is a *claim*
  reviewable in git — every PR that touches it is auditable.
  Fingerprinting is the *receipt* that proves the claim.

  A fingerprint-only approach can silently fail when build flags
  change and a version string is stripped or moves to a different
  binary; the scanner just reports "version unknown" and you stop
  noticing. A manifest-first approach forces a human to write down
  what shipped — and the fingerprinter then catches drift.
  """

  @external_resource Path.join([__DIR__, "..", "..", "..", "priv", "security", "bundled_versions.exs"])

  @manifest_path Path.join([
                   :code.priv_dir(:mob_dev) |> to_string(),
                   "security",
                   "bundled_versions.exs"
                 ])

  @doc "Path to the manifest .exs file."
  @spec manifest_path() :: Path.t()
  def manifest_path, do: @manifest_path

  @doc """
  Load the manifest from disk. Returns the parsed map.

  Raises if the file is missing or doesn't evaluate to a map with
  the expected shape — the manifest is a hard requirement for the
  bundled-runtime scan layer; a missing file is a real bug, not a
  soft warning.
  """
  @spec load() :: %{
          active_hash: String.t(),
          bundles: %{String.t() => map()}
        }
  def load do
    path = manifest_path()

    unless File.exists?(path) do
      raise "bundled versions manifest missing at #{path}"
    end

    {manifest, _bindings} = Code.eval_file(path)
    validate!(manifest)
    manifest
  end

  @doc """
  Return the bundle entry for a given OTP tarball hash.

  Returns `{:ok, bundle}` when present, `{:error, :unknown_hash}`
  otherwise. Useful for the fingerprinter when the hash on disk
  doesn't match the manifest's `:active_hash` — the tarball might
  be from an older or unpublished build.
  """
  @spec for_hash(String.t()) :: {:ok, map()} | {:error, :unknown_hash}
  def for_hash(hash) when is_binary(hash) do
    case Map.fetch(load().bundles, hash) do
      {:ok, bundle} -> {:ok, bundle}
      :error -> {:error, :unknown_hash}
    end
  end

  @doc "Return the currently active bundle (the hash Mob is shipping today)."
  @spec active() :: map()
  def active do
    manifest = load()
    Map.fetch!(manifest.bundles, manifest.active_hash)
  end

  defp validate!(%{active_hash: hash, bundles: bundles})
       when is_binary(hash) and is_map(bundles) do
    unless Map.has_key?(bundles, hash) do
      raise "bundled versions manifest: active_hash #{inspect(hash)} not found in :bundles"
    end

    Enum.each(bundles, fn {h, bundle} -> validate_bundle!(h, bundle) end)
    :ok
  end

  defp validate!(other) do
    raise "bundled versions manifest must be %{active_hash: ..., bundles: %{...}}; got #{inspect(other)}"
  end

  @required_fields [:erts, :otp_release, :elixir, :openssl, :exqlite_beam]

  defp validate_bundle!(hash, bundle) when is_map(bundle) do
    Enum.each(@required_fields, fn key ->
      unless Map.has_key?(bundle, key) do
        raise "bundled versions manifest: bundle #{inspect(hash)} missing required field #{inspect(key)}"
      end
    end)
  end

  defp validate_bundle!(hash, other) do
    raise "bundled versions manifest: bundle #{inspect(hash)} must be a map, got #{inspect(other)}"
  end
end
