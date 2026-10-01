# Plugin envelope v2 — verify signature before eval

- Date: 2026-09-11
- Status: accepted; point 5 amended by [2026-09-30-v1-envelope-transition.md](2026-09-30-v1-envelope-transition.md) (MOB-287); points 1 and 3 amended by [2026-09-30-plugin-signature-coverage.md](2026-09-30-plugin-signature-coverage.md) (MOB-297)

## Context

Before this change, `MobDev.Plugin.Manifest.load/1` (which is called from
`MobDev.Plugin.activated/0` on every `mix mob.deploy`, and from
`mix mob.plugins` / `mix mob.audit_plugins` / `MobDev.Plugin.Report`)
called `Code.eval_file("priv/mob_plugin.exs")` **before** any signature
check. The signature check that ran afterwards (`SignatureGate.check_plugin/4`
→ `Verify.verify_plugin(dir, manifest)`) covered the *eval'd manifest map*
plus a list of referenced sources — but NOT the manifest bytes themselves.
So a malicious plugin could:

```elixir
# priv/mob_plugin.exs
File.write!("/tmp/pwned", "evil ran")         # side effect
%{name: :innocent, mob_version: "~> 0.7", ...}
```

`Code.eval_file/1` would execute the side effect on the consumer's
machine, then return the innocent-looking map. The signature covered the
map (which was untouched) so `Verify` reported clean, and the CVE was
never surfaced.

Filed as MOB-74 in the July 2026 audit.

## Decision

Move to envelope v2, which flips the trust chain end-to-end:

1. **The manifest bytes join the signed file_hashes list.** `Sign.referenced_files/2`
   now always prepends `priv/mob_plugin.exs` — the file that used to be
   trusted implicitly is now cryptographically covered like every other
   source.

   **Correction (2026-09-30, MOB-297):** "cryptographically covered like every
   other source" overstated it. `referenced_files/2` hashed only
   `.c`/`.h`/`.cpp`/`.zig` inside a `native_dir`, so every iOS `.m` NIF was
   unsigned, and `cpp_archive` sources were skipped. `Sign.build_inputs/2`
   replaces it for new signatures, which also carry a signed coverage marker.
   See [2026-09-30-plugin-signature-coverage.md](2026-09-30-plugin-signature-coverage.md).
2. **The v2 envelope on disk carries the file_hashes list alongside the
   signature.** Payload signed = `%{file_hashes: [...], envelope_version: 2}`.
   The eval'd manifest map is no longer part of the payload — its
   authoritative representation is the on-disk bytes, whose hash lives
   in file_hashes.
3. **`Verify.verify_plugin/1` no longer takes a manifest arg.** It reads
   the envelope, rebuilds the payload from the envelope's own file_hashes
   (proving the author signed *this* list of files), then re-hashes each
   listed file on disk (proving the disk hasn't been tampered with since
   signing). Neither step calls `Code.eval_file/1`.

   **Correction (2026-09-30, MOB-297):** "Neither step calls `Code.eval_file/1`"
   no longer holds for new signatures. When the envelope carries the coverage
   marker, `verify_plugin/1` evaluates the manifest *after* both steps pass,
   to check that every build input is listed. The bytes it evaluates have
   already matched their signed hash, so verification still runs before any
   evaluation of unverified bytes. Envelopes without the marker still never
   evaluate. See [2026-09-30-plugin-signature-coverage.md](2026-09-30-plugin-signature-coverage.md).
4. **`Verify.load_verified/1`** is the new consumer entry point. Verifies
   first; only calls `Manifest.load/1` (which does the eval) after
   verification passes. This is the actual MOB-74 close: a plugin that
   fails verification never has its `.exs` bytes evaluated on the
   consumer's machine.
5. **v1 envelopes are refused.** They can't verify without the eval'd
   manifest to rebuild their payload, so accepting them silently reopens
   the CVE. The refusal is a distinguished `:envelope_v1_unsupported`
   error with an actionable re-sign hint.

   **Correction (2026-09-30, MOB-287):** this point is no longer unconditional.
   It assumed first-party plugins would be re-signed before any release that
   refuses v1. They could not be: plugin CI signs with the Hex mob_dev, which
   predates this change, so every published first-party plugin is v1-signed.
   For one transition window, a v1 envelope is accepted when Mix resolves the
   plugin through Hex, mix.lock pins it as a `hexpm` package in the deps
   directory, **and** its
   `priv/mob_plugin.pub` fingerprint is trusted in `:trusted_plugins`. Both
   checks run before any eval. The v1 signature must then verify against the
   evaluated manifest. Every other v1 envelope still gets this refusal. See
   [2026-09-30-v1-envelope-transition.md](2026-09-30-v1-envelope-transition.md).

   **Update (2026-09-30, MOB-301):** the transition was removed in mob_dev
   0.7.6, once every first-party plugin had a v2-signed release. This point
   is unconditional again: every v1 envelope is refused,
   and the error tells the user to `mix deps.update <plugin>`.

