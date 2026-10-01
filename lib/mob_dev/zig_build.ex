defmodule MobDev.ZigBuild do
  @moduledoc """
  Runs a native `zig build` (the iOS simulator/device binary, the Android
  per-ABI objects, Zigler NIF cross-compiles) and turns its result into `:ok`
  or an error that names what broke.

  Two things this owns (MOB-344):

    * **Warnings are not failures.** Zig's build runner prints every step
      that wrote to stderr in its failure layout — step tree, a `w` marker and
      a `failed command:` line — even when the step exited 0. A plugin NIF
      whose clang compile emits one warning therefore read as a failed
      compile while the build went on to succeed. We run zig with
      `ZIG_BUILD_ERROR_STYLE=minimal` (unless the caller's environment already
      chose a style), which drops that command-line context, and list the
      steps that only warned after a successful build.

    * **A failure names the plugin and the compiler error.** zig's own exit
      line only says the build failed. On a non-zero exit we parse the
      captured output for the failing steps and the compiler `error:` lines,
      and attribute them to the plugin whose NIF source failed, so the
      `✗ <platform> native build failed:` line says which plugin to fix.

  The output is still streamed live; it's captured alongside for the parse.
  """

  defmodule Tee do
    @moduledoc false
    # Collectable for System.cmd/3 `:into`: echoes each chunk to stdout as it
    # arrives (the live build log) and accumulates it for MobDev.ZigBuild.report/4.
    defstruct acc: []

    defimpl Collectable do
      @spec into(%MobDev.ZigBuild.Tee{}) ::
              {iodata(),
               (iodata(), {:cont, binary()} | :done | :halt -> iodata() | binary() | :ok)}
      def into(tee) do
        collector = fn
          acc, {:cont, chunk} ->
            IO.write(chunk)
            [acc | chunk]

          acc, :done ->
            IO.iodata_to_binary(acc)

          _acc, :halt ->
            :ok
        end

        {tee.acc, collector}
      end
    end
  end

  alias MobDev.Plugin.Merge

  @typedoc "A plugin NIF source zig compiles: the plugin's name and the source path."
  @type nif_source :: {plugin :: atom() | String.t(), source :: Path.t()}

  @max_error_lines 20

  @doc """
  Every C-family and zig NIF source `platform` compiles for the activated
  `plugins` (`MobDev.Plugin.activated/0`), paired with the plugin's name — the
  `nif_sources` argument of `run/4`.
  """
  @spec plugin_nif_sources([Merge.plugin()], :ios | :android) :: [nif_source()]
  def plugin_nif_sources(plugins, platform) do
    for {_dir, manifest} = plugin <- plugins,
        is_map(manifest),
        source <-
          Merge.nif_sources([plugin], platform) ++ Merge.zig_nif_sources([plugin], platform),
        do: {manifest[:name], source}
  end

  @doc """
  Runs `zig` with `args`. `label` names the build in the error
  (`"zig build binary (iOS sim)"`); `nif_sources` are the plugin NIF sources
  the build compiles, used to name the plugin a failure belongs to.

  Options: `:zig`, the executable (default `"zig"` on PATH); `:cd`, the
  directory to run in.
  """
  @spec run([String.t()], String.t(), [nif_source()], keyword()) :: :ok | {:error, String.t()}
  def run(args, label, nif_sources \\ [], opts \\ []) do
    cmd_opts =
      [stderr_to_stdout: true, into: %__MODULE__.Tee{}, env: env()] ++
        Keyword.take(opts, [:cd])

    {output, code} = System.cmd(Keyword.get(opts, :zig, "zig"), args, cmd_opts)

    case report(output, code, label, nif_sources) do
      {:ok, []} ->
        :ok

      {:ok, warned} ->
        IO.puts(
          "  #{IO.ANSI.yellow()}⚠  compiler warnings (not failures; the build succeeded) in: " <>
            "#{Enum.join(warned, ", ")}#{IO.ANSI.reset()}"
        )

        :ok

      {:error, _} = error ->
        error
    end
  end

  # Respect a style the user set; otherwise ask zig not to dress warnings up
  # as failed commands.
  defp env do
    case System.get_env("ZIG_BUILD_ERROR_STYLE") do
      nil -> [{"ZIG_BUILD_ERROR_STYLE", "minimal"}]
      _ -> []
    end
  end

  @doc """
  Interprets zig's captured `output` and exit `code`.

  Exit 0 is `{:ok, warned_steps}` (steps zig marked `w`: stderr output, no
  failure). Non-zero is `{:error, message}`: `label` plus the exit code, then
  each plugin whose NIF source failed with its compiler errors, then any
  failing step or error line not tied to a plugin.
  """
  @spec report(String.t(), non_neg_integer(), String.t(), [nif_source()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def report(output, 0, _label, _nif_sources), do: {:ok, steps_marked(output, ~r/ w$/)}

  def report(output, code, label, nif_sources) do
    failed_steps = steps_marked(output, ~r/ (failure|\d+ errors?)$/)
    errors = error_lines(output)

    {plugin_sections, claimed_steps, claimed_errors} =
      Enum.reduce(nif_sources, {[], [], []}, fn {plugin, source}, {sections, steps, errs} ->
        file = Path.basename(source)
        nif = Path.rootname(file)
        nif_re = ~r/(^|[^A-Za-z0-9_])#{Regex.escape(nif)}([^A-Za-z0-9_]|$)/
        own_steps = Enum.filter(failed_steps, &Regex.match?(nif_re, &1))
        own_errors = Enum.filter(errors, &String.contains?(&1, "/" <> file <> ":"))

        if own_steps == [] and own_errors == [] do
          {sections, steps, errs}
        else
          section =
            ["    plugin #{plugin}: #{file} failed to compile (#{source})" | indent(own_errors)]

          {[section | sections], steps ++ own_steps, errs ++ own_errors}
        end
      end)

    other_steps = failed_steps -- claimed_steps
    other_errors = errors -- claimed_errors

    other =
      case {other_steps, other_errors} do
        {[], []} ->
          []

        _ ->
          steps = Enum.map(other_steps, &"    failed step: #{&1}")
          [steps ++ indent(other_errors)]
      end

    message =
      [["#{label} exited #{code}"] | Enum.reverse(plugin_sections) ++ other]
      |> List.flatten()
      |> Enum.join("\n")

    {:error, message}
  end

  # Step headers zig prints for a step with messages: the step name followed by
  # a status marker, optionally behind a `+- ` tree prefix (the build summary).
  # `transitive failure` rows are the dependants of a failure, not failures.
  defp steps_marked(output, marker) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.map(&(&1 |> String.replace(~r/^[\s|+\-]*/, "") |> String.trim_trailing()))
    |> Enum.filter(
      &(Regex.match?(marker, &1) and not String.ends_with?(&1, "transitive failure"))
    )
    |> Enum.map(&Regex.replace(marker, &1, ""))
    |> Enum.uniq()
  end

  # Compiler diagnostics (`path:line:col: error: ...`, `fatal error: ...`) and
  # zig's own `error:` lines, minus the generic ones that only restate that
  # something failed.
  defp error_lines(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(
      &(Regex.match?(~r/: (fatal )?error: /, &1) or String.starts_with?(&1, "error: "))
    )
    |> Enum.reject(
      &(String.starts_with?(&1, "error: process exited with error code") or
          String.starts_with?(&1, "error: the following build command failed"))
    )
    |> Enum.uniq()
    |> Enum.take(@max_error_lines)
  end

  defp indent(lines), do: Enum.map(lines, &"      #{&1}")
end
