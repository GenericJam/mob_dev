defmodule MobDev.SecurityScan.Layers.GradleDeps do
  @moduledoc """
  Audits Android dependencies via `osv-scanner` recursively over
  the `android/` directory.

  ## What gets scanned

  `osv-scanner` understands these Android-relevant manifests:

    * `gradle.lockfile` — the result of Gradle's [dependency locking][1].
      Captures the exact transitive dep tree.
    * `buildscript-gradle.lockfile` — same idea, for buildscript classpath.
    * `pom.xml` — Maven, occasionally appears in Gradle projects.

  Mob's Android template does NOT enable dependency locking by default,
  so a fresh `mix mob.new` app will report `:not_applicable` for this
  layer until the user opts in. The layer's notes spell out the
  remediation.

  ## Enabling Gradle dependency locking

      // android/build.gradle
      allprojects {
        configurations.all {
          resolutionStrategy.activateDependencyLocking()
        }
      }

      // android/app/build.gradle
      dependencyLocking {
        lockAllConfigurations()
      }

  Then `cd android && ./gradlew :app:dependencies --write-locks`
  creates `gradle.lockfile`.

  [1]: https://docs.gradle.org/current/userguide/dependency_locking.html
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{LayerResult, OsvScanner}

  @impl true
  def name, do: :gradle_deps

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    android_dir = Path.join(project_root, "android")

    if File.dir?(android_dir) do
      run_scan(android_dir, opts)
    else
      %LayerResult{
        name: :gradle_deps,
        status: :not_applicable,
        notes: ["no android/ directory at #{android_dir}"]
      }
    end
  end

  defp run_scan(android_dir, opts) do
    osv_scan = Keyword.get(opts, :osv_scan_fn, &OsvScanner.scan/3)

    case osv_scan.({:directory, android_dir}, :gradle_deps, []) do
      {:ok, findings} when findings == [] ->
        %LayerResult{
          name: :gradle_deps,
          status: :ok,
          findings: [],
          tools_used: ["osv-scanner"],
          notes: notes_with_lockfile_guidance(android_dir)
        }

      {:ok, findings} ->
        %LayerResult{
          name: :gradle_deps,
          status: :ok,
          findings: findings,
          tools_used: ["osv-scanner"],
          notes: ["osv-scanner: #{length(findings)} finding(s) under #{android_dir}"]
        }

      {:error, :not_installed} ->
        %LayerResult{
          name: :gradle_deps,
          status: :tool_missing,
          notes: [
            "osv-scanner not installed — install: brew install osv-scanner",
            "without it Android Gradle deps are not audited"
          ]
        }

      {:error, {:scan_failed, reason}} ->
        %LayerResult{
          name: :gradle_deps,
          status: :error,
          tools_used: ["osv-scanner"],
          error: "osv-scanner failed: #{reason}"
        }

      {:error, {:not_found, path}} ->
        %LayerResult{
          name: :gradle_deps,
          status: :not_applicable,
          notes: ["target path missing: #{path}"]
        }
    end
  end

  defp notes_with_lockfile_guidance(android_dir) do
    lockfile = Path.join([android_dir, "app", "gradle.lockfile"])

    base = "osv-scanner ran cleanly under #{android_dir} (0 findings)"

    if File.exists?(lockfile) do
      [base, "scanned manifests including gradle.lockfile"]
    else
      [
        base,
        "NOTE: no gradle.lockfile present — only declared deps in build.gradle were checked",
        "for transitive coverage, enable Gradle dependency locking and run `./gradlew :app:dependencies --write-locks`"
      ]
    end
  end
end
