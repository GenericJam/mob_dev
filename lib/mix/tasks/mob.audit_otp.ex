defmodule Mix.Tasks.Mob.AuditOtp do
  @shortdoc "Reports which OTP libs your bundled app actually uses"

  @moduledoc """
  Walks an OTP runtime tree and tells you which libraries are dead weight.

  Reads each `.beam` file's `imports` chunk to build a call graph, seeds
  reachability from your app's modules + the OTP runtime essentials
  (kernel/stdlib/elixir/logger/sasl), and reports:

    * Libraries with zero reachable modules → safe to strip entirely
    * Duplicate library versions → keep only the newest
    * Foreign apps from another project's release tree → cache cruft
    * Per-lib breakdown of reachable vs total module count + KB

  ## Usage

      mix mob.audit_otp                         # audit the most recent release tree
      mix mob.audit_otp --root path/to/otp      # audit a specific tree
      mix mob.audit_otp --json                  # machine-readable output

  ## Where the audit reads from

  Looks for an OTP root in this order:
    1. `--root` arg if given
    2. `_build/mob_release/<App>.app/otp` (latest release build)
    3. The iOS device cache at `~/.mob/cache/otp-ios-device-*`

  ## What this is NOT (yet)

  Read-only. Does not modify the bundle. The companion `mix mob.release
  --slim` will use the same audit to drive auto-stripping; this task is
  the dry-run that lets you see what would happen.
  """

  use Mix.Task

  alias MobDev.OtpAudit

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [root: :string, json: :boolean, app: :string])

    root = resolve_root(opts[:root])
    app_name = opts[:app] || infer_app_name()

    Mix.shell().info("Auditing OTP tree: #{root}")
    if app_name, do: Mix.shell().info("App entry point: #{app_name}\n")

    report = OtpAudit.audit(root, app_name: app_name && String.to_atom(to_string(app_name)))

    if opts[:json] do
      report
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      print_report(report)
    end
  end

  defp resolve_root(nil) do
    candidates =
      Path.wildcard("_build/mob_release/*.app/otp") ++
        Path.wildcard(Path.expand("~/.mob/cache/otp-ios-device-*"))

    case Enum.find(candidates, &File.dir?/1) do
      nil ->
        Mix.raise("""
        No OTP tree found.

        Run `mix mob.release --ios` first, or pass `--root path/to/otp`.

        Searched:
        #{Enum.map_join(candidates, "\n", &"  #{&1}")}
        """)

      path ->
        path
    end
  end

  defp resolve_root(path), do: path

  defp infer_app_name do
    case Mix.Project.get() do
      nil -> nil
      _ -> Mix.Project.config()[:app]
    end
  end

  defp print_report(r) do
    h1 = IO.ANSI.bright()
    dim = IO.ANSI.faint()
    yellow = IO.ANSI.yellow()
    red = IO.ANSI.red()
    reset = IO.ANSI.reset()

    Mix.shell().info("#{h1}=== Per-library breakdown ==={reset}")
    Mix.shell().info("(libs sorted by total size; ✗ = nothing reachable, ◐ = partly used)")
    Mix.shell().info("")

    for lib <- r.libs do
      icon =
        cond do
          lib.modules_reachable == 0 -> "#{red}✗#{reset}"
          lib.modules_reachable < lib.modules_total -> "#{yellow}◐#{reset}"
          true -> "✓"
        end

      version = if lib.version, do: "-#{lib.version}", else: ""

      Mix.shell().info(
        "  #{icon} #{String.pad_trailing("#{lib.name}#{version}", 30)}" <>
          "  #{format_kb(lib.kb_total)}" <>
          "  #{lib.modules_reachable}/#{lib.modules_total} modules"
      )
    end

    Mix.shell().info("")
    Mix.shell().info("#{h1}=== Strippable (no reachable modules) ==={reset}")

    if r.strippable_libs == [] do
      Mix.shell().info("  #{dim}none — every shipped lib has at least one used module#{reset}")
    else
      for name <- r.strippable_libs do
        lib = Enum.find(r.libs, &(&1.name == name))
        Mix.shell().info("  #{red}#{name}#{reset}  #{format_kb(lib.kb_total)}")
      end
    end

    if map_size(r.duplicates) > 0 do
      Mix.shell().info("\n#{h1}=== Duplicate library versions ==={reset}")
      Mix.shell().info("(only the highest version is reachable; older ones are cache cruft)")

      for {name, dupe_paths} <- r.duplicates, dupe_path <- dupe_paths do
        Mix.shell().info("  #{yellow}#{name}#{reset}  obsolete: #{Path.basename(dupe_path)}")
      end
    end

    if r.foreign_apps != [] do
      Mix.shell().info("\n#{h1}=== Foreign apps in lib/ ==={reset}")
      Mix.shell().info("(other projects' code in your release — clean your OTP cache)")

      for path <- r.foreign_apps do
        Mix.shell().info("  #{red}#{Path.basename(path)}#{reset}")
      end
    end

    duplicate_kb = duplicate_kb(r)
    foreign_kb = foreign_kb(r)
    estimated_savings = r.strippable_kb + duplicate_kb + foreign_kb

    Mix.shell().info("\n#{h1}=== Summary ==={reset}")
    Mix.shell().info("  Total shipped:        #{format_kb(r.total_kb)}")
    Mix.shell().info("  Reachable:            #{format_kb(r.reachable_kb)}")
    Mix.shell().info("  Strippable libs:      #{format_kb(r.strippable_kb)}")
    Mix.shell().info("  Duplicate versions:   #{format_kb(duplicate_kb)}")
    Mix.shell().info("  Foreign apps:         #{format_kb(foreign_kb)}")

    Mix.shell().info("  #{h1}Total potential savings: #{format_kb(estimated_savings)}#{reset}\n")
  end

  defp duplicate_kb(r) do
    r.duplicates
    |> Enum.flat_map(fn {_name, paths} -> paths end)
    |> Enum.map(&dir_size_kb/1)
    |> Enum.sum()
  end

  defp foreign_kb(r) do
    r.foreign_apps |> Enum.map(&dir_size_kb/1) |> Enum.sum()
  end

  defp dir_size_kb(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> List.first() |> String.to_integer()
      _ -> 0
    end
  end

  defp format_kb(kb) when kb >= 1024, do: "#{Float.round(kb / 1024, 1)} MB"
  defp format_kb(kb), do: "#{kb} KB"
end
