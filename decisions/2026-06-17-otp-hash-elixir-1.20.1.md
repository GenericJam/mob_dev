# OTP runtime hash bump to Elixir 1.20.1 (new hash, not clobber)

- Date: 2026-06-17
- Status: accepted

## Context

Io (livebook_mob) needed to move from Elixir 1.20.0-rc.5 to 1.20.1. The bundled
Elixir stdlib lives inside the pre-built OTP tarballs that `OtpDownloader`
fetches (named by `@otp_hash`), so moving an app to 1.20.1 means the published
tarballs must carry 1.20.1 — the local cache stdlib-swap that proves it works on
a device is not reproducible (a clean machine pulls the published rc.5).

The active hash `7d46fdd4` is shared by every app on the current mob_dev
(air_cart_max, code_to_cloud, sloppy_joe, …). Clobbering its tarballs with
1.20.1 would silently change the Elixir under all of them.

## Decision

Publish a **new** OTP release `otp-5c9c69fc` (5 tarballs, same OTP-29/erts-17.0/
OpenSSL base, Elixir stdlib swapped rc.5 → 1.20.1) rather than clobbering
`7d46fdd4`. Flip `@otp_hash` + `bundled_versions.exs` `active_hash` to
`5c9c69fc`; keep the `7d46fdd4` manifest entry for provenance.

The new hash is deterministic, derived from the content
(`shasum` of "elixir-1.20.1-otp-29-base-7d46fdd4"), not an OTP git commit — the
OTP source didn't change, only the bundled Elixir.

## Consequences

- Updating to 1.20.1 is **opt-in per app**: only apps that `mix deps.update
  mob_dev` to ≥0.6.5 get the new runtime. Apps pinned to older mob_dev keep
  `7d46fdd4` (rc.5) untouched — no silent skew.
- The tarballs were rebuilt from **pristine** downloads of the published
  `7d46fdd4` assets (extract → swap stdlib → re-tar), NOT from local caches,
  which had been polluted by dev `--native` builds (e.g. a built-in
  `sqlite3_nif.a`, crypto-shim writes). Always repack from the published asset.
- `security_scan` verified the new caches fingerprint clean against the manifest
  (ERTS 17.0, Elixir 1.20.1, OpenSSL 3.4.0). Remove any locally stdlib-swapped
  `7d46fdd4` caches afterward or they read as DRIFT vs the rc.5 manifest entry.
- Tarball repack is a stdlib swap, not an OTP rebuild — no `~/code/otp` /
  xcompile needed. The `bundle_elixir_stdlib` set (elixir/logger/eex) is exactly
  what changes between Elixir patch versions on the same erts.
