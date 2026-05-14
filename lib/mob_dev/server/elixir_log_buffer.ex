defmodule MobDev.Server.ElixirLogBuffer do
  @moduledoc """
  Holds the last 200 server-side Elixir log lines in memory so the dashboard
  can restore them on reconnect. Fed by `MobDev.Server.ElixirLogger`.
  """
  use MobDev.Server.RingLog, limit: 200
end
