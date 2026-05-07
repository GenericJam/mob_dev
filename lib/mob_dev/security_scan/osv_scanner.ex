defmodule MobDev.SecurityScan.OsvScanner do
  @moduledoc """
  Wrapper around the `osv-scanner` CLI (https://google.github.io/osv-scanner/).

  `osv-scanner` queries the [OSV.dev](https://osv.dev) database, which
  aggregates advisories from many ecosystems (Hex, Maven/Gradle, Swift
  PM, npm, PyPI, RubyGems, ...) into a single feed. Several Mob scan
  layers (`hex_deps`, `gradle_deps`, `swift_deps`) call this helper so
  the binary integration lives in one place.

  All public functions are pure orchestration — no parsing logic, no
  finding shape. `Parser` does the actual JSON → `Finding` translation,
  which keeps the network/process side easy to mock and the parser
  trivially testable with fixture JSON.
  """

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.OsvScanner.Parser

  @binary "osv-scanner"

  @typedoc """
  What to scan. `{:lockfile, path}` for a single lockfile, `{:directory, path}`
  for a recursive scan that finds every supported manifest under the tree.
  """
  @type target :: {:lockfile, Path.t()} | {:directory, Path.t()}

  @doc "True if `osv-scanner` is on PATH."
  @spec installed?() :: boolean()
  def installed? do
    System.find_executable(@binary) != nil
  end

  @doc """
  Scan a target and return findings tagged with the given `layer`.

  Returns:

    * `{:ok, findings}` — scan completed (findings list may be empty)
    * `{:error, :not_installed}` — binary not on PATH
    * `{:error, {:not_found, path}}` — target path doesn't exist
    * `{:error, {:scan_failed, reason}}` — binary exited non-zero or
      produced unparseable output

  `osv-scanner` exits with code 1 when *findings* are present and 0
  when clean — this function treats both as success and only signals
  `:scan_failed` for true errors (code 127, malformed JSON, etc.).
  """
  @spec scan(target(), atom(), keyword()) ::
          {:ok, [Finding.t()]}
          | {:error,
             :not_installed | {:not_found, Path.t()} | {:scan_failed, String.t()}}
  def scan(target, layer, opts \\ []) when is_atom(layer) do
    runner = Keyword.get(opts, :runner, &default_runner/1)

    cond do
      not target_exists?(target) ->
        {:error, {:not_found, elem(target, 1)}}

      not installed?() and runner == (&default_runner/1) ->
        {:error, :not_installed}

      true ->
        target |> build_args() |> runner.() |> handle_output(layer)
    end
  end

  defp target_exists?({:lockfile, path}), do: File.exists?(path)
  defp target_exists?({:directory, path}), do: File.dir?(path)

  defp build_args({:lockfile, path}) do
    ["scan", "source", "--format=json", "--lockfile=#{path}"]
  end

  defp build_args({:directory, path}) do
    ["scan", "source", "--format=json", "--recursive", path]
  end

  # osv-scanner exit codes (https://google.github.io/osv-scanner/output/#exit-codes):
  #   0   clean (no vulns)
  #   1   success, vulns found
  #   128 no scannable lockfiles found in target
  #   127 tool error (bad args, internal failure, etc.)
  defp default_runner(args) do
    # stderr stays separate so the progress chatter ("Scanning dir ...",
    # "End status: ...") doesn't end up mixed into stdout's JSON.
    case System.cmd(@binary, args, stderr_to_stdout: false) do
      {output, code} when code in [0, 1] -> {:ok, output}
      {_output, 128} -> {:ok, ~s({"results":[]})}
      {output, code} -> {:error, "exit #{code}: #{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp handle_output({:ok, output}, layer) do
    case Jason.decode(output) do
      {:ok, %{} = json} -> {:ok, Parser.findings(json, layer)}
      {:error, decode_error} -> {:error, {:scan_failed, "json decode: #{inspect(decode_error)}"}}
    end
  end

  defp handle_output({:error, reason}, _layer) do
    {:error, {:scan_failed, reason}}
  end
end
