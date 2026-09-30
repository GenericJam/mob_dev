# mob_dev writes machine paths to mob.local.exs and keeps its import last
- Date: 2026-09-30
- Status: accepted

## Context
MOB-286: `mob.exs` holds project config — `config :mob, :plugins`
(activation), `:trusted_plugins`, `:styles` — but generated projects
gitignored it, so a clone activated no plugins and hit `:nif_not_loaded` at
runtime. mob_new now commits `mob.exs` with portable defaults and ends it with

    if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")

(mob_new `decisions/2026-09-30-commit-mob-exs-local-overrides.md`).
mob_dev had three writers working against that:

- `mix mob.install` rewrote the *whole* `mob.exs` as
  `config :mob_dev, mob_dir: <abs>` whenever `mob_dir` was missing or a
  `/path/to/` placeholder — dropping `:plugins`/`:trusted_plugins`/`:styles`
  and putting a machine path in a committed file.
- `mix mob.adopt.mob_exs` gitignored `mob.exs`, and with `--local` baked
  absolute `mob_dir`/`elixir_lib` into it.
- `mob.plugin.trust`, `mob.deploy --beam-flags` and `mob.enable liveview`
  append stanzas to the end of `mob.exs`, i.e. after the import.

## Decision
- `mob.install` writes prompted paths to `mob.local.exs` via
  `MobDev.MobExs.put_local_config/2`: created with the same header mob_new
  uses, or — if it exists — extended with a later `config :mob_dev, ...`
  call so every other setting in it survives. `mob.exs` is only touched to
  append the import line when missing (or created holding just that).
  `.gitignore` gains a `mob.local.exs` entry if it lacks one, because
  projects from before this change ignore only `mob.exs` and would otherwise
  leave the machine paths committable. An old `mob.exs` entry is left alone.
- `mob.adopt.mob_exs` writes mob_new's portable LiveView `mob.exs`
  (identical text), gitignores `mob.local.exs` instead of `mob.exs`, and
  under `--local` writes the checkout `mob_dir` to `mob.local.exs`.
  `elixir_lib` is no longer pinned: the portable default resolves the running
  Elixir at read time. An existing `mob.exs` only gains the import line.
- Writers that add a stanza to `mob.exs` insert it **above** the import
  (`MobDev.MobExs.insert_config/2`), keeping "mob.local.exs is imported
  last, so its values win" true. Config deep-merges keyword values but
  replaces maps and plain lists, so a stanza below the import would silently
  beat a local `:styles`/`:trusted_plugins`/etc. `mob.add_nif` goes through
  Igniter's `modify_config_code`, which edits the existing `config :mob_dev`
  call in place or adds one right after `import Config`, so it already lands
  above the import.
- The existing import is found by parsing `mob.exs` and walking each
  top-level statement for `import_config "mob.local.exs"` — parens or not,
  bare or under an `if` (one-line or `do`/`end`). A text match on the
  generated line missed hand-written forms: `ensure_local_import/1` then
  added a second import, which makes `Config.Reader` raise ("attempting to
  load configuration ... recursively"), and `insert_config/2` appended below
  an unconditional import. A file that doesn't parse counts as having no
  import.

Rejected: appending after the import so a freshly saved value "takes
effect". That makes the committed file override machine-local values for
whichever keys a tool happened to touch — a precedence rule nobody can
predict from reading either file.

## Consequences
- A key set in both files resolves to `mob.local.exs`. If a user keeps
  `beam_flags` in `mob.local.exs`, `mix mob.deploy --beam-flags` saves the
  new value to `mob.exs` and the local one still wins on the next deploy.
- `TrustStore` reads the merged view and writes `mob.exs`. With a
  `:trusted_plugins` map in `mob.local.exs`, that map replaces the committed
  one wholesale, so `mix mob.plugin.trust` additions are shadowed. Trust is
  project config; keep it in `mob.exs`.
- Projects adopted before this change keep `mob.exs` in `.gitignore`;
  re-running `mix mob.adopt.mob_exs` adds `mob.local.exs` but does not remove
  the old entry. Un-ignore and commit `mob.exs` by hand.
- mob_dev versions before this change still append after the import, so
  their `--beam-flags`/trust/`liveview_port` writes override
  `mob.local.exs` for those keys.
