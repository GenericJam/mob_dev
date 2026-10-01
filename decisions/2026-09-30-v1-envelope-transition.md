# Legacy v1 plugin envelopes: accepted for one transition window (MOB-287)

- Date: 2026-09-30
- Status: superseded — removed by MOB-301 (see "Removed")
- Linear: MOB-287
- Amends: [2026-09-11-plugin-envelope-v2-verify-before-eval.md](2026-09-11-plugin-envelope-v2-verify-before-eval.md), point 5

## Context

MOB-74 made mob_dev refuse every v1 signature envelope
(`:envelope_v1_unsupported`). v1 signatures cover the *evaluated* manifest
map, so checking one means running `Code.eval_file` on
`priv/mob_plugin.exs` first. That is arbitrary code execution for whoever
controls the manifest.

Plugin CI signs with the mob_dev release on Hex, and that release predates
MOB-74. So every published first-party plugin is v1-signed (mob_scanner
0.1.3, mob_camera 0.1.8, and the rest). A mob_dev release that refuses all
v1 envelopes breaks the next native build of every app that activates a
first-party plugin. We need a new mob_dev on Hex before the plugins can be
re-signed as v2, and we need re-signed plugins before we can refuse v1.

## Decision

mob_dev still signs v2 only (`mix mob.plugin.sign` is unchanged). For one
release window it accepts a v1 envelope only when all three of these hold:

1. **Hex provenance, no eval needed.** Mix resolves the dependency through
   `Hex.SCM` right now (`Mix.Project.deps_scms/0`). The project's
   `mix.lock` pins it as `{:hex, name, vsn, _, _, _, "hexpm", _}`: the
   package has the same name and comes from the public `hexpm` repository.
   And the plugin directory is the Hex checkout at `<deps_path>/<name>`.
   Path and git deps fail this check, and so do private or organisation
   repos. All three parts are needed. When a dep is switched to `path:` or
   `git:`, Mix keeps the old hexpm line in mix.lock, so the lock alone
   proves nothing. The smoke run hit this with a path dep outside `deps/`,
   which the directory check caught. Review then found that
   `{:mob_scanner, path: "deps/mob_scanner", override: true}` resolves to
   exactly the Hex checkout directory, and only the active-SCM check
   catches it.
2. **Trusted key, no eval needed.** The fingerprint of
   `priv/mob_plugin.pub` equals the fingerprint the project trusts for that
   plugin name in `config :mob, :trusted_plugins`.
3. **Valid v1 signature.** After checks 1 and 2 pass, the manifest is
   evaluated. The v1 payload is rebuilt as `%{manifest: <map>,
   file_hashes: <referenced files, excluding the manifest file>,
   envelope_version: 1}` and checked against the envelope signature.

If any check fails, the result is the existing `:envelope_v1_unsupported`
refusal. When check 1 or 2 fails, the manifest is never evaluated. The
`SignatureGate` error now spells out this rule.

Every build prints one line for each plugin accepted this way:

    mob_scanner 0.1.3 uses a legacy v1 signature, accepted during the v2 transition (MOB-287); it will be refused once re-signed releases ship

The code is kept in one place so it is easy to delete:

- `MobDev.Plugin.V1Transition` holds the rule. It restores the pre-MOB-74
  payload rebuild (commit `137fe20^`, `Verify.verify_plugin/2`), and
  nothing else from the old code.

  *(Correction, MOB-297: "nothing else" stopped being true. MOB-297 changed
  the signer's file selection for new signatures, and v1 payloads need the
  old one. The pre-MOB-297 rule, which hashes only `.c`/`.h`/`.cpp`/`.zig`
  from a `native_dir`, now lives in this module as `v1_referenced_files/2`
  and is deleted with it. See
  [2026-09-30-plugin-signature-coverage.md](2026-09-30-plugin-signature-coverage.md).)*
- `Verify.load_verified/2` calls it for the eval path.
  `activated/0`, `mix mob.plugins`, `mix mob.audit_plugins` and `Report`
  all go through this function. So will `NifActivation` from MOB-281, via
  `load_verified/2`. The API shape does not change; the only addition is
  optional `:scms` / `:lock` / `:deps_path` / `:trust_map` keywords.
