# Publishing a Mob app to Google Play (Android)

This is the full, step-by-step recipe for taking a Mob app from "runs on
my Android device via `mix mob.deploy --native`" to "uploaded to Google
Play, available on the internal testing track."

It assumes you already have a working development setup — `mix mob.deploy`
runs your app on a connected Android device or emulator.

> **Status (mob 0.5.12 / mob_dev 0.3.33):** End-to-end works. A real
> Mob app (Air Cart Maximizer) shipped through this exact pipeline on
> 2026-05-05. If you follow the steps below in order you should land a
> build on the internal testing track on your first or second attempt.
>
> The one-time setup (Part 1) is the painful part — Google's console is
> spread across three separate portals and the terminology is inconsistent.
> The per-release flow (Part 2) is a single command: `mix mob.republish --android`.

## CLI wizard (recommended for first-time setup)

Most of the Google Cloud steps in Part 1 can be automated. Run this instead
of following sections 1.4.1–1.4.5 manually:

```bash
mix mob.setup.google_play
```

The wizard opens your browser for a one-time Google sign-in (no `gcloud`
CLI or external tools required — just a browser), then automatically:

- Lets you pick your Google Cloud project
- Enables the Android Publisher API
- Creates the `play-publisher` service account
- Generates a JSON key and saves it to `~/.google_play/`
- Attempts to grant Release Manager access via the Play Developer API
- Prints the `mob.exs` config block to add

**What the wizard cannot automate** (manual steps regardless of path):

1. Creating the Google Play Developer account ($25, browser only)
2. Identity verification (government ID upload)
3. Creating the app record in Play Console (no create-app API)
4. Linking the Cloud project to Play Console:
   Play Console → Setup → API access → Link to a Google Cloud project

The wizard walks you through these four steps with exact instructions.

> **Note:** The CLI wizard requires an OAuth client ID registered in Google
> Cloud Console. If the wizard reports `OAuth client not registered yet`, see
> the `MobDev.GooglePlay.OAuth` moduledoc for the one-time registration steps.

If you prefer to do everything manually, or need to debug a specific step,
continue with the browser-based instructions below (Part 1).

---

## Prerequisites

