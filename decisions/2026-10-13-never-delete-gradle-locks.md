# mob_dev never deletes Gradle lock files

- Date: 2026-10-13
- Status: accepted
- Issue: MOB-469 (follows MOB-468)

## Context

Since 2026-04-23 `gradle_assemble` ran `clear_stale_gradle_locks/1` before every
`gradlew assembleDebug`, deleting `~/.gradle/daemon/*/registry.bin.lock`,
`wrapper/dists/**/*.lck` and `caches/**/*.{lock,lck}` (and, until MOB-468,
`native/**/*.lock`). The comment said interrupted builds left these behind and
the next build hung waiting for them.

Gradle's locks are OS-backed `FileChannel` locks. The OS releases them when the
holding JVM exits, killed or not; the file staying on disk means nothing. A
contended lock waits and then fails with a timeout (the cache and daemon locks
name the owner PID when Gradle knows it). Deleting the file does not release a
live lock: it unlinks the inode, so the next process locks a new file at the
same path while the old holder keeps going, and two builds write the shared
caches at once. MOB-468 was this failure for `native/`: concurrent JVMs crashed
with SIGSEGV. The cache and wrapper locks guard the same kind of shared state.

## Decision

mob_dev does not delete, truncate or otherwise touch any file under
`GRADLE_USER_HOME`. A contended lock is left to Gradle: the user stops the live
owner (or waits) instead of mob_dev deleting the file.

## Consequences

- Concurrent Android builds on one host (two projects, the NUC's CI lanes)
  keep Gradle's mutual exclusion.
- A build killed mid-Gradle (Ctrl+C, `kill -9`) does not hang the next build:
  its locks went with its JVM. Verified on macOS with a blank host on
  emulator-5554: wrapper and daemon killed with SIGKILL during
  `:app:mergeExtDexDebug`, rerun finished (`BUILD SUCCESSFUL in 13s`).
- A lock held by a live process now surfaces as Gradle's timeout error rather
  than being silently stolen.
- `gradle_assemble/1` has a test asserting lock files in `GRADLE_USER_HOME`
  survive a build.
