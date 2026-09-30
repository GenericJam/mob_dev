# Record the NIF plugins each native build compiled in, warn on BEAM-only drift
- Date: 2026-09-30
- Status: accepted

## Context

MOB-281: `:mob_scanner_nif.scanner_scan/1` returned `{:nif_not_loaded, ...}`.
Plugin `on_load`s tolerate a missing NIF, so two mistakes build and boot clean
and fail only at the first NIF call: a NIF plugin in deps but not in
`config :mob, :plugins`, and a plugin activated after the installed binary was
built (only a BEAM-only `mix mob.deploy` / `mix mob.push` ran since).

The first is decidable from the project alone. The second needs to know what
the installed binary contains, which the host can't read cheaply from every
device.

## Decision

- Every successful native build writes `mob_native_plugins.txt` under
  `Mix.Project.build_path/0`: one line per platform that built, listing the
  activated plugins with a NIF for that platform — decided by
  `Manifest.nif_for_platform?/2`, the same rule the build uses (an untagged
  `lang: :objc` NIF is iOS-only). A failed platform keeps its old line.
  BEAM-only deploy/push compare the current activation against it for the
  platforms they target (deploy: selected devices; push: platforms parsed from
  connected node names after stripping the project app prefix, so an app name
  containing `ios`/`android` can't be misread).
- A platform with no line is reported as "no record — if the installed app
  predates activating X, rebuild", not as a stale build.
- Plain text, names kept as strings: `binary_to_term(..., [:safe])` refuses
  atoms that don't exist yet, and a removed plugin's atom often won't.
- Every finding is a warning, never a failure — including failing to write
  the record, which must not fail a native build that just succeeded.
- The inactive-plugin warning only considers deps that ship to the device
  (`HotPush.runtime_lib_names/0`); activating an `only: :dev` /
  `runtime: false` dep would fix nothing on the device.
- Manifests are read through `Verify.load_verified/2` (MOB-74); an
  unverifiable dep is not eval'd and so is not reported as inactive. This scan
  reads every dep's envelope, not just activated ones, so `Verify` now refuses
  a v2 envelope whose `file_hashes` entries aren't `{path, hash}` binaries as
  `:corrupt` — it used to raise mid-verification.

## Consequences

- The record describes the last native build on this machine for this
  `MIX_ENV`, not what a given device has installed. A device installed from
  another checkout, or before `mix clean`, can disagree with it; the warning
  is a prompt, not proof. iOS simulator and device builds share one `ios` line.
- Projects built before this change get the "no record" warning once per
  BEAM-only deploy while NIF plugins are active, until their next native build.
- An inactive plugin whose signature doesn't verify isn't named; activating it
  hits `SignatureGate`'s build-blocking error, which does name it.
