# A physical-iPhone deploy never removes anything: numbered uploads, or a merge

- Date: 2026-10-15
- Status: accepted
- Linear: MOB-408

## Context

`mix mob.deploy` copied a physical iPhone's BEAMs with
`xcrun devicectl device copy to ... --destination Documents/otp/<app>
--remove-existing-content true`, replacing the override rather than merging
into it (so removed modules didn't linger), then read back `<app>.beam` to
check it.

Measured on Kevin's iPhone SE (devicectl 642.16): with that flag, devicectl
empties the app's whole data container except the destination, not the
destination directory its help describes. A merge copy (no flag) to
`Documents/otp/zz` left everything in place; the same copy with the flag left
only `Documents/otp/zz`, deleting `Documents/app.db`, the other Documents files
and directories, `Documents/otp`'s other entries, and the files in `Library/`
and `tmp/`. Reproduced end to end with a blank host on mob 0.9.19 and mob_dev
0.7.26: a sentinel file, a SQLite row, a nested directory, a `Library/` file and
a sibling in `Documents/otp` were all gone after one BEAM-only deploy. Every
deploy erased the app's data, and an interrupted one left the only directory
`mob_beam.m` loads incomplete.

devicectl has no delete or rename verb, so the Mac can neither clean up nor
swap a directory atomically. `devicectl device info files` lists a directory;
for one that doesn't exist (or an app that isn't installed) it exits 1 with
`CoreDevice.ActionError` code 3 in its JSON.

## Decision

Never pass `--remove-existing-content`. Every copy is a merge. Where it goes
depends on the app's runtime:

- **mob ≥ 0.9.20** (`ios/mob_code_versions.h` in mob; mob's
  `decisions/2026-10-15-ios-versioned-code-dirs.md`): list
  `Documents/otp/<app>.versions/`, upload to `<N>/` with `N` one above the
  highest numeric entry (committed or not, so an upload never lands on an
  interrupted one's leftovers), read back `<N>/<app>.beam` and compare, then
  copy `<N>/.mob_complete`. The app loads the highest committed `N` and
  deletes older ones at boot, so an interrupted deploy leaves the previous
  code running.
- **Older runtimes**: merge into `Documents/otp/<app>`, the one directory they
  read. A module removed from the project lingers there, and an interrupted
  copy can still leave a mix of old and new BEAMs; the error says so.

The versioned layout is used only when both are true (`ios_code_plan/2`):

- the project's `:mob` dependency has `ios/mob_code_versions.h`, so the
  runtime built from it reads the layout. A file, not a version number, so a
  path or git dependency of an unreleased mob counts;
- `Documents/otp/<app>.versions/` exists on the phone, which the runtime
  creates at every boot.

The first alone misses mob updated without `--native` (an old runtime still
on the phone, which would ignore the upload); the second alone misses a phone
that ran a newer mob before a `--native` downgrade. A listing that fails any
other way fails the deploy.

Both together still guess wrong when the project's mob moves across 0.9.20
without `--native` on a phone that has `<app>.versions/`: a versioned upload
an old runtime ignores, or a legacy merge that a new runtime's committed
version shadows (and that runtime then deletes). So the deploy checks the
result instead of trusting the guess. Every mob runtime since 0.6.2 writes
the directory it loaded to `Documents/mob_diag_beams_dir.txt` at boot. The
deploy overwrites that file with a placeholder (a legacy deploy expects the
same path the previous boot may have written), relaunches, reads it until it
names the directory just written (up to 20 s), and otherwise fails, naming
where the app booted from and saying to run `mix mob.deploy --native`. No
relaunch (a launch that failed, or `restart: false`) means nothing to check.

## Consequences

- No BEAM deploy deletes app data again, whatever mob the app runs.
- A physical-iPhone deploy that relaunched the app and reports success has
  had the app boot from the code it wrote.
- The `mix mob.deploy --native` run that first puts mob ≥ 0.9.20 on a phone
  still merges into `Documents/otp/<app>` (the new runtime hasn't booted to
  create `<app>.versions/`); its restart boots that runtime, later deploys
  are versioned, and the first versioned boot deletes the legacy directory.
- Each deploy costs one more devicectl call (the listing, for a project on
  mob ≥ 0.9.20), one more for a versioned one (the marker), and the boot
  check: about a second over USB in total, more if the app is slow to start.
- Two deploys to one phone at the same moment can both pick the same `N`.
  Concurrent deploys could always clobber each other; this doesn't fix that.
- A physical iPhone connected over dist is still only hot-loaded
  (`persistable?/1`): a LAN-only device has no devicectl route, and an old
  runtime's merge can still break the app mid-copy.
