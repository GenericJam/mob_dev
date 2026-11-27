# Security policy

## Reporting a vulnerability

Email **genericjam@gmail.com** with `[mob_dev security]` in the subject. Please
don't open a public issue, pull request or discussion for a vulnerability.

Include what you can of:

- the mob_dev version (or commit), your OS, and the Mix task or component
  involved;
- what the attacker controls: a plugin package, a downloaded artifact, a device
  or network peer, a file name;
- steps or a proof of concept that reproduce it;
- what it lets the attacker do.

The same address covers the related packages I maintain: `mob`, `mob_new` and
the `mob_*` plugins published from
[github.com/GenericJam](https://github.com/GenericJam). If a problem spans
several of them, send one report and I'll coordinate the fixes.

## What happens next

- I acknowledge reports within 7 days.
- I confirm or rule out the issue, then fix it in a new release on Hex.
- Once the fix is published, I publish a GitHub security advisory that credits
  you, unless you'd rather not be named.
- Please keep the details private until the fix is released, or for 90 days
  after your report, whichever comes first. If a fix needs longer, I'll tell you
  why and we'll agree on a date.

## Supported versions

mob_dev is pre-1.0. Security fixes go into the next release only, and older
versions don't get backports. Upgrade to the latest release on
[Hex](https://hex.pm/packages/mob_dev) to pick up a fix.

## Scope

mob_dev runs on the developer's machine with their permissions. It builds and
signs apps, downloads runtimes, verifies plugins, talks to devices and pushes
code to them.

**In scope:**

- **The plugin signature and trust gate.** It is a vulnerability if the gate
  lets through a tampered or untrusted plugin, or an unsigned one the developer
  didn't list in `config :mob, :acknowledge_unsafe_plugins`. It is also one if a
  task run in a host project evaluates a dependency's plugin manifest before
  verifying its signature, apart from an unsigned plugin the developer
  acknowledged. See mob's
  [`MOB_PLUGIN_SECURITY.md`](https://github.com/GenericJam/mob/blob/master/MOB_PLUGIN_SECURITY.md).
- **Downloaded artifacts,** such as the OTP runtime tarballs: missing or
  bypassable integrity checks, and path or symlink escapes when an archive is
  extracted.
- **Mob's OTP runtime builds:** a bug that the patches or build settings in
  `scripts/release/` introduce into the runtime that ships in apps.
- **The development server, dashboard, hot push, tunnels and device
  discovery:**
  - access without authentication;
  - listeners bound more widely than intended;
  - unsafe handling of data that comes from devices or the network.
- **Distribution cookies:** leaks, weak or public fallbacks, and overly
  permissive file modes.
- **Signing keys and store publishing credentials** exposed through logs,
  generated files or file permissions.
- **Command or path injection,** when the attacker controls the value without
  already controlling the project. Examples are a device name, a discovery
  response and an archive entry.

**Not vulnerabilities on their own:**

- The project's `mix.exs`, build scripts or dependencies running code on your
  machine. Mix trusts them by design. A plugin is a Mix dependency too, so its
  Elixir code runs like any other; the gate's promises above still have to
  hold.
- An authenticated development peer pushing code or running RPC calls. That
  access is the point of the connection.
- A vulnerability that `mix mob.security_scan` finds in *your app's*
  dependencies. Report it to that dependency. If the scan flags the OTP,
  Elixir, OpenSSL or SQLite that Mob bundles, do tell me so Mob can move to a
  fixed version. If the scanner misses a known advisory, that is an ordinary
  bug: open an issue.
- Bugs in Erlang/OTP, Elixir, Android, Xcode or a third-party library. Report
  those upstream, unless Mob's own patches or build settings introduced them
  (see above).
