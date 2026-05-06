# scripts/release/openssl

Per-target OpenSSL cross-compile for the four pre-built OTP runtime
tarballs. Each script writes `libcrypto.a` + `libssl.a` to a target
prefix; the OTP cross-compile then links those statically into the
crypto NIF (`crypto.a`) which gets bundled in the tarball at
`erts-VSN/lib/crypto.a` alongside `erts-VSN/lib/libcrypto.a`.

See [`crypto_plan.md`](../../../../mob/crypto_plan.md) for the design,
[`build_release.md`](../../build_release.md) §3b for where these slot
into the OTP cross-compile flow, and `mob/common_fixes.md` for the
gotchas (BSD `ar`'s empty-archive trap, Android `RTLD_LOCAL`).

## Files

| Script | Target | Output prefix |
|---|---|---|
| `android_arm64.sh` | aarch64 Android | `/tmp/openssl-android-arm64` |
| `android_arm32.sh` | armv7a Android | `/tmp/openssl-android-arm32` |
| `ios_sim.sh` | aarch64 iOS Simulator | `/tmp/openssl-ios-sim` |
| `ios_device.sh` | aarch64 iOS Device | `/tmp/openssl-ios-device` |
| `build_crypto_static_android_arm64.sh` | (helper, only used in dev when patching crypto.a outside an OTP rebuild) | `lib/crypto/priv/lib/<arch>/libcrypto_nif.a` |

## Source

OpenSSL 3.4.0, cloned shallow at `~/code/openssl`:

```bash
git clone --depth 1 --branch openssl-3.4.0 https://github.com/openssl/openssl.git ~/code/openssl
```

Pinning to 3.4.0 (not 3.5.x) for now because 3.4 is the latest stable
LTS. Bump after running each script clean against a newer tag and
verifying tarball boots end-to-end.

## Configure flags (all targets)

```
no-shared      # Build only static libs (no .so/.dylib)
no-tests       # Skip the test suite
no-apps        # Skip the openssl(1) binary — we don't ship it
no-engine      # No dynamic engine API; OpenSSL 3 providers replace it
```

## NDK / SDK pins

- Android: NDK `27.2.12479018`, API 24 minimum (`-D__ANDROID_API__=24`)
- iOS: Xcode's bundled `xcrun` toolchains, deployment target 17.0

If the host machine has different NDK / Xcode versions installed, set
`ANDROID_NDK_ROOT` env var to override the default.

## Verifying a built archive

```bash
# Architecture sanity:
file /tmp/openssl-android-arm64/lib/libcrypto.a
# → "current ar archive" (the wrapper); extract one .o to confirm:
$NDK/llvm-ar x /tmp/openssl-android-arm64/lib/libcrypto.a libcrypto-lib-evp_pkey.o
file libcrypto-lib-evp_pkey.o
# → ELF 64-bit LSB relocatable, ARM aarch64

# x25519 symbols present (peer_net needs them):
$NDK/llvm-nm /tmp/openssl-android-arm64/lib/libcrypto.a | grep -i x25519
# → ossl_x25519, ossl_x25519_public_from_private, etc.
```
