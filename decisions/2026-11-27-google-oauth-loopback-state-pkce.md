# Google OAuth sign-in: loopback listener, state and PKCE
- Date: 2026-11-27
- Status: accepted

## Context

`MobDev.GooglePlay.OAuth.authorize/1` (the Play setup wizard's browser
sign-in) listened for the authorization-code callback on every interface,
sent no `state`, and accepted the first connection it got as the callback
(MOB-555).

## Decision

- The callback listener binds `127.0.0.1` on a port the OS picks, and the
  socket stays open from port selection until the callback arrives. The old
  code probed a free port, closed it and reopened it, which left a gap.
- The redirect URI is `http://127.0.0.1:<port>/callback`, the loopback form
  Google documents for desktop clients. A redirect to `localhost` would let the
  browser try `::1`, where nothing listens.
- Each sign-in sends a random `state` (32 bytes from
  `:crypto.strong_rand_bytes/1`, url-safe base64). A callback is accepted only
  when its `state` matches, compared with `Plug.Crypto.secure_compare/2`.
  Any other request on the port (wrong or missing state, another path) gets
  400 and the listener keeps waiting until the timeout. A stray request
  therefore cannot end the sign-in, and its code is never exchanged.
  A Google `error=` callback ends the sign-in only when its state matches.
  The wait is bounded by the sign-in timeout: each connection gets at most
  the time left (and never more than 10 s) to send its request line, and a
  client that resets before `accept` (`:einval`/`:econnaborted`/
  `:econnreset`) does not end the wait.
- PKCE with S256 (RFC 7636): the auth request carries the challenge, and the
  token request carries the verifier. Google supports PKCE for desktop
  clients, so a code that leaks cannot be redeemed without the verifier.

## Consequences

- `parse_callback_request/2` takes the expected state and can return
  `{:ignore, reason}` besides `{:ok, code}` / `{:error, reason}`.
- `sign_in/6` takes the browser opener and the token exchange as functions,
  so the flow is tested end to end over a real loopback socket without a
  browser or network.
