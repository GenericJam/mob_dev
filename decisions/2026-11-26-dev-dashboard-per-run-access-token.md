# Dev dashboard: per-run access token, LAN bind kept
- Date: 2026-11-26
- Status: accepted

## Context

`mix mob.server` listens on every interface so a phone can open the dashboard
from the printed QR code. The dashboard streams device and Elixir logs and
starts deploys. It had no authentication and a constant `secret_key_base`
(MOB-551).

## Decision

- Each run generates a random access token and a random `secret_key_base`
  (`:crypto.strong_rand_bytes/1`). Nothing is persisted between runs.
- The printed URLs and the QR code carry the token as `?token=...`.
  `MobDev.Server.Auth`, a plug ahead of every route (static assets included),
  compares it in constant time, stores a SHA-256 digest of it in the signed
  session cookie and redirects to `/` without the query string, so the token
  does not stay in the address bar or browser history. Any other request
  without that session gets 401. The session holds the digest rather than the
  token because LiveView's debug log prints the session on mount, and that log
  reaches the dashboard's own Elixir panel.
- The session cookie key carries the port (`_mob_dev_session_<port>`).
  Browsers share cookies across ports on one host, so with a single key two
  dashboards running at once would overwrite each other's cookie and lock
  each other out.
- The LiveView socket is `MobDev.Server.LiveSocket`, whose `connect/3` refuses
  a session without the run's token digest. Phoenix dispatches sockets before
  the endpoint's plugs, so this check, not the plug, guards the websocket.
  Phoenix only loads `connect_info.session` when the connect params carry a
  CSRF token matching the cookie, so a cross-site page cannot ride the
  browser's cookie.
- `check_origin` lists the origins the dashboard is served from:
  `localhost`, `127.0.0.1` and the detected LAN IP, each with the run's port.
  Before, the default compared against `url: [host: "localhost"]`, so the
  phone's LAN origin could not open the socket at all.
- The bind stays `0.0.0.0` by default because the phone flow is the feature.
  `--local` binds `127.0.0.1` and prints no LAN URL.
- Deploy modes from the client are matched against an explicit list
  (`DashboardLive.deploy_mode/1`); client strings never become atoms.

## Consequences

- A token in a URL can leak where URLs leak: terminal scrollback, a
  screenshot of the QR code, shell history if the user pastes it. It is valid
  only for the run that printed it.
- Plain HTTP on the LAN: someone who can sniff the network can still read the
  token and the cookie. TLS for a dev dashboard opened from a phone needs a
  certificate the phone trusts, which is out of scope here.
- Bookmarks of the bare dashboard URL stop working; reopen the printed link
  after each restart.
