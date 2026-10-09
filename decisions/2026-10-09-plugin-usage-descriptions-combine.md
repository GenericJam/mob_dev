# Plugin usage descriptions combine across plugins; other Info.plist keys still collide

- Date: 2026-10-09
- Status: accepted
- Issue: MOB-421 (mob_ci finding F9)

## Context

`mob_bluetooth` and `mob_midi` both declare `NSBluetoothAlwaysUsageDescription`
in `ios.plist_keys`, each with its own reason ("discover and advertise to nearby
devices", "connect to wireless (BLE) MIDI devices"). `cross_validate/2` treated
every Info.plist key two plugins declare as a collision, so a host activating
both was refused before the build. The MOB-387 host exemption let it through
only if the author already knew to set the key in `ios/Info.plist`.

A usage description is the text of the iOS permission prompt. When two plugins
need the same permission, the app needs it for both reasons, and App Review
expects the purpose string to describe the app's actual use. Either plugin's
string alone is incomplete; last-write-wins (what `Merge.plist_keys/1` did)
silently drops one reason.

Options considered:

1. **Host must set the key**: a validate error naming both plugins and the
   `ios/Info.plist` line to add. A clear instruction, but every host combining
   two such plugins stops at a build error to write prose.
2. **Plugins stop declaring usage descriptions**: then even a single-plugin
   host has no default and iOS terminates the app on first Bluetooth access.
3. **Combine**: join each plugin's distinct sentence, in activation order.

## Decision

Option 3, with the host override from the 2026-05-28 ADR unchanged.

- `Manifest.usage_description_key?/1`: a key ending in `UsageDescription`.
- `Merge.plist_keys/1` groups declarations by the key's string name. A usage
  description every declaring plugin gives as a string becomes the distinct
  (trimmed, non-empty) sentences joined with a space, each ended with a period
  if it has no terminal punctuation. The same string from several plugins
  lands once, verbatim. Any other key keeps the later plugin's value.
- `cross_validate/2` exempts those combinable keys. Everything else is as
  before: a non-description key two plugins declare is a collision unless the
  host's `ios/Info.plist` sets it (scalars only); a usage description some
  plugin declares as a non-string still collides. Keys compare by string name,
  so `:K` and `"K"` from two plugins now clash instead of one silently losing.
- The iOS build prints one line per combined description the host doesn't set,
  naming the plugins and saying to set the key in `ios/Info.plist` to word the
  prompt itself. The gate's collision error says that a host-set key is not a
  conflict when an Info.plist key is among the errors.

## Consequences

- Activating any set of plugins that only share usage descriptions builds with
  no host change, and the prompt names every reason.
- The combined text is two plugin-authored sentences, not prose the author
  chose; the build line tells them, and their `ios/Info.plist` value wins.
- mob_ci's `all` set no longer needs to park `mob_midi` (F9).
