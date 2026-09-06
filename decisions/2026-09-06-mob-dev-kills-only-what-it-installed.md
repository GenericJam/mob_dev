# mob_dev kills only the apps mob_dev installed

Date: 2026-09-06
Status: accepted
Ticket: MOB-70

## Context

Launching a Mob app on a physical iPhone first cleared other apps off the
device. The reason is real: each physical-device Mob app starts an in-process
EPMD bound to `0.0.0.0:4369` (`mob/ios/mob_beam.m`), so only one can run at a
time — a second gets `EADDRINUSE` and never boots.

The implementation decided what to clear by pattern-matching the running
process list for `Bundle/Application/`, and terminated each match with
`devicectl ... --kill`. Every third-party iOS app runs from that path. So
plugging in a personal iPhone and running `mix mob.connect` force-quit every
app its owner had open, losing whatever in-memory state they held. The
`except_bundle` parameter that was supposed to spare the target app was
discarded outright (`_ = except_bundle`), and the function's own doc claimed it
was honoured.

Measured on the iPhone attached while writing this: the old code would have
killed **15** user apps, TestFlight among them.

Anchoring the match to `Bundle/Application/` removes 24 system processes from
consideration, but that is tidiness, not safety: Apple's `MobileCal.app` runs
from `Bundle/Application/` too, and app names come from
`Macro.camelize(project)`, so a project named `mobile_cal` collides exactly.
**The registry is the safety property.** The anchor only narrows what the
registry then has to be right about.

## Decision

**mob_dev may kill an app on an attached device only if mob_dev installed it
there.** A device is someone's phone; nothing else on it is ours to touch.

`MobDev.IOSInstalls` records `{udid → [{bundle_id, app_name}]}` at install
time. `kill_other_user_apps_physical/2` asks it what belongs to us, excludes
the app about to be launched, and kills only what remains. The decision itself
is a pure function, `IOS.mob_pids_to_kill/3`, so the thing that was previously
untestable is now the tested part.

**Not knowing is a reason to do nothing.** An absent, empty or corrupt registry
returns `[]`, and `[]` means kill nothing. The alternative — treating "I have
no record" as licence to clear the device — is the bug this replaces.

Matching is on the `.app` bundle name, whole, because the process listing
carries no bundle ids. `"Demo"` therefore does not match `"DemoOne.app"`; a
short recorded name must not widen the blast radius to everything sharing its
prefix.

## Consequences

- A Mob app installed by some other route — Xcode, TestFlight, a colleague's
  build — is no longer cleared, and will still hold EPMD 4369. The launch then
  fails as it would have before mob_dev ever cleared anything. Losing an
  automatic recovery is the correct trade against force-quitting a stranger's
  banking app, but the failure is silent in a nasty way: `devicectl launch`
  reports success, because it is the BEAM *inside* the app that dies. So an
  empty record prints a warning naming EPMD 4369 as the likely cause. Left
  unexplained, this would be a worse failure than the one being fixed.
- The target app is no longer `--kill`ed before launch, only
  `--terminate-existing`ed by the launch itself. Killing it separately raced
  the launch that immediately followed.
- Matching is by app name, so the record has to be forgotten on uninstall
  (`IOSInstalls.forget/2`). A stale entry is not inert: it stays killable, and
  a third-party app that later takes that name inherits it — the original bug
  in miniature.
- The registry is a cache, not a source of truth. Deleting it costs a stale Mob
  app surviving a launch; it never costs correctness. Losing a write never
  fails the install that is happening.
- The general rule this is an instance of: **a tool operating on someone's
  device kills what it created and nothing else.** The same reasoning already
  applies to this project's own agents, who are told never to `pkill -f` or
  `killall` and to kill only PIDs they spawned. mob_dev was doing to users'
  phones precisely what we forbid ourselves to do to our machines.
