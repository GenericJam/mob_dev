defmodule MobDev.Bench.Logger do
  @moduledoc """
  Append-only CSV log of bench probe snapshots.

  Format:

      ts_ms,elapsed_sec,reachability,app_process,usb,screen,battery_pct,reason

  Reading:
  - `ts_ms` is monotonic — safe to subtract for intervals
  - `elapsed_sec` is seconds since the run started (set on `open/2`)
  - `reachability`, `app_process`, `usb`, `screen` are atoms (string-encoded)
  - `battery_pct` is integer or empty
  - `reason` is a string (CSV-escaped)

  Use `summary/1` after a run to compute % success, gap distribution,
  reconnect count, etc.
  """

  alias MobDev.Bench.Probe

  defstruct [:path, :file, :start_ts_ms, :rows]

  @type t :: %__MODULE__{
          path: Path.t(),
          file: File.io_device() | nil,
          start_ts_ms: integer(),
          rows: non_neg_integer()
        }

  @header "ts_ms,elapsed_sec,reachability,app_process,usb,screen,battery_pct,reason\n"

  @doc """
  Open a log file for writing. Creates parent dirs as needed.

  Returns a struct that's passed to subsequent `append/2` and `close/1` calls.
  """
  @spec open(Path.t(), keyword()) :: t()
  def open(path, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    file = File.open!(path, [:write, :utf8])
    IO.write(file, @header)

    %__MODULE__{
      path: path,
      file: file,
      start_ts_ms: Keyword.get(opts, :start_ts_ms, System.monotonic_time(:millisecond)),
      rows: 0
    }
  end

  @doc """
  Append a probe snapshot. Returns the updated logger struct.
  """
  @spec append(t(), Probe.t()) :: t()
  def append(%__MODULE__{file: file} = log, %Probe{} = probe) when is_pid(file) do
    elapsed_sec =
      Float.round((probe.ts_ms - log.start_ts_ms) / 1000.0, 2)

    line =
      [
        Integer.to_string(probe.ts_ms),
        :erlang.float_to_binary(elapsed_sec, decimals: 2),
        Atom.to_string(probe.reachability),
        Atom.to_string(probe.app_process),
        Atom.to_string(probe.usb),
        Atom.to_string(probe.screen),
        if(probe.battery_pct, do: Integer.to_string(probe.battery_pct), else: ""),
        csv_escape(probe.reason)
      ]
      |> Enum.join(",")

    IO.write(file, line <> "\n")

    %{log | rows: log.rows + 1}
  end

  @doc """
  Close the log file. Idempotent.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{file: nil} = log), do: log

  def close(%__MODULE__{file: file} = log) when is_pid(file) do
    File.close(file)
    %{log | file: nil}
  end

  @doc """
  Read a CSV file and return a list of probe-like maps. Useful for tests
  and for `summary/1`.

  Each row is `%{ts_ms, elapsed_sec, reachability, app_process, usb,
  screen, battery_pct, reason}` with atoms restored.
  """
  @spec read(Path.t()) :: [map()]
  def read(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    [ts_ms, elapsed_sec, reach, app, usb, screen, battery, reason] =
      split_csv(line, 8)

    %{
      ts_ms: String.to_integer(ts_ms),
      elapsed_sec: String.to_float(elapsed_sec),
      reachability: String.to_atom(reach),
      app_process: String.to_atom(app),
      usb: String.to_atom(usb),
      screen: String.to_atom(screen),
      battery_pct: if(battery == "", do: nil, else: String.to_integer(battery)),
      reason: csv_unescape(reason)
    }
  end

  # ── CSV helpers ──────────────────────────────────────────────────────────
  #
  # Strategy: sanitize reasons on write (replace newlines / commas /
  # double-quotes with escape sequences) so each row is exactly one line
  # with comma-separated fields. Avoids the complexity of a full CSV
  # state-machine parser for a log format that's only consumed by us.
  #
  # Encoding for `reason`:
  #   newline  → \n   (literal two chars)
  #   tab      → \t
  #   comma    → \,
  #   backslash → \\
  # Other fields are atoms / integers — never need escaping.

  defp csv_escape(nil), do: ""

  defp csv_escape(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp csv_unescape(""), do: nil

  defp csv_unescape(str) when is_binary(str) do
    unescape(str, [])
  end

  # Walks the string character by character, recognising backslash-escapes.
  defp unescape("", acc), do: acc |> Enum.reverse() |> List.to_string()
  defp unescape("\\\\" <> rest, acc), do: unescape(rest, [?\\ | acc])
  defp unescape("\\n" <> rest, acc), do: unescape(rest, [?\n | acc])
  defp unescape("\\r" <> rest, acc), do: unescape(rest, [?\r | acc])
  defp unescape("\\t" <> rest, acc), do: unescape(rest, [?\t | acc])
  defp unescape("\\," <> rest, acc), do: unescape(rest, [?, | acc])
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, [c | acc])

  defp split_csv(line, fields) when is_binary(line) and is_integer(fields) do
    do_split(line, fields, [], [])
  end

  defp do_split("", _fields, current, acc) do
    final = current |> Enum.reverse() |> List.to_string()
    Enum.reverse([final | acc])
  end

  defp do_split("\\" <> <<c, rest::binary>>, fields, current, acc) do
    # Preserve escape — the unescape pass restores it later.
    do_split(rest, fields, [c, ?\\ | current], acc)
  end

  defp do_split("," <> rest, fields, current, acc) do
    field = current |> Enum.reverse() |> List.to_string()
    do_split(rest, fields, [], [field | acc])
  end

  defp do_split(<<c, rest::binary>>, fields, current, acc) do
    do_split(rest, fields, [c | current], acc)
  end
end
