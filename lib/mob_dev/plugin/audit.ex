defmodule MobDev.Plugin.Audit do
  @moduledoc """
  Static-analysis pass over a plugin's source tree.

  Behind `mix mob.audit_plugins` (see `MOB_PLUGIN_SECURITY.md`). Walks the
  plugin's Elixir sources (`lib/**/*.ex{,s}`) with an AST scanner and its C
  NIF sources (`priv/native/**/*.{c,h}`) with a tighter regex pass, flagging
  patterns Mob considers risky:

  - `Code.eval_string/1,2,3` and `Code.compile_string/1,2`
    — the prime arbitrary-code-execution vector. Severity `:high`.
  - `String.to_atom/1` with a non-literal argument — atom-exhaustion risk.
    A literal `String.to_atom("foo")` is fine; flagged only when the argument
    is a variable or expression. Severity `:medium`.
  - `:erlang.binary_to_term/1` — unbounded deserialization. The arity-2 form
    `:erlang.binary_to_term(bin, [:safe])` does not fire (caller has opted
    into the bounded variant). Severity `:high`.
  - `Application.put_env/3,4` targeting `:mob` — would let a plugin silently
    retarget plugin activations, host_config keys, etc. `get_env` is fine.
    Severity `:medium`.
  - File / network I/O escape hatches outside the plugin's own `priv/`:
    `File.write{,!}/1,2`, `File.rm_rf{,!}/1`, `File.cp{,!}/2`, `:os.cmd/1`,
    `System.cmd/2,3`, `Path.expand/1` with a `~` literal. We don't try to
    prove what they touch — flag and let the plugin author either remove or
    justify. Severity `:medium`.
  - In C NIF sources: calls to `system(3)`, `popen(3)`, `execve(2)`, and raw
    `socket(2)` creation. Regex over comment-stripped text. Severities
    `:medium` (`socket`) and `:high` (`system`/`popen`/`execve`).

  Swift / Kotlin sources are out of scope for this commit — the spec
  (`MOB_PLUGIN_SECURITY.md`) calls for proper parsers there, and the task
  surfaces a "not yet audited" summary line instead of guessing with regex.

  All checks are pure given file inputs; the only I/O is reading source
  files off disk.
  """

  @type severity :: :high | :medium | :low

  @type finding :: %{
          severity: severity(),
          rule: atom(),
          plugin: atom() | nil,
          file: String.t(),
          line: pos_integer() | nil,
          snippet: String.t(),
          hint: String.t()
        }

  @type report :: %{
          plugin: atom() | nil,
          findings: [finding()],
          summary: %{high: non_neg_integer(), medium: non_neg_integer(), low: non_neg_integer()},
          kotlin_or_swift_skipped: boolean()
        }

  @elixir_glob "**/*.{ex,exs}"
  @c_glob "**/*.{c,h}"

  @doc """
  Audits a single plugin checked out at `plugin_dir`.

  `manifest` may be `nil` (a tier-0 plugin); only `:name` is read from it for
  attribution in the resulting findings. Returns a `t:report/0` map.
  """
  @spec audit_plugin(Path.t(), map() | nil) :: report()
  def audit_plugin(plugin_dir, manifest) do
    name = (manifest && Map.get(manifest, :name)) || nil

    elixir_findings =
      plugin_dir
      |> elixir_sources()
      |> Enum.flat_map(&audit_elixir_file(&1, plugin_dir, name))

    c_findings =
      plugin_dir
      |> c_sources()
      |> Enum.flat_map(&audit_c_file(&1, plugin_dir, name))

    findings =
      (elixir_findings ++ c_findings)
      |> Enum.sort_by(fn f -> {severity_order(f.severity), f.file, f.line || 0} end)

    %{
      plugin: name,
      findings: findings,
      summary: tally(findings),
      kotlin_or_swift_skipped: has_kotlin_or_swift?(plugin_dir)
    }
  end

  @doc """
  Audits a single Elixir source file in isolation. Public for testing.
  """
  @spec audit_elixir_file(Path.t(), Path.t(), atom() | nil) :: [finding()]
  def audit_elixir_file(path, plugin_dir, plugin_name) do
    rel = relative_to(path, plugin_dir)

    case read_quoted(path) do
      {:ok, ast} ->
        scan_elixir_ast(ast, rel, plugin_name)

      {:error, reason} ->
        [
          %{
            severity: :low,
            rule: :unparseable_source,
            plugin: plugin_name,
            file: rel,
            line: nil,
            snippet: "",
            hint: "could not parse as Elixir: #{reason}"
          }
        ]
    end
  end

  @doc """
  Audits a single C source file in isolation. Public for testing.
  """
  @spec audit_c_file(Path.t(), Path.t(), atom() | nil) :: [finding()]
  def audit_c_file(path, plugin_dir, plugin_name) do
    rel = relative_to(path, plugin_dir)

    case File.read(path) do
      {:ok, source} ->
        source
        |> strip_c_comments()
        |> scan_c_source(rel, plugin_name)

      {:error, reason} ->
        [
          %{
            severity: :low,
            rule: :unreadable_source,
            plugin: plugin_name,
            file: rel,
            line: nil,
            snippet: "",
            hint: "could not read: #{:file.format_error(reason)}"
          }
        ]
    end
  end

  @doc """
  Tally findings into `%{high: n, medium: n, low: n}`. Public for testing.
  """
  @spec tally([finding()]) :: %{
          high: non_neg_integer(),
          medium: non_neg_integer(),
          low: non_neg_integer()
        }
  def tally(findings) do
    Enum.reduce(findings, %{high: 0, medium: 0, low: 0}, fn f, acc ->
      Map.update!(acc, f.severity, &(&1 + 1))
    end)
  end

  @doc """
  Computes the exit code for one or more reports.

  * 0 — every finding is `:low` (or there are none).
  * 1 — at least one `:medium`, no `:high`.
  * 2 — at least one `:high`.

  When `accept_medium?` is true, mediums no longer count toward exit code 1
  (highs still produce 2). Public for testing.
  """
  @spec exit_code([report()], boolean()) :: 0 | 1 | 2
  def exit_code(reports, accept_medium? \\ false) do
    totals =
      Enum.reduce(reports, %{high: 0, medium: 0, low: 0}, fn r, acc ->
        Map.merge(acc, r.summary, fn _k, a, b -> a + b end)
      end)

    cond do
      totals.high > 0 -> 2
      not accept_medium? and totals.medium > 0 -> 1
      true -> 0
    end
  end

  # ── source discovery ──────────────────────────────────────────────────────

  defp elixir_sources(plugin_dir) do
    plugin_dir
    |> Path.join("lib")
    |> Path.join(@elixir_glob)
    |> Path.wildcard()
  end

  defp c_sources(plugin_dir) do
    plugin_dir
    |> Path.join("priv/native")
    |> Path.join(@c_glob)
    |> Path.wildcard()
  end

  defp has_kotlin_or_swift?(plugin_dir) do
    Path.wildcard(Path.join(plugin_dir, "priv/native/**/*.{kt,swift}")) != []
  end

  defp relative_to(path, base) do
    path
    |> Path.relative_to(base)
    |> to_string()
  end

  # ── Elixir AST scanner ────────────────────────────────────────────────────

  defp read_quoted(path) do
    case File.read(path) do
      {:ok, source} ->
        try do
          {:ok, Code.string_to_quoted!(source, columns: true, file: path)}
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, reason} ->
        {:error, :file.format_error(reason)}
    end
  end

  defp scan_elixir_ast(ast, file, plugin) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        new = check_elixir_node(node, file, plugin)
        {node, new ++ acc}
      end)

    Enum.reverse(acc)
  end

  # Code.eval_string/1,2,3 and Code.compile_string/1,2 — :high
  defp check_elixir_node({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, args}, file, plugin)
       when fun in [:eval_string, :compile_string] and is_list(args) do
    [
      finding(
        :high,
        :code_eval,
        plugin,
        file,
        line(meta),
        "Code.#{fun}(...)",
        "Arbitrary code execution. Remove this call or justify it in the manifest."
      )
    ]
  end

  # :erlang.binary_to_term/1 — :high (arity-2 with [:safe] is fine)
  defp check_elixir_node({{:., _, [:erlang, :binary_to_term]}, meta, args}, file, plugin)
       when length(args) == 1 do
    [
      finding(
        :high,
        :unsafe_deserialization,
        plugin,
        file,
        line(meta),
        ":erlang.binary_to_term/1",
        "Use :erlang.binary_to_term(bin, [:safe]) to bound deserialization."
      )
    ]
  end

  # String.to_atom/1 with non-literal argument — :medium
  defp check_elixir_node(
         {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, meta, [arg]},
         file,
         plugin
       ) do
    if literal_binary?(arg) do
      []
    else
      [
        finding(
          :medium,
          :unbounded_atom,
          plugin,
          file,
          line(meta),
          "String.to_atom(<non-literal>)",
          "Use String.to_existing_atom/1 or an explicit whitelist to avoid atom-table exhaustion."
        )
      ]
    end
  end

  # Application.put_env(:mob, ...) — :medium
  defp check_elixir_node(
         {{:., _, [{:__aliases__, _, [:Application]}, :put_env]}, meta, [app | _]} = _node,
         file,
         plugin
       ) do
    if app == :mob do
      [
        finding(
          :medium,
          :mob_env_mutation,
          plugin,
          file,
          line(meta),
          "Application.put_env(:mob, ...)",
          "A plugin should not mutate the :mob app's env; route changes through manifest declarations."
        )
      ]
    else
      []
    end
  end

  # File.write/write!/rm_rf/rm_rf!/cp/cp! — :medium
  defp check_elixir_node({{:., _, [{:__aliases__, _, [:File]}, fun]}, meta, _args}, file, plugin)
       when fun in [:write, :write!, :rm_rf, :rm_rf!, :cp, :cp!] do
    [
      finding(
        :medium,
        :file_io,
        plugin,
        file,
        line(meta),
        "File.#{fun}(...)",
        "File-system mutation outside the plugin's priv/. Remove or justify in the manifest."
      )
    ]
  end

  # :os.cmd/1 — :medium
  defp check_elixir_node({{:., _, [:os, :cmd]}, meta, _args}, file, plugin) do
    [
      finding(
        :medium,
        :process_spawn,
        plugin,
        file,
        line(meta),
        ":os.cmd(...)",
        "Shell-out from a plugin is highly suspect. Remove or justify."
      )
    ]
  end

  # System.cmd/2,3 — :medium
  defp check_elixir_node(
         {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, meta, _args},
         file,
         plugin
       ) do
    [
      finding(
        :medium,
        :process_spawn,
        plugin,
        file,
        line(meta),
        "System.cmd(...)",
        "Process spawn from a plugin is highly suspect. Remove or justify."
      )
    ]
  end

  # Path.expand("~"...) — :medium (home-directory escape)
  defp check_elixir_node(
         {{:., _, [{:__aliases__, _, [:Path]}, :expand]}, meta, [arg | _]},
         file,
         plugin
       ) do
    if home_string?(arg) do
      [
        finding(
          :medium,
          :home_escape,
          plugin,
          file,
          line(meta),
          "Path.expand(\"~...\")",
          "Reaching outside the app sandbox via $HOME. Remove or justify."
        )
      ]
    else
      []
    end
  end

  defp check_elixir_node(_node, _file, _plugin), do: []

  defp literal_binary?(arg) when is_binary(arg), do: true
  defp literal_binary?(_), do: false

  defp home_string?(s) when is_binary(s), do: String.starts_with?(s, "~")
  defp home_string?(_), do: false

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line(_), do: nil

  # ── C source scanner ──────────────────────────────────────────────────────

  # Comment-strip + line-based scan. Regex on stripped source avoids matching
  # the words inside `// system(...)` documentation comments — common in NIF
  # stubs that explain why they *don't* call system(3).
  defp scan_c_source(stripped, file, plugin) do
    stripped
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line_text, ln} -> check_c_line(line_text, ln, file, plugin) end)
  end

  @c_rules [
    {:high, :process_spawn, ~r/\bsystem\s*\(/, "system(3) call",
     "Process spawn from a NIF is highly suspect."},
    {:high, :process_spawn, ~r/\bpopen\s*\(/, "popen(3) call",
     "Process spawn from a NIF is highly suspect."},
    {:high, :process_spawn, ~r/\bexecve\s*\(/, "execve(2) call",
     "Process spawn from a NIF is highly suspect."},
    {:medium, :raw_socket, ~r/\bsocket\s*\(/, "socket(2) call",
     "Raw network access from a NIF should be declared and justified."}
  ]

  defp check_c_line(line_text, ln, file, plugin) do
    @c_rules
    |> Enum.filter(fn {_sev, _rule, regex, _snippet, _hint} ->
      Regex.match?(regex, line_text)
    end)
    |> Enum.map(fn {sev, rule, _regex, snippet, hint} ->
      finding(sev, rule, plugin, file, ln, snippet, hint)
    end)
  end

  # Strip `/* ... */` and `// ...` comments. Keeps line counts intact by
  # replacing the comment body with spaces and preserving newlines.
  defp strip_c_comments(source) do
    source
    |> strip_block_comments()
    |> strip_line_comments()
  end

  defp strip_block_comments(source) do
    Regex.replace(~r{/\*.*?\*/}s, source, fn match ->
      match
      |> String.graphemes()
      |> Enum.map(fn
        "\n" -> "\n"
        _ -> " "
      end)
      |> Enum.join()
    end)
  end

  defp strip_line_comments(source) do
    Regex.replace(~r{//[^\n]*}, source, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp finding(severity, rule, plugin, file, line, snippet, hint) do
    %{
      severity: severity,
      rule: rule,
      plugin: plugin,
      file: file,
      line: line,
      snippet: snippet,
      hint: hint
    }
  end

  defp severity_order(:high), do: 0
  defp severity_order(:medium), do: 1
  defp severity_order(:low), do: 2
end
