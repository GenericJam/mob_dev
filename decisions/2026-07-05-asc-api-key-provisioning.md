# App Store Connect API key for headless provisioning

- Date: 2026-07-05
- Status: accepted

## Context

`mix mob.provision` authenticates `xcodebuild -allowProvisioningUpdates` against
Apple using the **signed-in Xcode Apple ID account** (Xcode → Settings →
Accounts). That account is per-macOS-user and only settable through Xcode's GUI,
so an unattended user — a CI runner, or an isolated headless *agent* account with
no GUI login — can register the signing identity but cannot provision (create /
refresh profiles, register devices). The cert + private key path already works
headlessly (a keychain the codesign step can read); only the Apple-contact step
was gated on the interactive account.

## Decision

Support an **App Store Connect API key** (`.p8`) as an alternative auth path for
the `xcodebuild -allowProvisioningUpdates` call, selected via three env vars:

- `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_PATH`

`asc_auth_args/1` (pure, `@doc false`, tested) maps them to xcodebuild's
`-authenticationKeyID` / `-authenticationKeyIssuerID` / `-authenticationKeyPath`.

- **Env vars, not a flag or mob.exs.** The key is a secret + machine-specific; env
  keeps it out of args history and out of the repo, and is the natural fit for a
  headless account's shell/launchd environment (and standard CI practice).
- **All three or none; partial raises.** A half-set key silently falling back to
  account auth would be a confusing "why is it still asking for Xcode?" — so a
  partial set is surfaced as an error naming what's missing.
- **Scoped to `mob.provision` only.** The native device build signs directly with
  `codesign` + an existing profile (no `-allowProvisioningUpdates`), so it needs
  only the keychain + profile, not the API key. Nothing else to thread it through.
- **Early `.p8` existence check** — clearer than an opaque xcodebuild failure.

## Consequences

- Unattended users provision by exporting the signing identity into an unlocked
  keychain + setting the three env vars — no Xcode GUI account. Interactive users
  are unaffected (none set ⇒ prior account-based behavior).
- The API key must have a role that can manage certificates/profiles/devices
  (Admin or App Manager). Signing still requires the cert + private key in an
  unlocked keychain — the key only authorizes the Apple-contact step.
- Follow-up: the runtime console preamble still prints "Xcode signed in" as step
  2; could branch on the env vars to show the API-key path instead (cosmetic).
