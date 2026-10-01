defmodule Mix.Tasks.Mob.Cookie do
  use Mix.Task

  @shortdoc "Print this app's private distribution cookie"

  @moduledoc """
  Prints the private distribution cookie of the app in the current directory,
  creating it on first use, for attaching by hand:

      elixir --name probe@127.0.0.1 --cookie "$(mix mob.cookie)" -e '...'
      iex --name me@127.0.0.1 --cookie "$(mix mob.cookie)" -S mix

  The cookie is a random 256-bit value per app, kept owner-only under
  `~/.mob/dist_cookies/`. `mix mob.deploy` and `mix mob.connect` hand it to
  the app; anyone holding it can run code in the app and, through the
  connection, on this Mac, so treat the output as a secret. Nothing else is
  written to stdout.
  """

  @impl Mix.Task
  def run(_args) do
    IO.puts(MobDev.DistCookie.for_project!())
  end
end
