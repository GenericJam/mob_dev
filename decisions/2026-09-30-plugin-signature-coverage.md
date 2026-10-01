# Plugin signatures cover every build input, marked inside the signed list (MOB-297)

- Date: 2026-09-30
- Status: accepted
- Linear: MOB-297
- Amends: [2026-09-11-plugin-envelope-v2-verify-before-eval.md](2026-09-11-plugin-envelope-v2-verify-before-eval.md) (points 1 and 3)

## Context

A v2 signature lists `{path, sha256}` for the files the signer picked, and
`Verify` rehashes only the listed files. The signer picked too few:

- A NIF's `native_dir` was filtered to `.c`/`.h`/`.cpp`/`.zig`. Every iOS
  Objective-C NIF (`lang: :objc`, `<module>.m`) was unsigned, and so was any
  `.mm`/`.hpp`/`.inc` the compiler includes. mob_camera 0.1.9 and
  mob_scanner 0.1.4, both published today, list their `.kt` and `.zig` but
  not their `.m`.
- A NIF with no `native_dir` (the build defaults it to `priv/native/jni`)
  had nothing expanded.
- `lang: :cpp_archive` `sources:`/`includes:` were ignored.
- Migrations, fonts and images the build copies out of the plugin were
  ignored.

And the verifier had no completeness check, so a file the build reads but
the envelope doesn't list could be added or swapped freely.

## Decision

1. **One function says what the build reads:** `Sign.build_inputs/2`. It
   calls the same `MobDev.Plugin.Merge` gatherers the build uses, with the
   plugin dir set to `""` so they return the declared relative paths: the
   manifest, `swift_files`, `bridge_kt`, `res_files`, every compiled
   C-family source (C/ObjC/Zig NIF primary sources, `jni_source`,
   `cpp_archive` `sources:`) **and every file under each one's directory**
   (a quoted `#include`/`@import` resolves there first),
   `migrations_dir/*.exs`, `assets.fonts`, `assets.images`,
   `default_font.file`. The signer lists all of them; the verifier
   recomputes the same set. Not covered: `{:dep, app, path}` entries,
   which are another package's files, and plugin-relative `cpp_archive`
   `includes:` roots (see Tradeoffs).
2. **New signatures declare coverage with a marker entry inside the signed
   `file_hashes`:** `{"priv/mob_plugin.coverage-2", sha256(<<>>)}`. The path
   never exists; a missing file hashes as empty bytes.
3. **Verifier:** after every listed file matched and the signature verified,
   if the marker is present, evaluate the manifest, recompute
   `build_inputs/2`, and return `:invalid_signature` when any input is not
   listed. `load_verified/2` reuses the manifest that check evaluated
   instead of evaluating it again. `verify_plugin/1` discards it, so in a
   build a marked manifest is evaluated once more by
   `SignatureGate.check_plugin` → `verify_plugin/1`, after `activated/0`
   has already evaluated it once.
4. **Envelopes without the marker verify exactly as before.** They were
   signed with the narrower rule, and holding them to `build_inputs/2`
   would refuse every plugin published so far. The published mob_scanner
   0.1.4 `priv/` is a test fixture proving it.
5. The pre-MOB-297 file selection moves into `V1Transition`, because v1
   payloads were built with it and rebuilding one needs it verbatim.

   **Update (2026-09-30, MOB-301):** `V1Transition` was removed in mob_dev
   0.7.6, and the pre-MOB-297 file selection with it.
   No v1 payload is rebuilt any more. Point 4 is unaffected: v2 envelopes
   without the marker still verify as before.

## Why a marker entry and not a `coverage:` key

The ticket proposed `coverage: 2` in the envelope. mob_dev 0.7.2 hosts must
verify plugins re-signed by newer mob_dev, and a key fails that three ways:

- **In the signed payload:** 0.7.2 rebuilds the payload as exactly
  `%{file_hashes: fh, envelope_version: 2}`. An extra payload key means
  every new signature fails on 0.7.2.
- **In the envelope only (unsigned):** anyone can delete it, which turns
  the completeness check off. That makes it useless as a security boundary.
- **Either way, a new atom:** 0.7.2 decodes the envelope with
  `binary_to_term(_, [:safe])` and interns only `:signature`,
  `:envelope_version` and `:file_hashes`. `:coverage` is not guaranteed to
  exist in a host VM, so the decode would fail intermittently as `:corrupt`.
  That is the bug in
  [2026-05-31-verify-safe-atom-intern.md](2026-05-31-verify-safe-atom-intern.md).