## Consequences

- **Breaking change for signed plugins.** Every plugin published with a
  mob_dev ≤ 0.7.1 signature must be re-signed with mob_dev 0.7.2+.
  There is no fallback path; the whole point of the fix is that the
  fallback path was the bug. First-party plugins get re-signed as part
  of the 0.7.2 release; third-party authors will see the
  `:envelope_v1_unsupported` error and follow the re-sign hint in the
  message. See [`MOB_PLUGIN_SECURITY.md`](../MOB_PLUGIN_SECURITY.md).

  **Correction (2026-09-30, MOB-287):** "First-party plugins get re-signed as
  part of the 0.7.2 release" did not happen, and "there is no fallback path" is
  suspended for one release window. See point 5's correction and
  [2026-09-30-v1-envelope-transition.md](2026-09-30-v1-envelope-transition.md).

  **Update (2026-09-30, MOB-301):** the window has closed; there is again no
  fallback path for v1.
- **Consumer paths that eval a manifest** now go through
  `MobDev.Plugin.Verify.load_verified/1` in the four places that
  matter to build- or activation-time: `MobDev.Plugin.activated/0`,
  `mix mob.plugins`, `mix mob.audit_plugins`, `MobDev.Plugin.Report`.
  *(Correction, MOB-281: this list was exhaustive when written; a fifth
  consumer now exists — `MobDev.Plugin.NifActivation.dep_manifests/0`, which
  reads every dep's manifest to warn about installed-but-inactive NIF
  plugins. It also goes through `load_verified/2`, so an unverifiable
  inactive plugin is never eval'd and is simply not reported.)*
- **Author-side paths still eval before verify** on purpose —
  `mix mob.plugin.sign` and `mix mob.plugin.keygen` operate on plugins
  the author owns and is about to sign; there is no attack vector.
  `mix mob.plugin.trust` is the first-trust decision by definition;
  the user is explicitly reviewing a plugin they don't trust yet.
  `mix mob.validate_plugin` runs as an author-side lint pass
  (`priv/mob_plugin.exs` shape checks against `Manifest.validate/1`);
  no attack vector for the author's own plugin. All four are noted as
  separate follow-ups (MOB-185/186/187 lay out the longer-term path
  to data-only manifests, which closes the class entirely).
- **`SignatureGate.check_activated/1` tier-0 detection** switched from
  "`is_map(manifest)`" (the old proxy) to
  "`Manifest.manifest_present?(dir)`". This is necessary because a
  failed-verification tier-1 plugin now also has `manifest == nil` —
  distinguishing the two by manifest-file presence surfaces the
  friendly error for the failed case instead of silently skipping.
- **`Verify.load_verified/2` accepts `acknowledged_unsafe: true`** as
  the second-arg option, and `MobDev.Plugin.activated_with_verify/0`
  passes it for plugins in `:acknowledge_unsafe_plugins`. Without
  this, an acknowledged unsigned plugin's `{:error, :missing_signature}`
  would strip its manifest map from the build even though
  `SignatureGate.check_plugin/4` still lets the plugin through
  (`if name in acknowledged, do: :ok`). Downstream `Merge`,
  `AndroidBootstrap`, `RuntimeManifest` all filter on
  `is_map(manifest)` — the acknowledged plugin would appear activated
  but contribute nothing: no NIFs, no gradle deps, no permissions. The
  opt-in escape hatch is scoped to `:missing_signature` only; every
  other verify failure (`:invalid_signature`, `:missing_pubkey`,
  `:envelope_v1_unsupported`) still refuses the eval because those
  are tamper / mis-key / attack signals, not "unsigned during dev".
- **UX regression when the manifest name isn't derivable from a nil
  manifest** — the gate falls back to `Path.basename(dir)` for the error
  label. In real deployments this equals the Hex package name; in tests
  it's a temp-dir basename. Acceptable — the alternative is a bigger
  return-shape refactor to thread the dep name through every layer.
- **Follow-up tickets on file:** MOB-185 (`mix mob.plugin.lint`),
  MOB-186 (migrate first-party plugins to the pure-data subset the
  linter accepts), MOB-187 (static JSON/TOML manifest at 1.0). Together
  they walk the manifest format from "safe if verified" (this ADR)
  toward "safe by construction" (MOB-187 endstate).
