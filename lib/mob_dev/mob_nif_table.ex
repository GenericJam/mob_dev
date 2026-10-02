defmodule MobDev.MobNifTable do
  @moduledoc """
  Detects "two paths to mob": native code built from `mob_dir` while the app's
  BEAMs come from a different mob (the Hex package in `deps/mob`).

  The native side registers the NIF table compiled from `mob_dir`; the BEAM
  side loads `mob_nif.beam` built from `deps/mob/src/mob_nif.erl`. When their
  `-nifs` lists differ, `erlang:load_nif/2` rejects the library, `mob_nif`'s
  `on_load` fails, the module is never loaded, and the app dies during boot with
  `undef mob_nif:log/1`, which says nothing about the cause.
  """

  @src "src/mob_nif.erl"

  @type mismatch :: %{
          mob_dir: Path.t(),
          deps_mob: Path.t(),
          only_in_mob_dir: [String.t()],
          only_in_deps: [String.t()]
        }

  @doc """
  Compares the `-nifs` table of `mob_dir` with the one in `project_root`'s
  `deps/mob`. `:ok` when they agree, when `mob_dir` *is* `deps/mob`, or when
  either file is missing (a `path:` dep has no `deps/mob`; nothing to compare).
  """
  @spec check(Path.t(), Path.t() | nil) :: :ok | {:mismatch, mismatch()}
  def check(_project_root, nil), do: :ok

  def check(project_root, mob_dir) do
    mob_dir = Path.expand(mob_dir, project_root)
    deps_mob = Path.expand("deps/mob", project_root)

    with false <- same_dir?(mob_dir, deps_mob),
         {:ok, ours} <- read_nifs(Path.join(mob_dir, @src)),
         {:ok, theirs} <- read_nifs(Path.join(deps_mob, @src)),
         false <- ours == theirs do
      {:mismatch,
       %{
         mob_dir: mob_dir,
         deps_mob: deps_mob,
         only_in_mob_dir: MapSet.difference(ours, theirs) |> Enum.sort(),
         only_in_deps: MapSet.difference(theirs, ours) |> Enum.sort()
       }}
    else
      _ -> :ok
    end
  end

  @doc "Human-readable explanation of a mismatch, naming both paths and the fix."
  @spec message(mismatch()) :: String.t()
  def message(m) do
    """
    mob_dir's NIF table differs from the mob your app's BEAMs are built from.
      mob_dir (native code): #{Path.join(m.mob_dir, @src)}
      deps/mob (BEAMs):      #{Path.join(m.deps_mob, @src)}
    #{diff_lines(m)}
    The native library would be rejected by load_nif, mob_nif would fail to load,
    and the app would crash at boot with `undef mob_nif:log/1`.
    Fix: build natives from the same mob as the BEAMs. Either set
      config :mob_dev, mob_dir: Path.join(File.cwd!(), "deps/mob")
    in mob.exs (and remove any mob_dir override in mob.local.exs), or make the app
    depend on the checkout: {:mob, path: "#{m.mob_dir}", override: true}.\
    """
  end

  defp diff_lines(m) do
    [
      {"only in mob_dir:  ", m.only_in_mob_dir},
      {"only in deps/mob: ", m.only_in_deps}
    ]
    |> Enum.reject(fn {_, l} -> l == [] end)
    |> Enum.map_join("\n", fn {label, l} -> "  #{label}#{Enum.join(l, ", ")}" end)
  end

  defp same_dir?(a, b) do
    resolve(a) == resolve(b)
  end

  defp resolve(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} -> Path.expand(to_string(target), Path.dirname(path))
      _ -> path
    end
  end

  @doc false
  # Every `name/arity` listed in the file's `-nifs([...])` attributes.
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
