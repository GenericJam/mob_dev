defmodule MobDev.Server.ElixirLogger do
  @moduledoc """
  OTP logger handler that captures Elixir `Logger` output and forwards it
  to the Mob dev server dashboard.

  Attached by `mix mob.server` after the supervision tree starts, so
  `ElixirLogBuffer` and PubSub are guaranteed to be running.

  Only captures events with `domain: [:elixir]` — the domain Elixir's Logger
  uses for all `Logger.info/debug/warning/error` calls. Raw `:logger` calls
  and OTP system messages are excluded.
  """

  @handler_id :mob_dev_elixir_logger
  @topic "elixir_logs"

  @doc "Attach the handler to OTP's logger. Call after the server supervisor starts."
  def attach do
    :logger.add_handler(@handler_id, __MODULE__, %{})
  end

  @doc "Detach the handler."
  def detach do
    :logger.remove_handler(@handler_id)
  end

  # ── OTP logger callbacks ──────────────────────────────────────────────────

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok

  def log(%{level: level, msg: msg, meta: meta} = _event, _config) do
    # Only capture Elixir Logger events (domain: [:elixir])
    if elixir_domain?(meta) do
      line = %{
        id: System.unique_integer([:positive, :monotonic]),
        level: level_char(level),
        message: format_msg(msg),
        ts: format_time(meta[:time]),
        module: meta[:module]
      }

      # Guard: if the buffer GenServer isn't up, skip silently
      if Process.whereis(MobDev.Server.ElixirLogBuffer) do
        MobDev.Server.ElixirLogBuffer.push(line)
      end

      if Process.whereis(MobDev.PubSub) do
        Phoenix.PubSub.broadcast(MobDev.PubSub, @topic, {:elixir_log_line, line})
      end
    end

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp elixir_domain?(%{domain: [:elixir | _]}), do: true
  defp elixir_domain?(_), do: false

  defp level_char(:emergency), do: "E"
  defp level_char(:alert), do: "E"
  defp level_char(:critical), do: "E"
  defp level_char(:error), do: "E"
  defp level_char(:warning), do: "W"
  defp level_char(:notice), do: "I"
  defp level_char(:info), do: "I"
  defp level_char(:debug), do: "D"
  defp level_char(_), do: "D"

  defp format_msg({:string, text}), do: IO.iodata_to_binary(text)
  defp format_msg({:report, map}), do: inspect(map, pretty: false, limit: 50)

  defp format_msg({:format, fmt, args}) do
    :io_lib.format(fmt, args) |> IO.iodata_to_binary()
  rescue
    _ -> inspect({fmt, args})
  end

  defp format_msg(other), do: inspect(other)

  defp format_time(nil), do: ""

  defp format_time(microseconds) do
    ms = div(microseconds, 1_000)
    dt = DateTime.from_unix!(ms, :millisecond)
    frac = String.pad_leading("#{rem(ms, 1000)}", 3, "0")
    Calendar.strftime(dt, "%H:%M:%S.") <> frac
  end
end