- `SignatureGate.check_plugin/5` calls it through `accepted?/3`. This path
  never evaluates: it re-checks provenance and verifies the manifest that
  `activated/0` already loaded.
- `SignatureGate.maybe_print_v1_transition_notice/2` prints the notice. It
  is called from `Validator.raise_on_capability_drift!/1`, next to the
  unsigned-plugin banner.

## Why this is safe enough

- **Evaluating the manifest adds no capability.** A hexpm dependency's
  `mix.exs` is evaluated, and its code is compiled (macros included), on
  every `mix deps.get` / `mix compile`. The package author already runs
  code on the consumer's machine. The MOB-74 attacker was someone whose
  manifest runs *without* that level of trust. Check 1 rules those
  sources out before any eval.
- **Hex fixes who published it.** On hexpm, only the package owners can
  publish under a name. Hex checks the tarball checksum against the
  registry and the lock on fetch. A look-alike package (`mob_scannr`) has
  no entry in `:trusted_plugins`, so check 2 refuses it before eval.
- **The trust pin is still required.** Check 2 is the same TOFU decision
  that v2 plugins need. The user has already trusted this key for this
  plugin name.
- **Known v1 gap, accepted for the window.** The signature covers only the
  map that the manifest evaluates to. A manifest with side effects before
  that map would still pass check 3. Checks 1 and 2 limit this to
  packages the trusted first-party owner published on hexpm, and that
  owner already runs code at compile time. v2 closes the gap for good.

## Consequences

- Apps using first-party plugins from Hex keep building on the mob_dev
  release cut from master. Verified against scanner_sample
  (mob_scanner 0.1.3 + mob_camera 0.1.8): this branch's
  `SignatureGate.check_activated(MobDev.Plugin.activated())` returns `:ok`
  and prints two notices. origin/master returns
  `{:error, [envelope_v1_unsupported: :mob_camera, envelope_v1_unsupported: :mob_scanner]}`.
- A v1 plugin used as a path or git dep (including a path override into
  `deps/`), from a private repo, or with an
  untrusted key is still refused, with an error that states the rule. The
  fix is to re-sign it as v2.
- `activated/0` runs several times per build, so each accepted v1 manifest
  is evaluated several times per build. That was already true before
  MOB-74. The notice is printed from the gate hook, so it appears once
  per build.

## Removal

Remove this once every first-party plugin has been republished with a v2
envelope (signed in CI by a mob_dev that includes MOB-74) and those
versions are the ones the generator and the sample apps pin. Removal steps:

1. Delete `lib/mob_dev/plugin/v1_transition.ex` and its test and fixture
   (`test/mob_dev/plugin/v1_transition_test.exs`,
   `test/fixtures/plugins/mob_scanner_v1/`).
2. In `Verify.load_verified/2`, drop the `:envelope_v1_unsupported` clause.
   In `SignatureGate`, drop `maybe_print_v1_transition_notice/2`, the
   `v1_opts` argument, and the `accepted?/3` branch. Remove the notice call
   from `Validator.raise_on_capability_drift!/1`.
3. Restore the unconditional refusal text in `SignatureGate.format_error/1`.
4. Mark this record superseded, and remove the transition note from the
   MOB-74 record.

## Removed (2026-09-30, MOB-301)

Every first-party plugin now has a v2-signed release (mob_deliver 0.2.1
was the last), so the transition was removed in mob_dev 0.7.6. Steps 1–3
above were followed with two differences:

- The `test/fixtures/plugins/mob_scanner_v1/` fixture stays. It is the
  published v1 plugin that met every transition condition, and
  `test/mob_dev/plugin/v1_envelope_refused_test.exs` uses it to prove such a
  plugin is now refused without evaluating its manifest.
- The refusal text is not the pre-MOB-287 one. It tells the user to
  `mix deps.update <plugin>` to a v2-signed release, because the user who
  hits it is a consumer on an old lock, not the plugin author.

Apps locked to plugin releases signed before 2026-09-30 (e.g. mob_deliver
≤ 0.2.0) fail the build with `:envelope_v1_unsupported` until they update.
The text above is left as written; it records what the transition was.
