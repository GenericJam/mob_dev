# Every downloaded runtime artifact is pinned by SHA-256; published assets are immutable

- Date: 2026-11-26
- Status: accepted
- Issue: MOB-553
- Builds on: `2026-06-17-otp-hash-elixir-1.20.1.md` (new hash, not clobber)

## Context

mob_dev downloads prebuilt artifacts and then extracts, links or ships them:
the five OTP runtimes and the two MLX bundles from `GenericJam/mob` releases,
BeeWare's Python-Apple-support, Chaquopy's three CPython zips, and TFLite's AAR,
iOS tarball and two headers. Their integrity rested on HTTPS alone, an
extracted cache was accepted on its layout, and the OTP release process
re-uploaded changed tarballs at the same URL ("schema-bump pattern"), so the
bytes behind a URL were not fixed. Extraction relied on each platform's
`tar`/`unzip` defaults, which differ, and did not check symlink targets.

## Decision

- **Pins in source.** `MobDev.Download.Pins` maps each URL a downloader can
  request to its SHA-256. A downloader looks the pin up before fetching
  (`MobDev.Download.pin/1` refuses an unpinned URL), verifies the file after
  download and before anything reads it, and on mismatch deletes it and fails
  with the expected and actual hashes. Keyed by URL because that is exactly
  what is fetched, and it covers third-party assets with no hash in the name.
- **Caches record their source.** After a verified extraction the downloader
  writes `.mob_download_sha256` (the archive's pin) into the cache dir; a cache
  is reused only when the marker matches the current pin. Caches from older
  mob_dev versions have no marker and are re-downloaded once. TFLite keeps its
  downloaded AAR/tarball (one archive serves two targets) and re-hashes it on
  every reuse. This detects an unverified or stale cache; it does not hash the
  extracted tree on every build, so it is not a defence against something that
  can already write to `~/.mob/cache`.
- **Local overrides are the developer's own builds.** `MOB_MLX_LOCAL_TARBALL_DIR`
  and `MOB_TFLITE_LOCAL_TARBALL_DIR` exist to use archives that differ from
  the published ones, so they are not held to the pin. Their hash is recorded
  as the cache marker instead, so the cache is replaced once the override is
  unset. TFLite now reads the local archive in place instead of copying it into
  the download cache.
- **Extraction refuses unsafe archives.** `MobDev.Download.untar/3` and
  `unzip/2` list members first (`:erl_tar.table`, `:zip.list_dir`) and refuse
  absolute names, `..` segments, hard links/devices/FIFOs, and members stored
  beneath a symlink member (compared at the path each member lands at after
  `--strip-components`, reading a `./` prefix both as a component and not,
  case- and Unicode-normalization-insensitively, since APFS resolves names
  that way). After extraction the tree is made
  owner-readable (`chmod -R u+rwX`, which does not follow links) so nothing is
  hidden from the scan or from cleanup, then every symlink must resolve,
  following other links, inside the destination (`:filelib.safe_relative_path/2`
  against the destination, so stripping is accounted for); a directory that
  cannot be listed is an error. Offending links are deleted and the caller
  discards the tree. Extraction itself stays with system `tar`/`unzip` for
  speed and `--strip-components`. MLX now extracts into its own cache dir with
  `--strip-components=1` rather than into the shared cache root.
- **Downloads land in the user's cache, not a shared temp dir.** The file that
  is verified and then extracted is written to `.download-<asset>` beside its
  cache dir (`MobDev.Download.staging_path/2`), so another local user cannot
  pre-create or swap it between the hash check and extraction. The name is
  fixed per asset, so an interrupted download is overwritten by the next try
  rather than left to pile up.
- **Published assets are immutable (the boring option).** A rebuilt runtime gets
  a new hash, and so new asset names and URLs, as `2026-06-17` already did for
  Elixir 1.20.1. `mix mob.release.publish` (which now also knows the x86_64
  tarball), `scripts/release/publish.sh` and `scripts/release/mlx/publish.sh`
  refuse to upload over an existing asset (no `delete-asset`, no `--clobber`)
  and print the pin entries for the new assets.
  `test/mob_dev/download/pins_test.exs` fails when a downloader can request a
  URL without a pin, or a pin is left that nothing requests. `mix mob.doctor`
  warns about an OTP cache that was not extracted from the pinned tarball.

## Alternatives considered

- **Content-addressed asset names** (`otp-android-<hash>-<sha12>.tar.gz`) so a
  rebuild can share a tag. Needs a name table in the downloader and renaming at
  publish time; the new-hash rule already gives every rebuild distinct URLs.
- **Hashing the extracted tree on every build.** Thousands of files per OTP
  runtime on every deploy, to defend against a local writer who could equally
  edit mob_dev.
- **`:erl_tar.extract` instead of system `tar`.** It already refuses `..` and
  escaping symlinks, but relative to the archive root, so a link that escapes
  only after the top directory is stripped passes; it has no strip option, and
  it silently skips hard links. The member-list check plus post-extraction link
  check covers both extractors the same way.

## Consequences

- First build after upgrading re-downloads every runtime once (no marker).
- A release-process mistake that changes bytes behind a pinned URL now fails
  every build with a hash mismatch instead of silently shipping different bytes.
- Bumping `@otp_hash`, the MLX tag, or a third-party version needs the pin in the
  same PR; the test says which URL is missing one.
- Pins for the current assets were taken by downloading each URL and hashing it,
  and cross-checked against GitHub's asset `digest` (GenericJam/mob, BeeWare)
  and Maven Central's `.sha1` files (Chaquopy, TFLite AAR).
