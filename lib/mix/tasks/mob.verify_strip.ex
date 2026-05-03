defmodule Mix.Tasks.Mob.VerifyStrip do
  @shortdoc "Eager-load every shipped .beam on a connected device, report failures"

  @moduledoc """
  Boot-safety verification for stripped Mob app builds.

  After deploying a slim build (where `mix mob.release` has dropped OTP
  libs to shrink the IPA), this task connects to the running app's BEAM
  and asks it to force-load every `.beam` shipped in the bundle. Any
  module that fails to load — typically because a stripped lib was
  needed by a transitive dep — shows up here.

  ## Usage

      # First connect to the device (sets up tunnels + verifies node):
      mix mob.connect --no-iex

      # Then run the verifier:
      mix mob.verify_strip

  Or pass `--node` explicitly to skip auto-discovery.

  ## What it checks

    1. **Eager load sweep** — `Code.ensure_loaded/1` on every `.beam`
       under `<files_dir>/otp/`. Catches "module X depends on stripped
       module Y" at load time.

    2. **Harness exercise** — runs `MobDev.OtpTrace.Harness.all/0` on
       the device and reports any exception. Catches issues with the
       common Elixir surface even if individual modules loaded fine.

  ## What it does NOT check

  App-specific code paths. If your app calls `:public_key.something`
  when the user opens a particular screen, this verifier won't find it
  unless the screen is opened. Run your own integration tests for that.

  ## Output

  Plain mode prints a summary + per-failure detail. Exit code is 0 if
  everything loaded + harness passed, 1 otherwise.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [node: :string])

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    node = resolve_node(opts[:node])

    Mix.shell().info("Verifying strip safety on #{node}…\n")

    case :rpc.call(node, Mob.Diag, :verify_loaded_modules, []) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")

        Mix.shell().error("""

        Is `Mob.Diag` deployed to the device? It ships with the `mob`
        runtime library — push the latest BEAMs first:

            mix mob.push

        And confirm the device's mob version is recent enough.
        """)

        exit({:shutdown, 1})

      report ->
        print_load_report(report)
        if report.failed != [], do: exit({:shutdown, 1})
    end
  end

  defp resolve_node(nil) do
    case Node.list() do
      [] ->
        Mix.raise("""
        No connected nodes found. Run `mix mob.connect --no-iex` first
        in a separate terminal so the device's BEAM is reachable.

        Or pass --node <name@host> explicitly.
        """)

      [single] ->
        single

      multiple ->
        Mix.raise("""
        Multiple nodes connected — specify with --node:

        #{Enum.map_join(multiple, "\n", &"  #{&1}")}
        """)
    end
  end

  defp resolve_node(node_str), do: String.to_atom(node_str)

  defp print_load_report(report) do
    h1 = IO.ANSI.bright()
    green = IO.ANSI.green()
    red = IO.ANSI.red()
    reset = IO.ANSI.reset()

    Mix.shell().info("#{h1}=== Eager-load sweep ==={reset}")
    Mix.shell().info("  OTP root:   #{report.otp_root || "(not detected)"}")
    Mix.shell().info("  Total .beam files: #{report.total}")
    Mix.shell().info("  #{green}Loaded: #{report.loaded}#{reset}")

    case report.failed do
      [] ->
        Mix.shell().info(
          "  #{green}✓ all modules loaded — strip is safe at the load-time level#{reset}"
        )

      failures ->
        Mix.shell().error("  #{red}✗ #{length(failures)} module(s) failed to load:#{reset}")

        for %{module: mod, reason: reason} <- Enum.take(failures, 20) do
          Mix.shell().error("    #{inspect(mod)}  — #{inspect(reason)}")
        end

        if length(failures) > 20 do
          Mix.shell().error("    … and #{length(failures) - 20} more")
        end
    end

    Mix.shell().info("  Elapsed: #{format_us(report.elapsed_us)}")
  end

  defp format_us(us) when us < 1_000, do: "#{us}μs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
