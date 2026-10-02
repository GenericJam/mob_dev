defmodule MobDev.MobNifTable do
  @moduledoc """
  The `-nifs` difference between two mob checkouts' `src/mob_nif.erl`.

  `MobDev.MobDirCheck` stops a native build whose `mob_dir` isn't the `:mob`
  dependency. When the two checkouts also list different NIFs, the outcome is
  not subtle misbehaviour but a boot crash: `erlang:load_nif/2` rejects the
  library, `mob_nif`'s `on_load` fails, and the bootstrap's first call dies
  with `undef mob_nif:log/1` (MOB-227). This module names that difference so
  the mismatch error can say so.
  """

  @src "src/mob_nif.erl"

  @type diff :: %{only_in_mob_dir: [String.t()], only_in_dep: [String.t()]}

  @doc """
  NIFs listed by only one of `mob_dir` and `dep_path`, or `nil` when the
  tables agree or either `mob_nif.erl` can't be read.
  """
  @spec diff(Path.t(), Path.t()) :: diff() | nil
  def diff(mob_dir, dep_path) do
    with {:ok, ours} <- read_nifs(Path.join(mob_dir, @src)),
         {:ok, theirs} <- read_nifs(Path.join(dep_path, @src)),
         false <- MapSet.equal?(ours, theirs) do
      %{
        only_in_mob_dir: MapSet.difference(ours, theirs) |> Enum.sort(),
        only_in_dep: MapSet.difference(theirs, ours) |> Enum.sort()
      }
    else
      _ -> nil
    end
  end

  @doc "What the difference means, for appending to the mismatch error; `\"\"` for `nil`."
  @spec describe(diff() | nil) :: String.t()
  def describe(nil), do: ""

  def describe(diff) do
    lines =
      [
        {"only in mob_dir:         ", diff.only_in_mob_dir},
        {"only in :mob dependency: ", diff.only_in_dep}
      ]
      |> Enum.reject(fn {_, nifs} -> nifs == [] end)
      |> Enum.map_join("", fn {label, nifs} -> "\n    #{label}#{Enum.join(nifs, ", ")}" end)

    "Their mob_nif.erl NIF tables differ, so load_nif would reject the native " <>
      "library and the app would crash at boot with `undef mob_nif:log/1`:" <> lines
  end

  @doc false
  # Every `name/arity` in the file's `-nifs([...])` attributes.
  @spec read_nifs(Path.t()) :: {:ok, MapSet.t(String.t())} | :error
  def read_nifs(path) do
    case File.read(path) do
      {:ok, src} -> {:ok, parse_nifs(src)}
      {:error, _} -> :error
    end
  end

  @doc false
  @spec parse_nifs(String.t()) :: MapSet.t(String.t())
  def parse_nifs(src) do
    no_comments = Regex.replace(Regex.compile!("%[^\\n]*"), src, "")
    attr = Regex.compile!("^-nifs\\(\\s*\\[(.*?)\\]\\s*\\)\\s*\\.", "ms")
    entry = Regex.compile!("([a-z][A-Za-z0-9_@]*|'[^']+')\\s*/\\s*(\\d+)")

    for [_, body] <- Regex.scan(attr, no_comments),
        [_, name, arity] <- Regex.scan(entry, body),
        into: MapSet.new(),
        do: "#{name}/#{arity}"
  end
end
