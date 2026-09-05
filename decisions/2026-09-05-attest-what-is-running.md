# Deployment attestation compares module digests, not artifacts

- Date: 2026-09-05
- Status: accepted

## Context

`mix mob.deploy` reports what it did. It does not report what is now true, and
the two come apart more often than the exit code suggests.

Two instances from one session. A bundle-id divergence sent the BEAM push into
one app's container while a different app was running: it did not fail with
"not installed", it succeeded and printed a tick, because both containers
existed on the device. And a plain dist deploy reported success while twelve
`mob` modules on the device kept their old digests (MOB-161).

In both cases every individual step was honest about itself and the run as a
whole was wrong. Every guide in these repos says "verify effects, not exit
codes" — an instruction that exists precisely because the tools cannot be
trusted, and that only works while someone remembers to follow it.

## Decision

Compare `module_info(:md5)` on the device against `:beam_lib.md5/1` of the
local `.beam`. They are the same digest for the same bytes, so a module that
never arrived, arrived in the wrong place, or arrived and was never loaded all
show up, and no new machinery has to be invented to produce a fingerprint.

Deliberately not hashing artifacts, directories or the IPA/APK. Two builds of
the same source differ in timestamps and paths, so an artifact hash reports a
mismatch on every rebuild; a check that cries wolf gets switched off, and a
switched-off check is worth less than none because its absence is invisible.

Four verdicts rather than two:

* `:stale` is fatal. The device is running code we did not build.
* `:unreadable` is fatal. The check could not run, and a check that could not
  run must not report success — the same rule as a deploy exiting 0 having
  shipped nothing.
* `:missing` is reported and is **not** fatal. Interactive BEAM loads a module
  when something first calls it, so most of a bundle is legitimately unloaded
  at any moment. Failing on that would make the tool unusable within a day.
* `:match` is the only pass.

Attestation connects without restarting. `Connector.connect_all/1` restarts the
app, which reloads every module and would destroy the evidence being read. The
tunnels a previous `mix mob.connect` set up are device-level and outlive it, so
a plain `Node.connect/1` is enough.

A run that reaches no device raises rather than reporting success, for the same
reason `:unreadable` is fatal.

## Consequences

It is a separate task, not a step inside `mob.deploy`. Deploy cannot always
reach the node — a physical iPhone with USB attached suspends its BEAM — and
folding a check that sometimes cannot run into the thing it checks would either
weaken the deploy's exit code or produce false failures. Wiring it in as an
opt-in deploy flag is the obvious follow-up.

It only sees modules the device has loaded, so it cannot distinguish "shipped
but not yet loaded" from "never shipped". `mix mob.snapshot_loaded` answers the
shipped-set question and the two are complementary.

It found MOB-161 on its first real use, which is the argument for building it
and also a caution: the failure it found had been happening silently, and there
is no way to know for how long.
