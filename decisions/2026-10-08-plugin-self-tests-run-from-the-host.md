# Plugin self-tests run from the host: `mix mob.selftest` and `MobDev.Plugin.SelfTest.run_all/3`

- Date: 2026-10-08
- Status: accepted
- Linear: MOB-411 (epic MOB-410); the contract is mob's
  `decisions/2026-10-08-plugin-self-test-contract.md`

## Context

- mob 0.9.15 gives plugins a behaviour, `Mob.Plugin.SelfTest`, with one
  callback `run(ctx) :: :pass | {:fail, reason} | {:skip, reason}`, named in
  the manifest as `selftest: Module`. The rule for a pass is a real answer
  from the plugin's native code.
- Something has to validate the key, call the tests on a device and judge
  the answers. mob_dev already owns manifest validation, device discovery
  and attaching to a running app over distribution (`mix mob.smoke`,
  `mix mob.attest`), and mob_ci calls into mob_dev for builds and the
  static gate, so the runner belongs here and mob_ci calls it (invariant
  P12).
- A self-test is plugin code running inside the app: it can raise, exit,
  hang, or return `:ok` because its author misread the contract. None of
  that may take the runner, or the other plugins' runs, down.

## Decision

- **`selftest` is a manifest key.** `MobDev.Plugin.Manifest` requires an
  Elixir module; when the module is loadable at validation time (the
  plugin is compiled: `mix mob.validate_plugin` after a compile, or a host
  activating a dep) it must export `run/1`, otherwise only the name is
  checked. A manifest without the key gets a **warning** from
  `mix mob.validate_plugin` (`missing selftest`) in 0.7.17; it becomes an
  error in a later release once the first-party plugins carry theirs
  (MOB-418). Warning first because every published plugin would otherwise
  stop validating the day this ships.
- **`run_all(node, ctx, opts)` is the runner.** One `:erpc.call/5` per
  plugin, sequential (self-tests may touch shared hardware), each with its
  own timeout (`:timeout_ms`, 30 s). Every way a remote `run/1` can go
  wrong is caught on the host and becomes that plugin's `{:fail, why}`:
  `error:{erpc, timeout}`, `{exception, Reason, Stack}` (raise; `:undef`
  for a module the running build does not have, named as such),
  `exit:{exception, _}` and `{signal, _}`, `throw`, and a return outside
  the contract. The contract's three shapes are restated in the runner
  rather than calling `Mob.Plugin.SelfTest.result?/1`, so mob_dev does not
  need mob at runtime and the runner works against an app built with an
  older mob. Plugins with no `selftest:` (or no manifest) are entries with
  `module: nil` and a `{:skip, _}`: a plugin without a test is visible in
  every table, not silently absent.
- **Permissions are pre-granted where the host can.** `grant_permissions/4`
  runs `adb shell pm grant` for each `android.permissions` entry (only
  runtime permissions are grantable; a normal one answers with an error
  that is recorded, not raised) and `xcrun simctl privacy grant` for each
  `permissions: [%{capability: _}]` whose capability has a simctl service
  (location, microphone, photos, media, contacts, calendar, reminders,
  motion). A physical iPhone gets nothing: there is no host-side grant.
  `run_all/3` grants when given `:device` (mob_ci's path); `mix mob.selftest`
  grants **before** it relaunches the app, because `simctl privacy` warns
  that some changes terminate a running app, and a self-test must not meet
  a system prompt.
- **`mix mob.selftest` selects devices like `mix mob.connect`** (`--device`
  / `--only`, `--ios-only`, `--android-only`, `--cookie`) and relaunches
  the app by default like it (`--no-restart` attaches as is). The context is
  the device record's platform and type, not something the plugin detects:
  a plugin deciding for itself that it is "on an emulator" is how a skip
  hides a hole. Exit status is non-zero on any `FAIL` or on a selected
  device whose node could not be reached (a test that could not run is not
  a test that passed, the same rule as `mix mob.attest`).
- **Scaffolds declare one.** `mix mob.new_plugin` tier 1 generates a
  `SelfTest` that calls the NIF's `ping/0`; tier 4 one that round-trips the
  supervised worker. Tiers 2 and 3 have no honest host-callable probe in
  the template and get the warning, which is the nudge intended.

## Consequences

- mob_ci replaces its `device_caps.exs` probe table with `run_all/3` once
  the plugins carry self-tests (MOB-414, MOB-418).
- The tests (`test/mob_dev/plugin/self_test_test.exs`) use this node as the
  device: `:erpc.call/5` to `node()` runs the fixture in a spawned local
  process, so the raise, exit, throw, timeout, undef and off-contract paths
  are exercised for real without a device.
- Turning the warning into an error is a one-line change in
  `Validator.selftest_review/1` plus moving it into the error list; record
  the release that does it here.
