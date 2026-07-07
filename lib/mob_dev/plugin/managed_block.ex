defmodule MobDev.Plugin.ManagedBlock do
  @moduledoc """
  Reversible insertion of plugin-contributed fragments into host-owned build
  files (`AndroidManifest.xml`, `build.gradle`).

  The problem: plugin permissions, AndroidManifest `<application>` components,
  and Gradle dependencies are spliced into files the host also hand-edits. A
  plain "append if absent" merge can't be undone — when a plugin is removed its
  lines linger (a dangling `<service>` whose class is gone, an orphan permission
  / dep). Unlike the copied artifacts (`bridge_kt`, `res_files`) there's no
  ledger to prune, because the target file is shared and hand-authored.

  The fix: fence each managed region with begin/end marker comments and
  **regenerate the whole region every build** from the current plugin set. A
  removed plugin simply isn't in the fresh region, so its lines disappear;
  anything the host wrote outside the fence is never touched. Re-running with an
  unchanged plugin set is idempotent.

  `upsert/4` is pure: `(content, markers, body, place) -> content'`. `markers`
  is `{begin_line, end_line}` (the exact comment lines, comment syntax chosen by
  the caller so it works for both XML and Gradle). `place` is
  `(stripped_content, region) -> content'` — it inserts the freshly built region
  at the file-specific anchor (using `insert_before/3` or `insert_before_index/3`
  so the region occupies whole lines and `strip/2` reverses it exactly). An
  empty `body` removes the region entirely.

  Idempotence rests on `insert_before*` placing the region as complete lines at
  a line boundary and `strip/2` removing exactly those lines — so
  `strip(place(x)) == x`, and re-running with an unchanged plugin set is a fixed
  point (verified in the tests).
  """

  @type markers :: {String.t(), String.t()}

  @doc """
  Replace (or remove) the managed region delimited by `markers` in `content`.

  Strips any existing region first (so the build is the single source of truth
  for it), then — if `body` is non-empty — rebuilds it as
  `begin <> "\\n" <> body <> "\\n" <> end` and hands it to `place` to insert.
  An empty `body` leaves the content with the region stripped (the removal case).
  """
  @spec upsert(String.t(), markers(), String.t(), (String.t(), String.t() -> String.t())) ::
          String.t()
  def upsert(content, {begin_line, end_line} = markers, body, place)
      when is_binary(content) and is_binary(body) and is_function(place, 2) do
    stripped = strip(content, markers)

    if String.trim(body) == "" do
      stripped
    else
      region = begin_line <> "\n" <> body <> "\n" <> end_line
      place.(stripped, region)
    end
  end

  @doc """
  Remove every managed region delimited by `markers` (the full lines the begin
  and end markers sit on, inclusive), or return `content` unchanged when no
  well-formed region is present.

  Each region is identified as **the last BEGIN before the first END**, never
  "first BEGIN → first END". That distinction matters: with a stray/duplicate
  BEGIN (an interrupted write, a hand-edit, a bad merge-conflict resolution),
  "first BEGIN → first END" would delete everything from the orphan through the
  real region's END — silently eating host-authored lines in between. Anchoring
  on the last BEGIN before the first END guarantees the removed span contains no
  other marker, so only the region itself is deleted. Loops until no well-formed
  region remains, so duplicates are all cleared.
  """
  @spec strip(String.t(), markers()) :: String.t()
  def strip(content, markers) when is_binary(content) do
    case strip_one(content, markers) do
      ^content -> content
      shorter -> strip(shorter, markers)
    end
  end

  defp strip_one(content, {begin_line, end_line}) do
    with {es, el} <- match(content, end_line),
         {bs, _} <- last_match_before(content, begin_line, es) do
      region_start = line_start(content, bs)
      region_stop = line_stop(content, es + el)

      binary_part(content, 0, region_start) <>
        binary_part(content, region_stop, byte_size(content) - region_stop)
    else
      _ -> content
    end
  end

  @doc """
  Insert `region` as whole lines immediately before the line containing the
  first occurrence of `anchor` (returns `content` unchanged if `anchor` is
  absent). Pairs with `strip/2` for an exact round-trip.
  """
  @spec insert_before(String.t(), String.t(), String.t()) :: String.t()
  def insert_before(content, anchor, region) when is_binary(content) and is_binary(anchor) do
    case match(content, anchor) do
      {pos, _} -> insert_before_index(content, pos, region)
      nil -> content
    end
  end

  @doc """
  Insert `region` as whole lines immediately before the line containing byte
  index `idx`.
  """
  @spec insert_before_index(String.t(), non_neg_integer(), String.t()) :: String.t()
  def insert_before_index(content, idx, region) when is_binary(content) and is_integer(idx) do
    ls = line_start(content, idx)

    binary_part(content, 0, ls) <>
      region <> "\n" <> binary_part(content, ls, byte_size(content) - ls)
  end

  # First occurrence of `needle` (or :nomatch as a with-friendly falsy).
  defp match(hay, needle) do
    case :binary.match(hay, needle) do
      {s, l} -> {s, l}
      :nomatch -> nil
    end
  end

  # Last occurrence of `needle` strictly before byte index `limit` (nil if none).
  defp last_match_before(hay, needle, limit) do
    case :binary.matches(binary_part(hay, 0, limit), needle) do
      [] -> nil
      list -> List.last(list)
    end
  end

  # Index of the start of the line containing `pos` (char after the previous \n).
  defp line_start(content, pos) do
    case :binary.matches(binary_part(content, 0, pos), "\n") do
      [] -> 0
      list -> (List.last(list) |> elem(0)) + 1
    end
  end

  # Index just past the newline that ends the line containing `pos` (or EOF).
  defp line_stop(content, pos) do
    rest = binary_part(content, pos, byte_size(content) - pos)

    case :binary.match(rest, "\n") do
      {s, l} -> pos + s + l
      :nomatch -> byte_size(content)
    end
  end
end