- A Mob Android project that runs via `mix mob.deploy --native`
- An Android device you've run the app on (proves your native build works)
- `android/upload_jks.keystore` + `android/keystore.properties` filled in.
  See [Setting up the upload keystore](#setting-up-the-upload-keystore) below.

You'll touch two Google portals during setup:

| Portal | URL | What lives here |
|---|---|---|
| Google Play Console | https://play.google.com/console | App listings, releases, testers, API access |
| Google Cloud Console | https://console.cloud.google.com | Service accounts, JSON keys |

These are separate products. Easy to confuse — the Play Console is where
you manage your apps and grant publishing permissions; Google Cloud is
where you create the service account credentials.

---

## Setting up the upload keystore

Every release AAB must be signed with an **upload keystore** — a private
key that Google uses to verify future updates come from you.

> **This key is forever.** If you lose it you cannot publish updates to
> your app. Back it up to 1Password or similar as soon as you create it.
> It must never be committed to git.

### Generate the keystore (one-time)

```bash
keytool -genkey -v \
  -keystore android/upload_jks.keystore \
  -alias upload \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storetype JKS
```

Use a strong passphrase. When prompted for your name, org, etc., fill in
something real (it goes into the certificate, which Google sees).

> **Format note:** Generate a JKS keystore, not PKCS12. Android's
> `bundletool` (the signing tool Gradle calls under the hood) rejects PKCS12
> keystores with a misleading "keystore password was incorrect" error even
> when the password is right. JKS avoids this entirely.
>
> If you already have a PKCS12 keystore (`upload.keystore`), convert it:
>
> ```bash
> keytool -importkeystore \
>   -srckeystore android/upload.keystore  -srcstoretype PKCS12 \
>   -destkeystore android/upload_jks.keystore -deststoretype JKS \
>   -srcalias upload -destalias upload
> ```

### Fill in `android/keystore.properties`

Copy from the example and fill in your passphrase:

```bash
cp android/keystore.properties.example android/keystore.properties
```

Edit `android/keystore.properties`:

```
storeFile=upload_jks.keystore
storePassword=your-passphrase
keyAlias=upload
keyPassword=your-passphrase
```

Both passwords are the same unless you explicitly set them differently
during `keytool -genkey`.

Both `android/upload_jks.keystore` and `android/keystore.properties` are
in `.gitignore` — confirm they stay there:

```bash
git check-ignore -v android/upload_jks.keystore android/keystore.properties
```

---

## Part 1 — One-time setup (per developer account + app)

### 1.1 Create a Google Play Developer account

Go to https://play.google.com/console and sign in with the Google account
you want to publish under.

You'll be asked to pay a **one-time $25 USD registration fee**. This is
per developer account, not per app.

> **ADC early access** — During registration or later, Google may show
> you the "Android Developer Console" at `get.google.com/adc-early-access`.
> This is a preview of a future replacement for the Play Console.
> **Ignore it** — you don't need it and it will not help you publish.
> Everything in this guide uses https://play.google.com/console.

### 1.2 Complete identity verification

Google now requires **identity verification** before your account can
publish apps. This is separate from the $25 fee and is free.

You'll be asked to submit:
- A government-issued ID (passport or driver's license), OR
- Business registration documents (if registering as an organization)

Submit via the prompts in the Play Console. Review typically takes a few
hours to one business day. You can't publish until verification clears.

### 1.3 Create the app record in Play Console

Once verified, you'll see the main developer dashboard at
https://play.google.com/console.

Click **Create app** and fill in:

| Field | Value |
|---|---|
| App name | Your public-facing name (e.g. `Air Cart Max`) |
| Default language | English (or your primary market) |
| App or game | App |
| Free or paid | Your choice |
| Declarations | Check both boxes |

Click **Create app**. This gives you an app record with a stable
package ID slot — you'll fill in the AAB and store listing separately.

### 1.4 Set up the Android API service account

> **CLI shortcut:** `mix mob.setup.google_play` automates all of section 1.4
> (except the Play Console link step in 1.4.1, which has no API).
> The manual steps below are the fallback if the wizard is unavailable or
> if you need to understand what's happening.

`mix mob.publish --android` uses the Google Play Developer API to upload
AABs without going through the browser. The API authenticates with a
**service account** — a non-human Google account that holds upload
credentials.

This involves steps in **both** the Play Console and Google Cloud Console.
Read the navigation notes carefully — it's easy to end up in the wrong
portal.

#### 1.4.1 Link a Google Cloud project (Play Console)

In **Play Console** (https://play.google.com/console):

1. Make sure you're at the **account level** — the main developer
   dashboard, not inside any specific app. If you see app-specific
   menus in the sidebar, click your developer account name at the top
   of the left nav to go back.
2. Left sidebar → **Setup** → **API access**
3. Click **Link to a Google Cloud project** → let Google create a new
   project (the auto-created project is fine), or link an existing one.

This one-time link is what allows service accounts in your Cloud project
to reach the Play API.

#### 1.4.2 Enable the Android Publisher API (Google Cloud Console)

Switch to **Google Cloud Console** (https://console.cloud.google.com):

1. Make sure the correct project is selected in the top dropdown
   (same project you linked in 1.4.1)
2. Left sidebar → **APIs & Services** → **Library**
3. Search for **Google Play Android Developer API** → click the result
4. Click **Enable**

> **Do this before creating the service account key.** If you skip it,
> `mix mob.publish --android` will fail with:
> `HTTP 403: Google Play Android Developer API has not been used in project …`
> Enabling the API and waiting ~2 minutes fixes it.

#### 1.4.3 Create a service account (Google Cloud Console)

Still in **Google Cloud Console** (https://console.cloud.google.com):

1. Make sure the correct project is selected in the top dropdown
   (the same project you linked in step 1.4.1)
2. Left sidebar → **IAM & Admin** → **Service Accounts**
3. Click **+ Create Service Account**
4. Fill in a name (e.g. `play-publisher`) — click **Create and continue**
5. **Skip the role assignment step** — click **Continue**, then **Done**

   > **Important:** Do NOT assign a Google Cloud IAM role here (like
   > "Cloud Deploy Releaser", "Resource Manager", "Editor", etc.).
   > Those are GCP infrastructure roles, not Play Console roles.
   > Play Console permissions are granted separately in step 1.4.4.

6. You'll land back on the service accounts list. Click your new
   service account → **Keys** tab → **Add key** → **Create new key** →
   **JSON** → **Create**
7. A `.json` file downloads automatically. **This is a one-time
   download** — Google does not store the private key. If you close
   the page without downloading, delete the key and create a new one.

Move the file into place:

```bash
mkdir -p ~/.google_play
mv ~/Downloads/*.json ~/.google_play/aircartmax-service-account.json
chmod 600 ~/.google_play/aircartmax-service-account.json
```

The service account email is inside the file — you'll need it in the
next step:

```bash
cat ~/.google_play/aircartmax-service-account.json | grep client_email
# "client_email": "play-publisher@your-project.iam.gserviceaccount.com"
```

#### 1.4.4 Grant the service account Play Console access

This requires **two separate actions** in Play Console — both are needed.

##### Part A — Grant access via API access page

In **Play Console** (https://play.google.com/console), account level:

1. Left sidebar → **Setup** → **API access**
2. Your service account appears in the list. Click **Grant access** next
   to it.
3. You'll be taken to a permission screen. Set role to **Release manager**.
4. Click **Apply** → **Invite user**

##### Part B — Invite via Users and permissions

Still in **Play Console**, account level:

1. Left sidebar → **Users and permissions**
2. Click **Invite new users**
3. **Email address**: paste the `client_email` from the JSON file
   (looks like `play-publisher@your-project.iam.gserviceaccount.com`)
4. Under **Permissions**, find **Release manager** role and select it.

   If you don't see named roles and instead see a permission checklist,
   enable at minimum:
   - **Release apps to testing tracks and production**
   - **Manage production releases**

   > **Do not select Google Cloud IAM roles** — if you see "Cloud Deploy
   > Releaser", "Resource Manager", or anything Cloud-prefixed, you're in
   > the wrong section. These are GCP infrastructure roles with no effect
   > on Play publishing.

5. Click **Apply** → **Invite user**

Both paths must be completed. Doing only one results in HTTP 403
"The caller does not have permission" when uploading. Service accounts
auto-accept invitations — permissions are active within a few minutes.

#### 1.4.5 Configure `mob.exs`

Add the Google Play config block to your `mob.exs`:

```elixir
import Config

config :mob_dev,
  # ... your existing config ...

  google_play: [
    package_name:         "com.example.myapp",          # your applicationId
    service_account_json: "~/.google_play/my-service-account.json",
    track:                "internal"                    # start here; promote later
  ]
```

`mob.exs` is per-machine and should be in your `.gitignore`. The JSON
key file should also never be committed.

The `track` field controls which Play track the AAB lands on:

| Track | Who can install | Review required |
|---|---|---|
| `"internal"` | Up to 100 testers you invite by email (must have a Play account) | None — instant |
| `"alpha"` | Closed group, any Google account | None |
| `"beta"` | Open or closed, any Google account | None |
| `"production"` | Everyone | Google review (typically 1–3 days) |

Start with `"internal"` and promote to `"production"` from the Play
Console web UI once you've verified the build works on real devices.

### 1.5 Configure Android target SDK

Google Play rejects AABs that don't target the current required SDK level.
As of 2026, that's **targetSdk 35**.

In `android/app/build.gradle`:

```gradle
android {
    compileSdk 35

    defaultConfig {
        targetSdk 35
        minSdk 28
        ...
    }
}
```

Keep `compileSdk` ≥ `targetSdk`. Update both together.

### 1.6 Set the application ID

The default `mix mob.new` scaffold uses `com.example.<app>` for
`applicationId`. You need to change this to a unique reverse-DNS
identifier under a domain you control. This is the permanent Play Store
package name — it cannot be changed after the first release.

In `android/app/build.gradle`:

```gradle
defaultConfig {
    applicationId "com.yourcompany.yourapp"
    ...
}
```

### 1.7 Set the app label

The `android:label` in `AndroidManifest.xml` is what users see as the
app name on their device. The scaffold default is a concatenated string
without spaces:

```xml
<application
    android:label="Air Cart Max"   <!-- spaces, human-readable -->
    ...>
```

---

## Part 2 — Per-release flow

Once Part 1 is done, every subsequent release is **one command**:

```bash
mix mob.republish --android
```

That runs the three steps below in sequence. Use the wrapper for the
common path; drop down to individual commands if you need to troubleshoot
one in isolation.

### 2.1 `mix mob.republish --android` (the wrapper)

What it does, exactly:

1. **Bump `versionCode`** — reads the current integer from
   `android/app/build.gradle`, bumps by 1, writes back. Google Play
   rejects AABs with a `versionCode` it has already seen for this app,
   even if the upload never succeeded.
2. **`mix mob.release --android`** — builds the OTP zip + signed AAB.
   See section 2.2.
3. **`mix mob.publish --android`** — uploads the AAB to Play. See
   section 2.3.

Flags:

- `--android` — required. Mob is platform-agnostic; you must pick a side.
- `--track internal|alpha|beta|production` — override the track from
  `mob.exs`. Useful for promoting a build: `mix mob.republish --android
  --track production`.
- `--no-bump` — skip the versionCode bump (only useful if you bumped
  manually and want to rebuild + re-upload without bumping again).

### 2.2 `mix mob.release --android` (manual equivalent of step 2)

Builds everything needed for a signed release AAB:

1. Compiles the Elixir project (`mix compile`)
2. Downloads the Android OTP runtime from the Mob release cache if not
   already present
3. Stages a temp tree: OTP runtime + app BEAMs (all runtime deps,
   flattened) + `priv/` + exqlite BEAMs in the OTP lib structure
4. Runs `MobDev.OtpAssetBundle.build/2`:
   - Strips unused OTP libs (megaco, runtime_tools, wx, observer, etc.)
   - Strips standalone executables from `erts-*/bin/` (the ones Mob
     actually needs — `erl_child_setup`, `inet_gethost`, `epmd` — are
     already in the APK's `jniLibs/` as `.so` files)
   - Strips static archives (`.a`) — already linked into the native lib
   - Strips optional BEAM chunks to shrink file size
   - Zips the tree to `android/app/src/main/assets/otp.zip`
5. Runs `./gradlew bundleRelease` to produce the signed `.aab`

Output: `android/app/build/outputs/bundle/release/app-release.aab`

> **Why does `otp.zip` matter?**
> `MobBridge.extractOtpIfNeeded()` in Kotlin extracts this zip into
> `<filesDir>/otp/` on first launch. This is how the BEAM runtime and
> your app's compiled code reach the device — Play Store installs can't
> `adb push` files the way development builds do. If `otp.zip` is absent,
> the app starts, finds no BEAM runtime to load, and crashes immediately.
> **Building via `./gradlew bundleRelease` directly (without first running
> `mix mob.release --android`) produces an AAB missing `otp.zip` — the
> app will crash on every device.**

### 2.3 `mix mob.publish --android` (manual equivalent of step 3)

Uploads the AAB at
`android/app/build/outputs/bundle/release/app-release.aab` to Google Play
via the Play Developer API.

You can also pass an explicit path:

```bash
mix mob.publish --android path/to/app-release.aab
```

Or override the track from `mob.exs`:

```bash
mix mob.publish --android --track production
```

The upload creates a Play **edit** (a transaction-style change), uploads
the bundle, assigns it to the track, and commits — all atomically. If
any step fails, the edit is abandoned and the Play Console is unchanged.

Successful output:

```
=== Uploading to Google Play ===
  AAB:          /path/to/app-release.aab
  Package:      com.example.myapp
  Track:        internal

  Authenticating with Google...
  Creating edit...
  Uploading 38.3MB...
  Assigning versionCode 3 to internal track...
  Committing edit...

✓ Upload accepted by Google Play
  versionCode 3 is on the internal track.

View it at:
  https://play.google.com/console
```

### 2.4 If the wrapper isn't working — the manual three-step

```bash
# 1. Bump versionCode (Play rejects re-uploads of the same versionCode).
#    Edit android/app/build.gradle: versionCode N → versionCode N+1

# 2. Build the release AAB (otp.zip + Gradle).
mix mob.release --android

# 3. Upload to Google Play.
mix mob.publish --android
```

Common recovery scenarios:

- **`mix mob.release --android` failed** — fix the error, then run
  `mix mob.release --android && mix mob.publish --android`. Don't bump
  again — the bump already happened.
- **`mix mob.publish --android` failed** — unlike Apple, Google's API
  uses an edit/commit model: if the upload fails before `commit`, the
  versionCode is NOT consumed. You can re-run `mix mob.publish --android`
  without bumping.
- **You bumped manually** — `mix mob.republish --android --no-bump` skips
  the bump step.

### 2.5 Add testers on the internal track

In the Play Console → your app → **Testing** → **Internal testing**:

1. Click **Testers** tab → **Create email list** (or use the default list)
2. Add tester email addresses
3. Each tester receives a link to opt in to the test
4. Once opted in, they install the app from the Play Store directly

Internal testing requires no review. The build is available immediately
after upload.

To promote to production, go to the Play Console → **Release** →
**Production** → **Create new release** → promote the internal testing
release.

---

## Troubleshooting

### "Your app currently targets API level 34 and must target at least API level 35"

Play Console rejects AABs with `targetSdk < 35` (as of 2026). Update
`android/app/build.gradle`:

```gradle
android {
    compileSdk 35
    defaultConfig {
        targetSdk 35
        ...
    }
}
```

### "Version code X has already been used"

Play rejects any AAB with a `versionCode` it's already seen for this app.
Bump the versionCode in `android/app/build.gradle` and rebuild:

```bash
# Manual bump:
# Edit android/app/build.gradle: versionCode N → versionCode N+1
mix mob.release --android
mix mob.publish --android

# Or let mob.republish handle it:
mix mob.republish --android
```

### App installed from Play Store crashes on launch — ERTS helpers not found (`inet_gethost : enoent`)

**Symptom**: App works fine when installed with `adb install` but crashes immediately
when installed from the Play Store (internal testing or production). Logcat shows
something like:

```
erl_child_setup: : no such file or directory
```

or the BEAM fails to start distribution with `inet_gethost : enoent`.

**Root cause**: Play Store delivers apps as split APKs (one per device ABI). On
Android 6+, the system does **not** extract `.so` files from split APKs to
`nativeLibraryDir` — they remain compressed inside the split APK zip file.

`mob_beam.c` creates symlinks from `erts-VER/bin/<name>` to
`<nativeLibraryDir>/lib<name>.so`. When installed from Play Store,
`nativeLibraryDir` is empty — all symlinks dangle and the BEAM's exec calls
fail with ENOENT.

**Fix**: This is handled automatically by `MobBridge.extractBeamHelpersFromSplitApk()`
(in the generated `MobBridge.kt`). On first launch, if `nativeLibraryDir` is empty,
it locates the ABI-specific split APK from `ApplicationInfo.splitSourceDirs`, opens
it as a zip, and extracts:
- `lib/<abi>/liberl_child_setup.so` → `<filesDir>/otp/erts-VER/bin/erl_child_setup`
- `lib/<abi>/libinet_gethost.so` → `<filesDir>/otp/erts-VER/bin/inet_gethost`
- `lib/<abi>/libepmd.so` → `<filesDir>/otp/erts-VER/bin/epmd`
- `lib/<abi>/libsqlite3_nif.so` → `<filesDir>/otp/lib/exqlite-VER/priv/sqlite3_nif.so`

`mob_beam.c` was also updated to detect pre-extracted helpers (stat check before
symlinking) so extraction and symlink creation don't conflict.

If you regenerated your Android project from an older `mob.new` template, `MobBridge.kt`
may be missing `extractBeamHelpersFromSplitApk`. Re-generate or manually add the function —
see the current template for the canonical implementation.

**Does not affect adb installs**: `adb install` unpacks a full APK where the system
does extract `.so` to `nativeLibraryDir` normally. The issue is Play Store split APK
delivery only.

### App installs from Play Store, BEAM starts, but screen stays black — `crypto.app not found`

**Symptom**: App is installed from Play Store, does not crash with a native signal, but
shows only a black screen. Logcat (filter: `adb logcat -s Elixir`) shows:

```
step 5 => {'EXIT',{{badmatch,{error,{crypto,{"no such file or directory","crypto.app"}}}},...}}
```

The BEAM started, but application boot failed when starting `:ecto_sqlite3` → `:ecto`
→ `:crypto`.

**Root cause**: The Mob pre-built Android OTP release does not include the `:crypto`
OTP application. Cross-compiling OpenSSL for Android was not part of the initial OTP
build. Many common deps (ecto, phoenix_pubsub, plug_crypto, phoenix) declare
`:crypto` in their `{applications, [...]}` list in their `.app` files. When
`Application.ensure_all_started` walks the dep tree, the OTP application controller
tries to load `crypto.app` and fails — even if `crypto.beam` were present, the
controller requires the `.app` spec to register the application before starting it.

**Fix**: `mix mob.release --android` (via `MobDev.ReleaseAndroid`) now handles this
automatically in two steps during staging:

1. **Patch all `.app` files** (`patch_crypto_deps!/1`): Walks every `*.app` file in
   the staging tree and removes `:crypto` from each `{applications, [...]}` list.
   This prevents `ensure_all_started` from even trying to start `:crypto` as a dep.

2. **Inject a crypto stub** (`add_crypto_stub!/2`): Compiles
   `mob_dev/priv/android/crypto.erl` — a minimal module that implements only
   `crypto:strong_rand_bytes/1` via `:rand` (the only function Ecto calls at runtime,
   for UUID generation). Also writes a `crypto.app` spec with no `{mod, ...}` entry,
   so the app controller can load and "start" `:crypto` without invoking any NIF
   initialization.

This is transparent as of the version where these functions were added. If you are on
an older `mob_dev` that doesn't have `patch_crypto_deps!/1`, upgrade `mob_dev` or
check `release_android.ex` for the current staging pipeline.

**Note on cryptographic strength**: The stub uses `:rand` seeded at BEAM start —
not a cryptographically secure RNG. This is acceptable for a local-only mobile app
that has no TLS or encryption use cases. If your app does require real crypto, you
will need to cross-compile OpenSSL and include the real `:crypto` NIF.

### App crashes immediately on launch (before any UI appears)

**Almost certainly a missing `otp.zip`.** This happens when you build the
AAB with `./gradlew bundleRelease` directly instead of going through
`mix mob.release --android`.

The app boots, `MobBridge.extractOtpIfNeeded()` finds no `assets/otp.zip`,
returns early, and then `mob_start_beam` tries to start BEAM from an
empty `<filesDir>/otp/` directory — crash.

Fix: always build release AABs with:

```bash
mix mob.release --android   # stages otp.zip, THEN runs gradlew
```

Never run `./gradlew bundleRelease` directly for a release build.

### "keystore password was incorrect" during Gradle release build

This is a misleading error. The likely cause is that your keystore is in
PKCS12 format and `bundletool` (which Gradle uses to sign AABs) doesn't
handle PKCS12 reliably even when the password is correct.

Convert to JKS:

```bash
keytool -importkeystore \
  -srckeystore android/upload.keystore  -srcstoretype PKCS12 \
  -destkeystore android/upload_jks.keystore -deststoretype JKS \
  -srcalias upload -destalias upload
```

Then update `android/keystore.properties` to use `upload_jks.keystore`.

### "Cannot read service account file: no such file or directory"

The file path in `mob.exs` `google_play.service_account_json` doesn't
exist. Check with:

```bash
cat mob.exs | grep service_account
ls ~/.google_play/
```

If the JSON file is missing, go to Google Cloud Console → IAM & Admin →
Service Accounts → your service account → Keys → Add key → Create new
key → JSON.

### "HTTP 401" or "Request had invalid authentication credentials"

The service account JSON key is invalid or revoked. Generate a new one:
Google Cloud Console → Service Accounts → your account → Keys → Add key.

Also confirm the `client_email` from the JSON is invited in Play Console →
Users and permissions with a Release manager role.

### "HTTP 403: Google Play Android Developer API has not been used in project … before or it is disabled"

The Android Publisher API isn't enabled in the linked Google Cloud project.

1. Go to https://console.cloud.google.com → correct project selected
2. **APIs & Services** → **Library** → search **Google Play Android Developer API** → **Enable**
3. Wait ~2 minutes for the change to propagate, then retry.

This is a one-time step per Cloud project.

### "HTTP 403" or "The caller does not have permission"

The service account exists and the API is enabled, but Play Console
publishing permission isn't fully wired. There are **two** required steps —
missing either one causes this error.

**Step 1 — Grant access via API access page:**

Play Console (account level) → **Setup** → **API access** → find your
service account in the list → click **Grant access** → set role to
**Release manager** → Apply.

**Step 2 — Invite via Users and permissions:**

Play Console (account level) → **Users and permissions** → **Invite new
users** → paste `client_email` from the JSON → role **Release manager** →
Apply → Invite user.

Both steps are required. Doing only the Users and permissions invite (Step 2)
without the API access Grant (Step 1) is the most common cause of this error.

Also confirm you're working in Play Console (https://play.google.com/console),
not Google Cloud Console — GCP IAM roles have no effect on Play publishing.

### "I see Cloud roles like 'Cloud Deploy Releaser' when trying to grant access"

You're in the wrong portal. That's Google Cloud Console IAM — those roles
control GCP infrastructure (Kubernetes, Cloud Run, etc.), not Play Store
publishing.

Go to https://play.google.com/console → Users and permissions → Invite new
users. The roles here (Release manager, Finance, etc.) are Play-specific.

### "I can't find API access in the Play Console"

API access is at the **account level**, not inside any specific app. If
you're inside an app's settings you'll only see app-level menus.

Click your **developer account name** or the back arrow at the top of the
left sidebar to reach the main developer dashboard. Then: Setup → API access.

### "There's a new ADC (Android Developer Console) asking for additional verification"

That's `get.google.com/adc-early-access` — a preview of Google's future
replacement for the Play Console. It may ask for additional verification
or fees as part of its early-access terms.

You don't need it. Publish using https://play.google.com/console, which
uses the $25 account you already registered. The ADC early access is
completely optional.

### "My build is on internal testing but testers can't find the app"

Testers must opt in via a link before the Play Store will show them the
app. In the Play Console → Testing → Internal testing → **Testers** tab,
there's a **copy link** button. Send that link to each tester. They click
it, choose to become a tester, and then the Play Store shows them the app.

Internal testing is tied to specific email addresses — testers must be
signed in to Play with the invited email.
