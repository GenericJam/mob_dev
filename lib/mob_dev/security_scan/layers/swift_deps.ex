defmodule MobDev.SecurityScan.Layers.SwiftDeps do
  @moduledoc """
  Audits iOS dependencies via `osv-scanner` recursively over the
  `ios/` directory.

  ## What gets scanned

  `osv-scanner` understands:

    * `Package.resolved` — Swift Package Manager (when SwiftPM is used)
    * `Podfile.lock` — CocoaPods

  Mob's iOS template does not depend on either by default — the iOS
  bridge is built with raw `.m` / `.swift` files plus the bundled OTP
  static libs (libcrypto.a, libbeam.a, etc.). Those static libs are
  audited by the `:bundled_runtime` layer; this layer only covers
  *application-level* iOS dependencies.

  In a stock Mob app this layer typically reports `:not_applicable`,
  which is the correct signal — there's no iOS dependency manifest
  to audit because the app pulls nothing from CocoaPods/SwiftPM.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{LayerResult, OsvScanner}

  @impl true
  def name, do: :swift_deps

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    ios_dir = Path.join(project_root, "ios")

    cond do
      not File.dir?(ios_dir) ->
        %LayerResult{
          name: :swift_deps,
          status: :not_applicable,
          notes: ["no ios/ directory at #{ios_dir}"]
        }

      not has_swift_manifest?(ios_dir) ->
        %LayerResult{
          name: :swift_deps,
          status: :not_applicable,
          notes: [
            "no Package.resolved or Podfile.lock under #{ios_dir}",
            "Mob iOS apps typically have neither — bundled OpenSSL/SQLite are audited by :bundled_runtime"
          ]
        }

      true ->
        run_scan(ios_dir, opts)
    end
  end

  defp has_swift_manifest?(ios_dir) do
    paths = [
      Path.join([ios_dir, "Package.resolved"]),
      Path.join([ios_dir, "**/Package.resolved"]),
      Path.join([ios_dir, "Podfile.lock"]),
      Path.join([ios_dir, "**/Podfile.lock"])
    ]

    Enum.any?(paths, &(Path.wildcard(&1) != []))
  end

  defp run_scan(ios_dir, opts) do
    osv_scan = Keyword.get(opts, :osv_scan_fn, &OsvScanner.scan/3)

    case osv_scan.({:directory, ios_dir}, :swift_deps, []) do
      {:ok, findings} ->
        %LayerResult{
          name: :swift_deps,
          status: :ok,
          findings: findings,
          tools_used: ["osv-scanner"],
          notes: ["osv-scanner: #{length(findings)} finding(s) under #{ios_dir}"]
        }

      {:error, :not_installed} ->
        %LayerResult{
          name: :swift_deps,
          status: :tool_missing,
          notes: ["osv-scanner not installed — install: brew install osv-scanner"]
        }

      {:error, {:scan_failed, reason}} ->
        %LayerResult{
          name: :swift_deps,
          status: :error,
          tools_used: ["osv-scanner"],
          error: "osv-scanner failed: #{reason}"
        }

      {:error, {:not_found, path}} ->
        %LayerResult{
          name: :swift_deps,
          status: :not_applicable,
          notes: ["target path missing: #{path}"]
        }
    end
  end
end
