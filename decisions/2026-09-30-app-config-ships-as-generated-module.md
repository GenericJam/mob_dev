# Application config ships to the device as a generated `mob_app_config` module

- Date: 2026-09-30
- Status: accepted
- Related: mob 0.9.6 (`Mob.App.start/0` applies it), mob_deliver hello-world QA run (P2)

## Context

A Mob app boots from `-eval '<app>:start().'`, not an OTP release. Nothing
reads `config/*.exs` on the device, so `Application.get_env/3` returned nil
for everything except `compile_env` values. mob_deliver's `:endpoint`, `:app`
and `:channel` were nil on the device, and the app had to work around it.
Every existing app owns its `src/<app>.erl`, so a template change alone
would fix new apps and leave every existing one broken.

## Decision

1. mob_dev evaluates the config on the host with `Config.Reader`:
   `config/config.exs` for the build's `Mix.env()` and `Mix.target()`,
   merged with `config/runtime.exs` when present, minus `:mob_dev`.
2. It compiles the result into an Erlang module, `mob_app_config`, whose
   `config/0` returns `[{app, [{key, value}]}]`. The term is embedded with
   `:erlang.term_to_binary/2` and decoded by `config/0`, not turned into
   literals. A key whose value holds a local fun, pid, port or reference is
   dropped with a warning, because it can't mean anything on another VM.
3. The BEAM is written into the app's own compile path, next to `<app>.beam`.
   Every path that ships the app's BEAMs already copies that directory, so the
   hook is where those paths collect it (`HotPush`'s compile path, the iOS
   `copy_app_beams/2`, the iOS release script) rather than one per platform.
   The file is rewritten only when its bytes change.
4. mob's `Mob.App.start/0` applies it with
   `Application.put_all_env(config, persistent: true)` before anything else.
   A missing module (older mob_dev, host tests) is a no-op.

## Consequences

- `runtime.exs` runs on the developer's Mac at build time. `System.get_env/1`
  there reads the host environment, not the phone's. This is documented in
  `MobDev.AppConfig` and the README. It is the only place runtime.exs can run,
  since the device has no Mix and no release boot.
- A config change reaches a running app at its next start. A hot push loads
  the new module but doesn't re-apply it.
- The module sits on the host code path under `_build/<env>`, and
  `compile.app` lists it in `<app>.app`. Both are harmless: nothing on the
  host calls it except `Mob.App.start/0`, which only a device runs.

## Rejected

- **`Macro.escape` into an Elixir module.** Large or unusual terms make
  literal embedding fragile, and a generated Elixir module would need the
  Elixir compiler in the loop for no gain.
- **Pushing `sys.config` / config files and reading them on device.** The
  device has no `Config.Reader` step at boot, and file locations differ per
  platform (Android files dir, iOS bundle or Documents override). A module
  rides the existing BEAM transport on every platform.
- **Fixing it in the `mob_new` template.** It would leave every existing app
  broken, because apps own their bootstrap.
