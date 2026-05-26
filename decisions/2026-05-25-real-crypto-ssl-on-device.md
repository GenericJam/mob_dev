# Ship real OpenSSL crypto + ssl on device, not md5/no-op shims

- Date: 2026-05-25
- Status: accepted

## Context
Early device OTP runtimes were built `--without-ssl`, so the release scripts
compiled stand-in `:crypto` and `:ssl` modules into the app beam dir: an
md5-only crypto (`supports/1 -> []`, fake `generate_key`/`sign`) and an ssl
that only exported `start`/`stop`. They existed purely so
`ensure_all_started/1` wouldn't fail for HTTP-only loopback Phoenix.

Those shims make real TLS impossible. On the Code-To-Cloud orchestra app the
phone fetches stems and streams SSE from `https://c0.boltbrain.ca`, so it needs
working TLS. With the shims, iOS hit `:ssl.versions/0 undefined` (the shim
lacks it) and Android's stubbed `crypto.supports/1 -> []` made `:ssl.versions/0`
raise — every HTTPS connect crashed. Meanwhile the current OTP tarballs *do*
ship real `crypto-5.9` + `ssl-11.7`, and the native builds already link the
OpenSSL static archive (`crypto.a` + `libcrypto.a`) and register the crypto NIF.

## Decision
Use the real beams. Android (`release_android.ex`) gates on
`real_crypto_available?/1` — only stub when the runtime genuinely has no
`crypto.a`; otherwise keep the OpenSSL crypto. iOS (`release.ex`) stops
compiling the shim crypto/ssl into `BEAMS_DIR` (they shadowed the real
`lib/{crypto,ssl}-*/ebin` on the prepended `-pa` path), and links
`crypto.a`/`libcrypto.a` so the NIF resolves.

## Consequences
- Real `verify_peer` TLS works on device; orchestra SSE + stem download connect.
- The shims are gone; `supports/1` returns real algorithms, `:ssl.versions/0`
  works.
- Hard dependency: the device OTP tarball must ship `crypto.a` and the real
  `crypto`/`ssl` beams. If a future `--without-ssl` tarball reappears,
  `real_crypto_available?/1` falls back to the Android stub; iOS would need the
  shim path restored.
- Apps that only need loopback HTTP are unaffected (the real beams still load).
