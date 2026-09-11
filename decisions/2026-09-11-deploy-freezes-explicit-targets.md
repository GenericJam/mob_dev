# mob.deploy freezes explicit targets before doing work

Date: 2026-09-11
Status: accepted
Ticket: MOB-169

## Context

`mix mob.deploy --native` discovered devices independently during compatibility
checks, native installation, and the final BEAM push. A bare run therefore
installed on every Android device returned by `adb devices` and tried every
connected iPhone. It also ignored `ANDROID_SERIAL`. The set could change during
a long native build, so even checking the initial output did not define which
devices the command would later modify.

Physical phones may contain personal data and are often attached for unrelated
work. A command that changes them needs a deliberate target choice. Emulators
and simulators are safer development defaults, but selecting several of them
implicitly is still ambiguous.

## Decision

The deploy task discovers once and resolves one immutable list before compile,
build, install, or push begins. Every later stage consumes that list.

The shared `MobDev.TaskTargets` policy is:

- `--device <id>` selects one named device, including a physical device.
- `--all-devices` selects every emulator and simulator.
- `--all-physical` selects every physical device.
- Combining the broad flags selects every connected device.
- With no flag, exactly one emulator or simulator is selected automatically.
  Physical devices are never implicit, and multiple development devices are an
  error.

For Android, a non-empty `ANDROID_SERIAL` is a named target when no CLI target
scope was supplied. Explicit CLI selection takes precedence.

Native artifact-only builds remain valid with no connected device. An empty
frozen list means install and push nothing; it never means rediscover and fan
out.

## Consequences

- Users with several emulators or simulators must choose one or pass
  `--all-devices`.
- Users deploying to a phone must name it or pass `--all-physical`.
- Android install and OTP delivery intersect later `adb devices` output with
  the frozen serials. Newly connected devices cannot join, and a selected
  device disappearing stops the native delivery instead of widening scope.
- An iOS simulator build is shared across selected simulators and installed
  only on their frozen UDIDs. Physical iOS builds remain per-device because
  signing and installation are device-specific.
- `MobDev.Uninstaller` delegates to the same selector so the two device-changing
  tasks cannot drift independently.
