# Keep the :compiler OTP app in the slimmed device runtime

- Date: 2026-05-25
- Status: accepted

## Context
The iOS release slim-strip drops unused OTP apps to shrink the bundle, and
`compiler-*` looks unused at runtime — nothing the app calls references it
directly. But Ecto.Migrator compiles `.exs` migration files at runtime via
`Code.compile_file/1`, which needs the `:compiler` OTP app. Any app that runs
migrations on boot (the common Mob + ecto_sqlite3 pattern) depends on it.

Stripping it surfaced as `{:badmatch, {:error, :enoent, :"compiler.app"}}` deep
in `:application_controller` during boot — the BEAM never reached
`Mob.Screen.start_root`, so the app hung on the splash with no obvious cause.

## Decision
Remove `compiler` from the slim-strip prefix list in `release.ex`; keep it in
the device runtime.

## Consequences
- A few MB larger bundle, in exchange for apps that run runtime migrations
  actually booting.
- Documented inline at the strip list so it isn't "re-optimized" away later.
- Apps that don't compile code at runtime carry compiler unnecessarily — minor,
  and not worth a per-app flag for the size saved.
