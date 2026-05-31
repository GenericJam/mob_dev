# Verify: intern envelope atoms so the :safe sig decode is deterministic

- Date: 2026-05-31
- Status: accepted

## Context

The build-time signature gate (`SignatureGate` → `Verify.verify_plugin/2`)
intermittently reported validly-signed plugins as `:invalid_signature`. The
same plugin, same files on disk, same code would verify `:ok` in one Mix
invocation and fail in the next. It was reproducible per-process: a script that
only called `Verify.load_signature/1` failed 100% of the time, while one that
also called `Sign.*` succeeded 100% of the time.

Root cause: `Verify.load_signature/1` decodes `priv/mob_plugin.sig` with
`:erlang.binary_to_term(bytes, [:safe])`. The `:safe` flag refuses to *create*
atoms, so every atom in the encoded term must already exist in the runtime atom
table or the decode raises `badarg` (rescued → `:corrupt` → surfaced by the
gate as `:invalid_signature`). The signed envelope is
`%{signature: <64 bytes>, envelope_version: 1}`. `Verify` matched only
`%{signature: sig}`, so it interned `:signature` at load but never
`:envelope_version` — the sole interner of that atom was `Sign`. Because
`verify_plugin/2` calls `load_signature/1` *before* it touches `Sign`, the
decode's success depended on whether `Sign` had been loaded earlier in that
BEAM for unrelated reasons. Load order varies between builds → intermittent
rejection.

`:safe` is the correct choice here: signature files are attacker-controlled
(the thing being verified), and `:safe` blocks atom-table-exhaustion and
unsafe-term decode bombs. So the fix must keep `:safe`, not drop it.

## Decision

Intern the envelope's atom keys at `Verify`-load time. A module-level literal
`@envelope_atoms [:signature, :envelope_version]` (referenced from
`decode_envelope_term!/1` and exposed via `envelope_atoms/0`) embeds those
atoms in `Verify`'s compiled atom chunk, so they are guaranteed present the
moment `Verify` is loaded — which is necessarily before any call to
`load_signature/1`. The `:safe` decode is retained.

## Consequences

- The signature gate is now deterministic regardless of module-load order; both
  `mob_bluetooth` and `mob_demo_signature_pad` verify `:ok` on the trust path
  with no `:acknowledge_unsafe_plugins` entry (confirmed across cold VMs).
- Any future field added to the signed envelope (in `Sign.build_payload/2` or
  the envelope map in `sign_plugin/2`) whose key is an atom must also be added
  to `@envelope_atoms`, or the same intermittent-decode bug returns for terms
  that include it. The `verify_test.exs` guard pins the current set.
- True cold-VM reproduction is cross-process (atoms can't be un-interned in a
  live VM), so the regression test guards the fix's mechanism in-process
  (`envelope_atoms/0` membership + a decode that includes `:envelope_version`)
  rather than re-triggering the original failure.
