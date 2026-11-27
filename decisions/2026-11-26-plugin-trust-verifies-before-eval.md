# `mix mob.plugin.trust` verifies the signature before evaluating the manifest

- Date: 2026-11-26
- Status: accepted
- Linear: MOB-550
- Amends: [2026-09-11-plugin-envelope-v2-verify-before-eval.md](2026-09-11-plugin-envelope-v2-verify-before-eval.md) ("Author-side paths still eval before verify"); [2026-09-30-plugin-signature-coverage.md](2026-09-30-plugin-signature-coverage.md) ("Evaluation order")

## Context

`mix mob.plugin.trust <name>` read a dependency's `priv/mob_plugin.exs` with
`Manifest.load/1` to show its capabilities, and never checked the plugin's
signature. The 2026-09-11 record listed it with the author-side tasks that
evaluate before verifying, reasoning that trust is "the first-trust decision by
definition". That grouping was wrong: the author-side tasks evaluate the
author's own manifest, while trust evaluates a dependency's manifest on the
consumer's machine. `MOB_PLUGIN_SECURITY.md` says a tampered manifest is never
run, and this task contradicted it.

## Decision

1. Trust reads the manifest through `Verify.load_verified/1`, the same path
   the build uses. The v2 envelope is checked first (envelope, public key,
   on-disk file hashes, signature); the manifest is evaluated only after that
   succeeds. The review shows the fingerprint and the capabilities from that
   verified manifest.
2. A plugin with no signature, a signature that does not verify, or a legacy
   v1 envelope is refused with a message naming the remedy, and `mob.exs` is
   not touched. `acknowledged_unsafe` is not passed: trust records a key
   fingerprint, so an unsigned plugin has nothing to trust. Unsigned plugins
   are used through `config :mob, :acknowledge_unsafe_plugins`, as before. A
   plugin missing both its key and its signature is unsigned and gets that
   remedy, not the "generate a key" one.
3. `Verify` requires a present `priv/mob_plugin.exs` to be one of the signed
   files, and refuses with `:invalid_signature` before anything evaluates it
   (including the build-input coverage check, which evaluates the manifest).
   Rehashing covers only the files an envelope lists, so a validly signed
   envelope that left the manifest out would otherwise have let its bytes
   through unverified. Every `mix mob.plugin.sign` since v2 lists it, so no
   genuine signature is affected. This applies to every caller of `Verify`,
   not just trust.
4. Which remedy a refusal names depends on whether the plugin is a path
   dependency: one outside `Mix.Project.deps_path/0`, not outside
   `<project>/deps`, so an umbrella child's deps and a moved `deps_path:` /
   `MIX_DEPS_PATH` are still Hex/git dependencies.

Signature verification here proves the files the envelope lists, the
manifest among them, are the ones the holder of the shipped key signed. It
does not prove who holds the key; the fingerprint shown in the review, which
the user confirms, is what decides that, exactly as before.

## Audit of the other host-side manifest evaluations

Every other host-side caller reads a dependency's manifest through
`Verify.load_verified/2`: `MobDev.Plugin.load_activated/3`,
`MobDev.Plugin.NifActivation.dep_manifests/0` and
`Mix.Tasks.Mob.Plugins.load_manifests/2` pass `acknowledged_unsafe: true` only
for plugins listed in `:acknowledge_unsafe_plugins`, and `MobDev.Plugin.Report`
and `mix mob.audit_plugins` pass no options. The only unverified evaluation is
therefore an unsigned (`:missing_signature`) plugin the user has explicitly
acknowledged. `mix mob.plugin.sign`, `mix mob.plugin.keygen` and
`mix mob.validate_plugin` evaluate the manifest of the plugin in the current
directory (or `--plugin`), which is the author's own.

Not covered by plugin signing: `MobDev.Style.load/1` evaluates an activated
style package's `priv/mob_style.exs`. Style packages have no signature scheme;
they are a separate lane (`MOB_STYLES.md`) and outside this change.

## Consequences

- An unsigned, tampered or v1-signed plugin can no longer be trusted with this
  task. Trusting an unsigned plugin never got it past the build's signature
  gate (a missing signature is refused unless acknowledged, whatever is
  trusted); the task now says so and points at `:acknowledge_unsafe_plugins`.
- A verified manifest that fails to evaluate is reported as before
  ("could not load manifest").
