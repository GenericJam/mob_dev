# Development distribution uses one private managed cookie per app

- Date: 2026-09-30
- Status: accepted
- Issue: MOB-49. Runtime side: `mob/decisions/2026-09-30-private-dist-cookie-and-loopback-listeners.md`

## Context

Development nodes on every platform, and the Mac-side `mob_dev` node, used the
repository-known cookie `mob_secret`. Anyone who could reach a dist port could
run arbitrary RPC on the phone, and the Mac node accepts the same cookie for
unknown peers, so on the developer's Mac too.

A first cut (unmerged, 2026-09-13) moved only iOS to a private cookie and kept
`mob_secret` for Android on the grounds that its node is "only reachable
through adb loopback tunnels". That was wrong: OTP's default listener binds
every interface, and `elixir --cookie mob_secret` reached an Android node.

Generating a new cookie per `mob.connect` run would break the multi-session
workflow: a second session restarts the app under a new cookie and disconnects
the first.

## Decision

`mob_dev` keeps one random 256-bit cookie per app (keyed by `bundle_id`) in
`~/.mob/dist_cookies/`: directory `0700`, file `0600`, file name a SHA-256 of
the bundle id. iOS, Android and the Mac-side node all use it.

- **Delivery.** iOS launches get it in the child environment
  (`SIMCTL_CHILD_MOB_DIST_COOKIE`, `DEVICECTL_CHILD_MOB_DIST_COOKIE`). Android
  gets it as `files/otp/<app>/mob_dist_cookie`, written with `run-as` by every
  deploy (filesystem or dist path) and before every `mob.connect` restart. The
  value goes to adb on stdin, not in an argument, so `ps` on the Mac never
  shows it. A hand-started node loads it inside the VM
  (`Node.set_cookie(MobDev.DistCookie.for_project!())`); there is deliberately
  no command that prints it, since the obvious use, `--cookie "$(...)"`, would
  put it in the arguments of a long-lived process.
- **Migration restarts.** `mob.deploy` hot-loads by default, but `Mob.Dist`
  reads its cookie and binds its listener only at start, so a node that
  accepted the legacy cookie is sent down the filesystem path, which writes
  the private cookie and restarts it (`Deployer.hot_load_nodes/1`). A physical
  iPhone stays on the hot-load path; only `--native` changes its launcher.
- **Legacy fallback.** Without `--cookie`, `MobDev.DistCookie.connect/2` tries
  the private cookie, then `mob_secret`, and warns when the second one works:
  that app was built against a mob from before MOB-49 and stays reachable
  until it is redeployed. When neither works, the node's cookie is reset to
  the private one, because a per-node cookie also authenticates *incoming*
  connections claiming that name. An explicit `--cookie` is tried alone.
- **Mac default cookie** is the private cookie (or the explicit one), never
  `mob_secret`, so a LAN peer claiming an unknown name is refused.

## Consequences

- Concurrent sessions reuse one cookie and attach under distinct node names.
- Deleting the cookie file invalidates running sessions; the next
  deploy/connect creates a new one and hands it over.
- An iOS app launched from Xcode or the home screen has an ephemeral random
  cookie until `mob.connect` restarts it. An Android launcher start reads the
  file, so it stays attachable. (Amended by MOB-348: iOS filesystem deploys
  now also write `mob_dist_cookie` into the beams dir, the simulator runtime
  dir or the physical iPhone's `Documents/otp/<app>/`, and mob ≥ the matching
  release reads it, so iOS relaunches stay attachable too.)
- While a legacy app is connected, its node name carries `mob_secret` as a
  per-node cookie on the Mac. That is the old exposure, limited to that name,
  and the warning tells the developer how to end it.
