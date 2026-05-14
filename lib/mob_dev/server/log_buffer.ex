defmodule MobDev.Server.LogBuffer do
  @moduledoc """
  Holds the last 500 log lines in memory so the LiveView can restore them on
  reconnect without losing context from before a crash or page refresh.
  """
  use MobDev.Server.RingLog, limit: 500
end
