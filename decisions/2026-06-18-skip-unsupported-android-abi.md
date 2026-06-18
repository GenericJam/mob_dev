# Skip Android ABIs the app's build.zig can't compile

- Date: 2026-06-18
- Status: accepted

## Context

`native_build.ex` builds three Android ABIs (arm64-v8a, armeabi-v7a, x86_64)
unconditionally; x86_64 was added in 0.6.4. But the per-app `build.zig` is
app-owned (copied at `mix mob.new` time), and apps generated before mob_new
0.4.5 only handle arm64-v8a + armeabi-v7a — they exit 1 with
`unsupported -Dabi=x86_64`.

The ABI loop `reduce_while`'d with `{:halt, {:error, …}}` on any failure, so a
single unsupported ABI failed the **entire** native build. Worse, that abort
happened before the `io.mob.plugin.MobPluginBootstrap` regeneration step, so the
generated bootstrap went missing and the next `gradle bundleRelease` failed on
an unresolved `MobPluginBootstrap` — a confusing second-order symptom. This bit
the Io (livebook_mob) 16 KB-page reship.

## Decision

Pre-flight each ABI against the app's build.zig and skip the ones it doesn't
declare, with a warning. `build_zig_supports_abi?/2` (pure, `@doc false` for
testing) checks for the ABI as a quoted string literal — every handled ABI
appears in the build.zig's `abi_to_target` / `ndk_arch_triple` switches.

## Consequences

- Apps with an older build.zig build cleanly for the ABIs they support; the
  plugin bootstrap regen always runs. gradle `abiFilters` already excludes the
  skipped ABI from the AAB, so nothing is lost.
- A real build failure of a **supported** ABI still halts (the predicate gates
  the *attempt*, not the result) — we don't mask genuine errors.
- The proper long-term fix is for apps to regenerate their `build.zig` from
  mob_new ≥ 0.4.5 (full x86_64 support); this just stops the default ABI set
  from being a hard wall in the meantime.
- String-literal detection is intentionally simple; it can't be fooled into a
  false positive that matters (if the ABI string is present, the switch handles
  it; the build then succeeds or fails on its own merits).
