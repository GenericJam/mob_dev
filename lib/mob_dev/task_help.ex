defmodule MobDev.TaskHelp do
  @moduledoc """
  Helpers for `--help` / `-h` handling in mob_dev Mix tasks.

  Mix has `mix help <task>` built in (reads the task module's
  `@moduledoc`), but users from outside the Elixir ecosystem expect
  `<command> --help` to work too. This module gives each task a
  one-line opt-in:

      def run(args) do
        if MobDev.TaskHelp.help_requested?(args) do
          MobDev.TaskHelp.print_module_help(__MODULE__)
        else
          # normal flow…
        end
      end

  Public API is intentionally tiny — two predicates and a printer —
  so a future change to where `@moduledoc` is stored (or how it gets
  rendered) only ripples through one file.
  """

  @doc """
  True when `argv` contains `--help` or `-h` as a standalone arg.

      iex> MobDev.TaskHelp.help_requested?(["--help"])
      true

      iex> MobDev.TaskHelp.help_requested?(["-h"])
      true

      iex> MobDev.TaskHelp.help_requested?(["--device", "foo"])
      false

      iex> MobDev.TaskHelp.help_requested?([])
      false
  """
  @spec help_requested?([String.t()]) :: boolean()
  def help_requested?(argv) when is_list(argv) do
    "--help" in argv or "-h" in argv
  end

  @doc """
  Prints `task_module`'s `@moduledoc` to stdout.

  Falls back to a small "no docs available" message if the module
  has no `@moduledoc` (which shouldn't happen for any mob_dev task
  but the fallback keeps `print_module_help/1` total).
  """
  @spec print_module_help(module()) :: :ok
  def print_module_help(task_module) when is_atom(task_module) do
    case Code.fetch_docs(task_module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        IO.puts(doc)

      _ ->
        IO.puts("(no documentation found for #{inspect(task_module)} — `mix help` may have more)")
    end

    :ok
  end
end
