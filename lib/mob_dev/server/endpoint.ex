defmodule MobDev.Server.Endpoint do
  use Phoenix.Endpoint, otp_app: :mob_dev

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: [store: :cookie, key: "_mob_dev_session", signing_salt: "mob_dev"]]
    ]
  )

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

  plug(Plug.RequestId)

  plug(Plug.Session,
    store: :cookie,
    key: "_mob_dev_session",
    signing_salt: "mob_dev"
  )

  plug(MobDev.Server.Router)
end
