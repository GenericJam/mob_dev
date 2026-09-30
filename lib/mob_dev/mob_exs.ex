defmodule MobDev.MobExs do
  @moduledoc """
  Text edits to a project's committed `mob.exs` and its gitignored
  `mob.local.exs` override file.

  `mob.exs` holds project config (plugin activation, plugin trust, styles)
  and is committed; a clone without it activates no plugins. Machine paths
  (a local `mob_dir` checkout) go in `mob.local.exs`, which the last
  statement of `mob.exs` imports when present — so local values win.

  Config deep-merges keyword lists but replaces every other value (maps,
  plain lists), so a stanza written *after* that import would silently beat
  the local override. Writers that add a stanza to `mob.exs` go through
  `insert_config/2`, which places it above the import.

  The import is found by walking the parsed file, not by matching text:
  `import_config "mob.local.exs"` with or without parens, bare or under an
  `if` (one line or `do`/`end`), all count. Importing the same file twice
  makes `Config.Reader` raise, so a missed variant is not harmless.

  See `decisions/2026-09-30-mob-local-exs-overrides.md`.
  """

  @local_file "mob.local.exs"
  @local_import ~s|if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")|
  @gitignore_entry "# Mob machine-local config overrides (mob.exs itself is project config — commit it)\nmob.local.exs\n"

  @doc "The conditional import line that ends a generated `mob.exs`."
  @spec local_import() :: String.t()
  def local_import, do: @local_import

  @doc """
  Adds `stanza` (one or more lines of config) to `mob.exs` content: directly
  above the top-level statement that imports `mob.local.exs` when there is
  one, otherwise at the end.
  """
  @spec insert_config(String.t(), String.t()) :: String.t()
  def insert_config(content, stanza) do
    case local_import_line(content) do
      nil ->
        append(content, stanza)

      line ->
        {head, tail} = content |> String.split("\n") |> Enum.split(line - 1)
        Enum.join(head ++ [stanza, ""] ++ tail, "\n")
    end
  end

  @doc """
  Appends the `mob.local.exs` import to `mob.exs` content unless it already
  imports that file.
  """
  @spec ensure_local_import(String.t()) :: String.t()
  def ensure_local_import(content) do
    if local_import_line(content), do: content, else: append(content, @local_import)
  end

  @doc """
  Adds a `mob.local.exs` entry to `.gitignore` content unless one is there.
  Other entries — including an old `mob.exs` line — are left alone.
  """
  @spec ensure_gitignored(String.t()) :: String.t()
  def ensure_gitignored(content) do
    ignored? =
      content
      |> String.split("\n")
      |> Enum.any?(&(String.trim(&1) in [@local_file, "/" <> @local_file]))

    cond do
      ignored? -> content
      content == "" -> @gitignore_entry
      String.ends_with?(content, "\n") -> content <> "\n" <> @gitignore_entry
      true -> content <> "\n\n" <> @gitignore_entry
    end
  end

  @doc """
  Full content for a new `mob.local.exs` setting `mob_dev_config` under
  `config :mob_dev`. Same header `mob.new --local` writes.
  """
  @spec local_content(keyword()) :: String.t()
  def local_content(mob_dev_config) do
    """
    # mob.local.exs — machine-specific Mob overrides. Gitignored; imported at
    # the end of mob.exs when present, so values here win.
    import Config

    #{mob_dev_stanza(mob_dev_config)}
    """
  end

  @doc """
  Writes `mob_dev_config` to `project_dir/mob.local.exs`, makes sure
  `mob.exs` imports it, and makes sure `.gitignore` ignores it.

  An existing `mob.local.exs` keeps everything it has: the new values are
  appended as a later `config :mob_dev` call, which wins over earlier ones
  for the same keys. `mob.exs` only gains the import line (or is created
  holding just that when absent).
  """
  @spec put_local_config(Path.t(), keyword()) :: :ok
  def put_local_config(project_dir, mob_dev_config) do
    update_file(Path.join(project_dir, @local_file), local_content(mob_dev_config), fn existing ->
      append(existing, mob_dev_stanza(mob_dev_config))
    end)

    update_file(
      Path.join(project_dir, "mob.exs"),
      ensure_local_import("import Config\n"),
      &ensure_local_import/1
    )

    update_file(Path.join(project_dir, ".gitignore"), ensure_gitignored(""), &ensure_gitignored/1)
  end

  defp update_file(path, new_content, update) do
    content =
      case File.read(path) do
        {:ok, existing} -> update.(existing)
        {:error, :enoent} -> new_content
      end

    File.write!(path, content)
  end

  # 1-based line of the top-level statement that imports mob.local.exs.
  defp local_import_line(content) do
    case Code.string_to_quoted(content) do
      {:ok, {:__block__, _, statements}} -> Enum.find_value(statements, &import_statement_line/1)
      {:ok, statement} -> import_statement_line(statement)
      {:error, _} -> nil
    end
  end

  defp import_statement_line({_, meta, _} = statement) do
    {_, imports?} =
      Macro.prewalk(statement, false, fn
        {:import_config, _, [file]} = node, _acc when file in [@local_file, ~c"mob.local.exs"] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    if imports?, do: meta[:line]
  end

  defp import_statement_line(_literal), do: nil

  defp mob_dev_stanza(mob_dev_config) do
    "config :mob_dev, " <>
      Enum.map_join(mob_dev_config, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp append(content, stanza) do
    case String.trim_trailing(content) do
      "" -> stanza <> "\n"
      body -> body <> "\n\n" <> stanza <> "\n"
    end
  end
end