A `file_hashes` entry avoids all three. It is a string, so there is no new
atom. It is inside the payload 0.7.2 rebuilds, so it is signed and can't be
stripped. And 0.7.2 rehashes it, finds no file, gets the empty-bytes hash,
and accepts it. `envelope_version` stays 2 because 0.7.2 refuses anything
else.

Verified against the real 0.7.2 code: the `lib/mob_dev/plugin/{crypto,sign,verify,manifest}.ex`
files from `mix hex.package fetch mob_dev 0.7.2`, compiled into a fresh VM.
It returns `:ok` for a mob_camera 0.1.9 copy re-signed by this branch. It
returns `:invalid_signature` when that copy's `.m` is tampered, because the
file is now listed. It returns `:ok` when an unlisted `extra.h` is added,
because only an upgraded host runs the completeness check.
`verify_test.exs` includes a copy of 0.7.2's decode and payload rebuild,
and asserts that the envelope uses only 0.7.2's atoms.

The `-2` suffix versions the rule. A future `build_inputs/2` change that
would reject existing marked signatures, such as a new file-bearing
gatherer, needs a new marker, and the verifier keeps the old rule for the
old marker.

## Evaluation order (MOB-74)

Before this change `verify_plugin/1` never evaluated the manifest. Now,
for a marked envelope, it does, because the completeness set depends on
the manifest term. The evaluation runs only after:

1. every listed file, `priv/mob_plugin.exs` included, matched its signed
   hash, and
2. the Ed25519 signature over that list verified.

The bytes being evaluated are the bytes the key holder signed. That is the
same point where `load_verified/2` has always called `Manifest.load/1`, so
no attacker who can't sign gets a new evaluation. A tampered manifest fails
step 1 and is never evaluated. Like `load_verified/2`, this does not check
trust: a self-signed plugin's manifest is evaluated before
`SignatureGate.check_trust`, as it already was in `activated/0`. A signed
manifest that fails to evaluate makes `verify_plugin/1` return
`:invalid_signature`, because completeness can't be checked. In that case
`load_verified/2` returns the evaluation error message, as it did before.

## Tradeoffs

- **`cpp_archive` `includes:` roots are not expanded.** An include root can
  be provisioned on the host rather than shipped. mob_nx_eigen declares
  `includes: ["eigen-3.4.0", …]`, and its `eigen_headers` Mix compiler
  downloads about 1,775 Eigen headers into `deps/mob_nx_eigen/eigen-3.4.0`
  on every host. The Hex package does not contain them. If include roots
  were expanded, both ways of signing would fail. Signed from a clean tree,
  every compiled host would find the headers unlisted. Signed from a
  provisioned tree, every host that hasn't provisioned them yet would find
  listed files missing. (Adversarial review caught this before merge.) The
  gap: a header in a *shipped* include root that sits outside every
  source's directory can be swapped without detection. Headers a plugin
  ships belong beside its sources, where directory expansion covers them.
- **Directories are listed with `File.ls`/`File.lstat`, not
  `Path.wildcard`.** A `[` or `{` in the plugin's absolute path would be
  read as glob syntax and match nothing. The signer and the verifier would
  then disagree about the set. Symlinks are listed as entries and never
  followed, so a link loop can't hang verification. A symlink to a
  directory hashes as empty bytes, which is still enough to detect one
  being added.
- **A compiled source at the plugin root** expands the whole plugin tree
  (`lib/`, `mix.exs`, any provisioned directory). The plugin is then
  refused on hosts where that tree changes. Keep native sources in a
  subdirectory.
- **Dotfiles are skipped in directory expansion.** Hex does ship dotfiles
  from `priv/` subdirectories (checked with `mix hex.build`: `.hidden.h`
  ships, `.DS_Store` doesn't). But `.DS_Store` also appears on hosts
  whenever someone opens `deps/` in Finder. If dotfiles counted, that
  harmless file would fail verification. The gap: a signed source that
  `#include`s a dotfile header is not protected against swaps of that
  header.
- **Paths outside the declared directories** (`#include "../common/x.h"`)
  are not covered. That was already true.
- **0.7.2 hosts get the wider list but no completeness check.** Tampering
  with a newly listed file is caught everywhere. Adding an unlisted file is
  caught only after the host upgrades.
- A file under a native dir that exists in the author's tree when signing
  but is left out of the Hex package is listed, then missing on the host,
  so verification fails. That is the same failure mode as any missing
  listed file today. Sign from a clean tree.
