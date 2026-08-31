# Android component factory generation is explicit

- Date: 2026-08-31
- Status: accepted

## Context

MobDev 0.6.31 treated `ui_components.android.composable` as a callable Kotlin
symbol. Existing plugins and MobDev's own tier-2 scaffold use that field as the
native-view registry key. Some plugins register their factories from
`android.bridge_class`, including factories that depend on the native event
sender. The generated 0.6.31 registration therefore either failed to compile
or overwrote a working bridge-owned factory with one that discarded events.

## Decision

`android.composable` retains its established registry-key meaning. A component
opts into generated registration with a separate `android.factory` Kotlin
function. The function accepts `(props, send)`; generated code forwards both
arguments. A bare function name is qualified with the package of
`android.bridge_class`, while a fully-qualified name needs no bridge.

Generated factories are installed before bridge `register()` and activity
handoff. A bridge that registers the same key therefore remains authoritative.
Components without `android.factory` receive no generated registration and
continue using their existing bridge- or host-owned path.

## Consequences

- Existing manifests and eventful bridge registrations work unchanged.
- Automatic registration is deliberate and has one event-capable signature.
- Plugins adopting automatic registration may ignore `send` in their Kotlin
  function, but the function must accept it.
- MobDev 0.6.31 should be skipped in favor of the containing patch release.
