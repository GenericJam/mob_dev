defmodule MobDev.SecurityScan.Finding do
  @moduledoc """
  A single normalized security finding.

  Findings come from many sources — Hex `mix_audit`, `osv-scanner`,
  the OpenSSL/SQLite/Erlef advisory feeds, semgrep, etc. — and are
  normalized into this struct so the report and rubric treat them
  uniformly. `source` records which scanner produced it; `layer`
  records which surface area it covers (`:hex_deps`, `:bundled_runtime`,
  `:c_source`, ...).

  `severity` is one of `:critical`, `:high`, `:medium`, `:low`,
  `:unknown`. Scanners report severity differently (CVSS scores,
  GHSA ratings, vendor scales); upstream callers normalize before
  building a Finding.
  """

  @type severity :: :critical | :high | :medium | :low | :unknown

  @type t :: %__MODULE__{
          id: String.t() | nil,
          severity: severity(),
          package: String.t() | nil,
          version: String.t() | nil,
          fixed_in: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          source: atom(),
          layer: atom()
        }

  @derive Jason.Encoder
  defstruct id: nil,
            severity: :unknown,
            package: nil,
            version: nil,
            fixed_in: nil,
            title: nil,
            description: nil,
            url: nil,
            source: nil,
            layer: nil

  @severity_order %{critical: 0, high: 1, medium: 2, low: 3, unknown: 4}

  @doc """
  Sort order helper: severities ranked critical → unknown.

  Use as `Enum.sort_by(findings, &Finding.sort_key/1)`.
  """
  @spec sort_key(t()) :: {non_neg_integer(), String.t()}
  def sort_key(%__MODULE__{severity: sev, id: id}) do
    {Map.get(@severity_order, sev, 99), id || ""}
  end

  @doc """
  Deduplication key. Two findings dedupe to the same key when they
  describe the same advisory against the same package+version, even
  if they came from different sources (e.g. mix_audit and osv-scanner
  both reporting GHSA-XXXX against `:plug` 1.10).
  """
  @spec dedupe_key(t()) :: {String.t() | nil, String.t() | nil, String.t() | nil}
  def dedupe_key(%__MODULE__{id: id, package: package, version: version}) do
    {id, package, version}
  end
end
