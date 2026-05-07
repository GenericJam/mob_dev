defmodule MobDev.SecurityScan do
  @moduledoc """
  Top-level API for `mix mob.security_scan`.

  Runs every layer of the scan against the current project and
  returns a `Report`. Layers cover:

    * Hex dependency CVEs (`mix_audit` + OSV)
    * Android Gradle dependency CVEs (`osv-scanner`)
    * iOS Swift Package dependency CVEs (`osv-scanner`)
    * Bundled-runtime CVEs — OpenSSL/SQLite/OTP/Elixir baked into
      the OTP tarballs (manifest + fingerprint verification +
      OpenSSL/SQLite/Erlef advisory feeds)
    * C source static analysis (semgrep, flawfinder)
    * Kotlin static analysis (detekt)
    * Swift static analysis (`xcodebuild analyze`)

  Each layer can be disabled with `--skip <name>`. Layers
  never raise: a missing tool or unreadable file lands as a
  `LayerResult` with status `:tool_missing` or `:error`, not
  an exception.
  """

  alias MobDev.SecurityScan.{Report, Runner}

  @default_layers [
    MobDev.SecurityScan.Layers.HexDeps,
    MobDev.SecurityScan.Layers.GradleDeps,
    MobDev.SecurityScan.Layers.SwiftDeps,
    MobDev.SecurityScan.Layers.BundledRuntime,
    MobDev.SecurityScan.Layers.CSource,
    MobDev.SecurityScan.Layers.KotlinSource,
    MobDev.SecurityScan.Layers.SwiftSource
  ]

  @doc """
  Run the scan. `opts` may include:

    * `:layers` — module list, defaults to `default_layers/0`
    * `:skip` — list of layer-name atoms to skip
    * `:project_root` — directory to scan; defaults to `File.cwd!/0`
    * `:on_layer_start` / `:on_layer_done` — progress callbacks
  """
  @spec run(keyword()) :: Report.t()
  def run(opts \\ []) do
    layers = Keyword.get(opts, :layers, default_layers())
    Runner.run(layers, opts)
  end

  @doc "Default layer list. New layers register here as they are built."
  @spec default_layers() :: [module()]
  def default_layers, do: @default_layers
end
