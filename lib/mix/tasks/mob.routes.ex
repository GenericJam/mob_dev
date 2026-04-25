defmodule Mix.Tasks.Mob.Routes do
  use Mix.Task

  @shortdoc "Validate navigation destinations in push_screen/reset_to/pop_to calls"

  @moduledoc """
  Walks all `lib/**/*.ex` files and checks that every module passed to
  `push_screen/2`, `reset_to/2`, or `pop_to/2` resolves to a loadable module.

  Unresolvable destinations are printed as warnings. Use `--strict` to exit
  non-zero (for CI).

  Examples:

      mix mob.routes
      mix mob.routes --strict

  ## What is checked

  - `Mob.Socket.push_screen(socket, MyApp.SomeScreen)`
  - `Mob.Socket.push_screen(socket, MyApp.SomeScreen, params)`
  - `Mob.Socket.reset_to(socket, MyApp.SomeScreen)`
  - `Mob.Socket.pop_to(socket, MyApp.SomeScreen)`
  - Unqualified forms: `push_screen(socket, ...)`, `reset_to(...)`, `pop_to(...)`

  ## What is NOT checked

  - Dynamic destinations: `push_screen(socket, some_variable)` — skipped silently.
  - Registered name atoms (e.g. `:main`) — these require the app to be running
    to verify against `Mob.Nav.Registry`; they are skipped with a note.

  ## Under the hood

      mix compile   # ensure all modules are compiled before verifying

      # For each lib/**/*.ex file:
      Code.string_to_quoted(source, file: file)   # parse to AST
      Macro.prewalk(ast, ...)                      # find push_screen/reset_to/pop_to calls
      Code.ensure_loaded(MyApp.SomeScreen)         # verify module is loadable

  This is pure static analysis — it parses the source and checks the compiled
  modules on disk. No app process is started. `Code.ensure_loaded/1` is the
  same function the BEAM uses internally to check whether a module exists.
  """

  @nav_fns ~w(push_screen reset_to pop_to)a

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [strict: :boolean])
    strict = Keyword.get(opts, :strict, false)

    Mix.Task.run("compile")

    refs = collect_nav_refs()
    {ok, bad} = Enum.split_with(refs, fn r -> r.valid end)
    skipped = Enum.filter(refs, fn r -> r.skipped end)

    total = length(refs) - length(skipped)
    IO.puts("")

    if refs == [] do
      IO.puts("#{IO.ANSI.yellow()}No navigation calls found in lib/.#{IO.ANSI.reset()}")
      IO.puts("")
      return(false, strict)
    end

    if bad == [] do
      IO.puts(
        "#{IO.ANSI.green()}✓ #{total} navigation reference(s) valid" <>
          skipped_note(skipped) <> "#{IO.ANSI.reset()}"
      )
    else
      IO.puts(
        "#{IO.ANSI.red()}✗ #{length(bad)} unresolvable navigation destination(s):#{IO.ANSI.reset()}\n"
      )

      Enum.each(bad, fn %{file: file, line: line, fn_name: fn_name, dest: dest} ->
        IO.puts(
          "  #{IO.ANSI.yellow()}#{file}:#{line}#{IO.ANSI.reset()}  " <>
            "#{fn_name}(socket, #{inspect(dest)})"
        )

        IO.puts("    Module #{inspect(dest)} could not be loaded.")
      end)

      if skipped != [] do
        IO.puts("")

        IO.puts(
          "  #{IO.ANSI.cyan()}#{length(skipped)} dynamic/named destination(s) skipped " <>
            "(cannot verify at compile time)#{IO.ANSI.reset()}"
        )
      end
    end

    IO.puts("")
    _ = ok
    return(bad != [], strict)
  end

  # ── AST extraction ───────────────────────────────────────────────────────────

  defp collect_nav_refs do
    Path.wildcard("lib/**/*.ex")
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, source} ->
          case Code.string_to_quoted(source, file: file, columns: false) do
            {:ok, ast} -> extract_nav_calls(ast, file)
            {:error, _} -> []
          end

        {:error, _} ->
          []
      end
    end)
  end

  defp extract_nav_calls(ast, file) do
    {_, refs} =
      Macro.prewalk(ast, [], fn node, acc ->
        case nav_call(node) do
          {fn_name, meta, dest_ast} ->
            dest = resolve_dest(dest_ast)
            {valid, skipped} = classify(dest)

            ref = %{
              file: file,
              line: Keyword.get(meta, :line, 0),
              fn_name: fn_name,
              dest: dest,
              valid: valid,
              skipped: skipped
            }

            {node, [ref | acc]}

          nil ->
            {node, acc}
        end
      end)

    refs
  end

  # Mob.Socket.push_screen / reset_to / pop_to with at least 2 args
  defp nav_call(
         {{:., meta, [{:__aliases__, _, [:Mob, :Socket]}, fn_name]}, _, [_socket, dest | _]}
       )
       when fn_name in @nav_fns,
       do: {fn_name, meta, dest}

  # Unqualified push_screen / reset_to / pop_to (imported via use Mob.Screen)
  defp nav_call({fn_name, meta, [_socket, dest | _]})
       when fn_name in @nav_fns and is_list(meta),
       do: {fn_name, meta, dest}

  defp nav_call(_), do: nil

  # ── Destination resolution ───────────────────────────────────────────────────

  defp resolve_dest({:__aliases__, _, parts}), do: Module.concat(parts)
  defp resolve_dest(atom) when is_atom(atom), do: atom
  defp resolve_dest(_), do: :dynamic

  # skip — dynamic value
  defp classify(:dynamic), do: {true, true}

  defp classify(dest) when is_atom(dest) do
    # Plain lowercase atoms (e.g. :main) are registered names — runtime only.
    name = Atom.to_string(dest)

    if String.match?(name, ~r/^[a-z]/) do
      # registered name atom — skip
      {true, true}
    else
      # Uppercase module atom — check if loadable
      case Code.ensure_loaded(dest) do
        {:module, _} -> {true, false}
        _ -> {false, false}
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp skipped_note([]), do: ""
  defp skipped_note(skipped), do: " (#{length(skipped)} dynamic/named skipped) "

  defp return(has_errors, strict) do
    if has_errors and strict, do: exit({:shutdown, 1})
  end
end
