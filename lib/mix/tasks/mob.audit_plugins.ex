defmodule Mix.Tasks.Mob.AuditPlugins do
  use Mix.Task

  @shortdoc "Static-analysis audit of activated Mob plugins"

  @moduledoc """
  Scans every activated Mob plugin's Elixir + C source for risky patterns
  (see `MOB_PLUGIN_SECURITY.md`'s default ruleset).

      mix mob.audit_plugins
      mix mob.audit_plugins --plugin mob_demo_haptic_extras
      mix mob.audit_plugins --accept-medium

  Rules implemented (in `MobDev.Plugin.Audit`):

    * `Code.eval_string/1,2,3` and `Code.compile_string/1,2`           (high)
    * `:erlang.binary_to_term/1` (the unbounded arity-1 form)          (high)
    * `String.to_atom/1` with a non-literal argument                   (medium)
    * `Application.put_env(:mob, ...)`                                 (medium)
    * `File.write/cp/rm_rf`, `:os.cmd`, `System.cmd`, `Path.expand("~")` (medium)
    * `system(3)`, `popen(3)`, `execve(2)`, `socket(2)` in NIF C       (high/medium)

  Kotlin and Swift sources are reported as "not yet audited" — proper
  parsers land in a follow-up commit.

  ## Options

    * `--plugin <name>` — scope the audit to one activated plugin.
    * `--accept-medium` — exit 0 when only mediums are found (highs still
      produce exit 2). Use after you've reviewed and decided to live with
      the medium findings.

  ## Exit code

    * `0` — no findings, or only `:low` findings, or `:medium` findings with
      `--accept-medium`.
    * `1` — at least one `:medium` finding (without `--accept-medium`).
    * `2` — at least one `:high` finding.
  """

  alias MobDev.Plugin
  alias MobDev.Plugin.{Audit, Manifest, Report}

  @switches [plugin: :string, accept_medium: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")

    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    accept_medium? = Keyword.get(opts, :accept_medium, false)
    only = parse_only(opts[:plugin])

    reports = audit_all(only)
    output = Report.render_audit(reports)

    IO.puts("\n" <> output <> "\n")

    case Audit.exit_code(reports, accept_medium?) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  @doc """
  Audits every activated plugin, optionally filtered to one name. Public for
  testing — the matching CLI invocation is `mix mob.audit_plugins`.
  """
  @spec audit_all(atom() | nil) :: [Audit.report()]
  def audit_all(only \\ nil) do
    plugins = activated_plugins()

    plugins
    |> Enum.filter(fn {name, _dir, _manifest} -> only == nil or name == only end)
    |> Enum.map(fn {name, dir, manifest} ->
      manifest = manifest || %{name: name}
      Audit.audit_plugin(dir, manifest)
    end)
  end

  @doc """
  Returns `{name, dir, manifest}` for every activated plugin, resolving names
  through `Mix.Project.deps_paths/0`. Public for testing.
  """
  @spec activated_plugins() :: [{atom(), Path.t(), map() | nil}]
  def activated_plugins do
    deps = Mix.Project.deps_paths()

    for name <- Plugin.activated_names(), dir = deps[name], not is_nil(dir) do
      manifest =
        case Manifest.load(dir) do
          {:ok, m} -> m
          {:error, _} -> nil
        end

      {name, dir, manifest}
    end
  end

  defp parse_only(nil), do: nil
  defp parse_only(name) when is_binary(name), do: String.to_atom(name)
end
