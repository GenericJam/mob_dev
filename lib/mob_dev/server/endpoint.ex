defmodule MobDev.Server.Endpoint do
  use Phoenix.Endpoint, otp_app: :mob_dev

  socket("/live", MobDev.Server.LiveSocket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]]
  )

  plug(Plug.RequestId)
  plug(:session)

  # Every route below, static assets included, needs the run's access token.
  plug(MobDev.Server.Auth)

  # Serve phoenix.js and phoenix_live_view.js directly from package priv/static.
  # No npm/esbuild needed — these are pre-built files from the hex packages.
  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/assets/plv",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/",
    from: {:mob_dev, "priv/static"},
    gzip: false
  )

  plug(MobDev.Server.Router)

  @doc """
  Session cookie options. The cookie is signed with the endpoint's
  `secret_key_base`, which `mix mob.server` generates per run. Browsers share
  cookies across ports, so the key carries the port: two dashboards on one
  host would otherwise overwrite each other's cookie.
  """
  @spec session_options() :: keyword()
  def session_options do
    [store: :cookie, key: "_mob_dev_session_#{config(:http)[:port]}", signing_salt: "mob_dev"]
  end

  defp session(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
