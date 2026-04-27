# mob_dev

Development tooling for [Mob](https://hexdocs.pm/mob) — the BEAM-on-device mobile framework for Elixir.

[![Hex.pm](https://img.shields.io/hexpm/v/mob_dev.svg)](https://hex.pm/packages/mob_dev)

## Installation

Add to your project's `mix.exs` (dev only):

```elixir
def deps do
  [
    {:mob_dev, "~> 0.2", only: :dev}
  ]
end
```

## Mix tasks

| Task | Description |
|------|-------------|
| `mix mob.new APP_NAME` | Generate a new Mob project (see `mob_new` archive) |
| `mix mob.install` | First-run setup: download OTP runtime, generate icons, write `mob.exs` |
| `mix mob.deploy` | Compile and push BEAMs to all connected devices |
| `mix mob.deploy --native` | Also build and install the native APK/iOS app |
| `mix mob.connect` | Tunnel + restart + open IEx connected to device nodes (`--name` for multiple sessions) |
| `mix mob.watch` | Auto-push BEAMs on file save |
| `mix mob.watch_stop` | Stop a running `mix mob.watch` |
| `mix mob.devices` | List connected devices and their status |
| `mix mob.push` | Hot-push only changed modules (no restart) |
| `mix mob.server` | Start the dev dashboard at `localhost:4040` |
| `mix mob.icon` | Regenerate app icons |
| `mix mob.routes` | Validate navigation destinations across the codebase |
| `mix mob.battery_bench_android` | Measure BEAM idle power draw on an Android device |
| `mix mob.battery_bench_ios` | Measure BEAM idle power draw on a physical iOS device |

## Dev dashboard (`mix mob.server`)

`mix mob.server` starts a local Phoenix server (default port 4040) with:

- **Device cards** — live status for connected Android emulators and iOS simulators, with Deploy and Update buttons per device
- **Device log panel** — streaming logcat / iOS simulator console with text filter
- **Elixir log panel** — Elixir `Logger` output forwarded from the running BEAM, with text filter
- **Watch mode toggle** — auto-push changed BEAMs on file save without running a separate terminal
- **QR code** — LAN URL for opening the dashboard on a physical device

Run with IEx for an interactive terminal alongside the dashboard:

```bash
iex -S mix mob.server
```

### Watch mode

Click **Watch** in the dashboard header or control it programmatically:

```elixir
MobDev.Server.WatchWorker.start_watching()
MobDev.Server.WatchWorker.stop_watching()
MobDev.Server.WatchWorker.status()
#=> %{active: true, nodes: [:"my_app_ios@127.0.0.1"], last_push: ~U[...]}
```

Watch events broadcast on `"watch"` PubSub topic:

```elixir
{:watch_status, :watching | :idle}
{:watch_push,   %{pushed: [...], failed: [...], nodes: [...], files: [...]}}
```

## Hot-push transport (`mix mob.deploy`)

When Erlang distribution is reachable, `mix mob.deploy` hot-pushes changed BEAMs in-place via RPC — no `adb push`, no app restart. The running modules are replaced exactly like `nl/1` in IEx.

```
Pushing 14 BEAM file(s) to 2 device(s)...
  Pixel_7_API_34  →  pushing... ✓ (dist, no restart)
  iPhone 15 Pro   →  pushing... ✓ (dist, no restart)
```

If dist is not reachable (first deploy, app not running), it falls back to `adb push` + restart. Mixed deploys work — one device can hot-push while another restarts.

**Requirements:** The app must call `Mob.Dist.ensure_started/1` at startup, and the cookie must match the one in `mob.exs` (default `:mob_secret`).

## Navigation validation (`mix mob.routes`)

Validates all `push_screen`, `reset_to`, and `pop_to` destinations across `lib/**/*.ex` via AST analysis. Module destinations are verified with `Code.ensure_loaded/1`.

```bash
mix mob.routes           # print warnings
mix mob.routes --strict  # exit non-zero (for CI)
```

```
✓ 12 navigation reference(s) valid (2 dynamic/named skipped)

# On failure:
✗ 1 unresolvable navigation destination(s):
  lib/my_app/home_screen.ex:42  push_screen(socket, MyApp.SettingsScren)
    Module MyApp.SettingsScren could not be loaded.
```

Dynamic destinations (`push_screen(socket, var)`) and registered name atoms (`:main`) are skipped with a note.

## Battery benchmarks

Measure BEAM idle power draw with specific tuning flags. Both tasks share the same presets and flag interface.

### Android (`mix mob.battery_bench_android`)

Deploys an APK and measures drain via the hardware charge counter (`dumpsys
battery`). Reports mAh every 10 seconds. Uses the same probe / observer /
CSV-log / preflight infrastructure as the iOS bench.

**WiFi ADB required** — a USB cable charges the device and skews measurements.

```bash
# One-time WiFi ADB setup (while plugged in):
adb -s SERIAL tcpip 5555
adb connect PHONE_IP:5555
# then unplug
```

#### Two-step workflow (recommended)

Same pattern as iOS — push BEAM flags via `mix mob.deploy`, then bench
with `--no-build`. Saves the Gradle rebuild (~30+ seconds) when only
changing flags.

```bash
mix mob.deploy --beam-flags "" --android                # tuned (Nerves)
mix mob.deploy --beam-flags "-S 4:4 -A 8" --android     # untuned variant

mix mob.battery_bench_android --no-build --device 192.168.1.42:5555
```

The bench will:
- Run preflight checks (adb device, app installed, BEAM reachable, RPC
  responsive, NIF version, keep-alive NIF)
- Subscribe to `Mob.Device` events on the running app for ground-truth
  screen/app-state tracking
- Write a per-tick CSV log to `_build/bench/run_android_<ts>.csv`
- Auto-reconnect with backoff if the dist connection flaps
- Print a probe-based summary at the end with success rate, reconnect
  count, time-by-state, screen-on/off durations, and **taint warnings**

#### Single-step Gradle path

Still supported when you want a clean rebuild:

```bash
mix mob.battery_bench_android                              # default: Nerves-tuned BEAM, 30 min
mix mob.battery_bench_android --no-beam                    # baseline: no BEAM at all
mix mob.battery_bench_android --preset untuned             # raw BEAM, no tuning
mix mob.battery_bench_android --flags "-sbwt none -S 1:1"
mix mob.battery_bench_android --duration 3600 --device 192.168.1.42:5555
mix mob.battery_bench_android --no-build                   # re-run without rebuilding
```

#### Recovering from bad flags

`mix mob.deploy --beam-flags "..."` saves to `mob.exs` so the flags persist
across runs. If a flag combination crashes the BEAM, every subsequent
deploy re-applies them. Push an empty string to clear:

```bash
mix mob.deploy --beam-flags "" --android
```

### iOS (`mix mob.battery_bench_ios`)

Deploys to a physical iPhone/iPad and reads battery via `ideviceinfo` (USB)
or via Erlang RPC over WiFi. Reports mAh (if `BatteryMaxCapacity` is
available) or percentage points.

**Prerequisites:** `brew install libimobiledevice`, Xcode 15+, device
trusted on this Mac, phone on the same WiFi as the Mac.

#### Two-step workflow (recommended)

For Mob projects (which use `ios/build_device.sh` rather than a full Xcode
project), you can't rebuild + bench in one command — the bench task's
built-in `xcodebuild` path doesn't support the Mob build system. Instead,
do the two steps separately:

```bash
# Step 1 — deploy with whatever BEAM flags you want.
# This pushes the .beam files PLUS a runtime mob_beam_flags file that
# the launcher reads at startup. No native rebuild required (~5 seconds).
mix mob.deploy --beam-flags "" --ios                       # tuned (Nerves defaults)
mix mob.deploy --beam-flags "-S 6:6 -A 16" --ios           # untuned variant
mix mob.deploy --ios                                       # uses flags saved in mob.exs

# Step 2 — run the bench with --no-build, since we already deployed.
mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120
mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --duration 600
mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --skip-preflight
```

Find your phone's WiFi IP in **Settings → Wi-Fi → (i) → IP Address**.

`--wifi-ip` is strongly recommended — without it the bench tries to
auto-discover the device, which is flaky for WiFi-only setups (we've seen
it pick up the Mac's own EPMD or simulator nodes).

#### What the bench shows you

A live trace per 10-second poll, with state per tick:

```
[02:33:00] 0.5/30 min — screen:off app:running rpc:ok battery:100% (−0.0 %)
```

A CSV log in `_build/bench/run_<ts>.csv` (every sample, every state).

A probe-based summary at the end with success rate, reconnect count,
longest gap, time-by-state, screen-on/off durations, and **taint warnings**
that catch invalid runs (screen turned on, app died, majority unreachable,
flapping connection).

#### Recovering from bad flags

`mix mob.deploy --beam-flags "..."` saves the flags to `mob.exs` so they
persist across runs. If a flag combination crashes the BEAM (e.g.
requesting more threads than iOS allows per process), every subsequent
`mix mob.deploy` re-applies the same bad flags and the app keeps crashing.

To recover, push an empty flags string — clears `mob.exs` *and* the
runtime override file on every device:

```bash
mix mob.deploy --beam-flags "" --ios
```

#### Flag prefix convention (iOS)

The Mob iOS BEAM build is conservative about flag syntax. Match the
compile-time defaults' format — `-` prefix, space-separated values:

```
-S 1:1 -SDcpu 1:1 -SDio 1 -A 1 -sbwt none      ← compile-time defaults (Nerves)
```

When in doubt, copy that pattern. We've observed `+S 6:6 +A 64 +SDio 8`
crashing the BEAM at startup with no useful log line — likely because the
combined thread count exceeds iOS's per-process limit. Build untuned
configs incrementally:

```bash
# Smallest delta from defaults — multi-scheduler but everything else minimal:
mix mob.deploy --beam-flags "-S 2:2 -SDcpu 2:2 -SDio 2 -A 2" --ios
# Bench. If the app launches and runs, ramp up:
mix mob.deploy --beam-flags "-S 6:6 -SDcpu 6:6 -SDio 6 -A 8" --ios
```

#### Other options

```bash
mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --no-keep-alive
# Skips the silent-audio keep-alive call. Use when the keep-alive NIF is
# misbehaving or you want to verify how much drain comes from background
# audio session vs the BEAM itself.

mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --skip-preflight
# Bypass the pre-flight checks (useful when the checks are spuriously
# failing on devicectl noise or similar).

mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --no-csv
# Don't write the CSV log (run is purely live-trace + final summary).

mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120 --log-path /tmp/run.csv
# Override CSV location.
```

### Presets and results

| Preset | Flags | mAh/hr (Moto G, screen on, low brightness) |
|--------|-------|----------------|
| No BEAM | — | ~200 |
| Nerves (default) | `-S 1:1 -SDcpu 1:1 -SDio 1 -A 1 -sbwt none` | ~202 |
| Untuned | *(none)* | ~250 |

The Nerves-tuned BEAM is essentially indistinguishable from a stock Android app at idle. The untuned BEAM costs ~25% more because schedulers spin-wait instead of sleeping.

**iOS results** are tracked separately in `mob/guides/why_beam.md` (different
device, different methodology — physical iPhone with screen on/off
distinction). The `--preset` shortcuts (`untuned`/`sbwt`/`nerves`) aren't
useful on iOS because they require a full Xcode rebuild (which Mob projects
don't have), so on iOS you set flags via `mix mob.deploy --beam-flags ...`
and bench with `--no-build`.

## Working with an agent (Claude Code / LLM)

Because OTP runs on the device, an agent can connect directly to the running app via Erlang distribution and inspect or drive it programmatically — no screenshots required.

### How it works

```
Agent (Claude Code)
    │
    ├── mix mob.connect      → tunnels EPMD, connects IEx to device node
    │
    ├── Mob.Test.*           → inspect screen state, trigger taps via RPC
    │   (exact state: module, assigns, render tree)
    │
    └── MCP tools            → native UI when needed
        ├── adb-mcp          → Android: screenshot, shell, UI inspect
        └── ios-simulator-mcp → iOS: screenshot, tap, describe UI
```

### Mob.Test — preferred for agents

`Mob.Test` gives exact app state via Erlang distribution. Prefer it over screenshots whenever possible — it doesn't depend on rendering, is instantaneous, and works offline.

```elixir
node = :"my_app_ios@127.0.0.1"

# Inspection
Mob.Test.screen(node)               #=> MyApp.HomeScreen
Mob.Test.assigns(node)              #=> %{count: 3, user: %{name: "Alice"}, ...}
Mob.Test.find(node, "Save")         #=> [{[0, 2], %{"type" => "button", ...}}]
Mob.Test.inspect(node)              # full snapshot: screen + assigns + nav history + tree

# Tap a button by tag atom (from on_tap: {self(), :save} in render/1)
Mob.Test.tap(node, :save)

# Navigation — synchronous, safe to read state immediately after
Mob.Test.back(node)                 # system back gesture (fire-and-forget)
Mob.Test.pop(node)                  # pop to previous screen (synchronous)
Mob.Test.navigate(node, MyApp.DetailScreen, %{id: 42})
Mob.Test.pop_to(node, MyApp.HomeScreen)
Mob.Test.pop_to_root(node)
Mob.Test.reset_to(node, MyApp.HomeScreen)

# List interaction
Mob.Test.select(node, :my_list, 0)  # select first row

# Simulate device API results (permission dialogs, camera, location, etc.)
Mob.Test.send_message(node, {:permission, :camera, :granted})
Mob.Test.send_message(node, {:camera, :photo, %{path: "/tmp/p.jpg", width: 1920, height: 1080}})
Mob.Test.send_message(node, {:location, %{lat: 43.65, lon: -79.38, accuracy: 10.0, altitude: 80.0}})
Mob.Test.send_message(node, {:notification, %{id: "n1", title: "Hi", body: "Hey", data: %{}, source: :push}})
Mob.Test.send_message(node, {:biometric, :success})
```

### Accessing IEx alongside an agent

**Option 1 — shared session (`iex -S mix mob.server`):**

```bash
iex -S mix mob.server
```

Starts the dev dashboard and gives you an IEx prompt in the same process. The agent uses Tidewave to execute `Mob.Test.*` calls in this session; you type directly in the same IEx prompt. Both share the same connected node and see the same live state. This is the recommended setup for working alongside an agent.

**Option 2 — separate sessions (`--name`):**

Because Erlang distribution allows multiple nodes to connect to the same device, you can run independent sessions simultaneously:

```bash
# Your terminal
mix mob.connect --name mob_dev_1@127.0.0.1

# Agent's terminal (or a second developer)
mix mob.connect --name mob_dev_2@127.0.0.1
```

Both connect to the same device nodes, can call `Mob.Test.*` and `nl/1`, and don't interfere with each other.

### MCP tool setup

For native UI interaction (screenshots, native gestures, accessibility inspection), install MCP servers for Claude Code:

**Android — `adb-mcp`:**

```bash
npm install -g adb-mcp
```

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "adb": {
      "command": "npx",
      "args": ["adb-mcp"]
    }
  }
}
```

**iOS simulator — `ios-simulator-mcp`:**

```bash
npm install -g ios-simulator-mcp
```

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "ios-simulator": {
      "command": "ios-simulator-mcp"
    }
  }
}
```

With these installed, Claude Code can take screenshots, inspect the accessibility tree, and simulate gestures on the native device — useful when you need to verify layout or test native gesture paths.

### Recommended CLAUDE.md for Mob projects

Add a `CLAUDE.md` to your Mob project root to give an agent the context it needs:

````markdown
# MyApp — Agent Instructions

## Connecting to a running device

```bash
mix mob.connect          # discover, tunnel, connect IEx
mix mob.connect --no-iex # print node names without IEx
mix mob.devices          # list connected devices
```

Node names:
- iOS simulator:    `my_app_ios@127.0.0.1`
- Android emulator: `my_app_android@127.0.0.1`

## Inspecting and driving the running app

Prefer `Mob.Test` over screenshots — it gives exact state, not a visual approximation.

```elixir
node = :"my_app_ios@127.0.0.1"

# Inspection
Mob.Test.screen(node)       # current screen module
Mob.Test.assigns(node)      # current assigns map
Mob.Test.find(node, "text") # find UI nodes by visible text
Mob.Test.inspect(node)      # full snapshot: screen + assigns + nav history + tree

# Interaction
Mob.Test.tap(node, :tag)              # tap by tag atom (from on_tap: {self(), :tag} in render/1)
Mob.Test.back(node)                   # system back gesture
Mob.Test.pop(node)                    # pop to previous screen (synchronous)
Mob.Test.navigate(node, Screen, %{})  # push a screen (synchronous)
Mob.Test.select(node, :list_id, 0)    # select a list row

# Simulate device API results
Mob.Test.send_message(node, {:permission, :camera, :granted})
Mob.Test.send_message(node, {:camera, :photo, %{path: "/tmp/p.jpg", width: 1920, height: 1080}})
Mob.Test.send_message(node, {:biometric, :success})
```

Navigation functions (`pop`, `navigate`, `pop_to`, `pop_to_root`, `reset_to`) are
synchronous — safe to read state immediately after.

`back/1` and `send_message/2` are fire-and-forget. If you need to wait:

```elixir
Mob.Test.back(node)
:rpc.call(node, :sys, :get_state, [:mob_screen])  # flush
Mob.Test.screen(node)
```

## Hot-pushing code changes

```bash
mix mob.push          # compile + push all changed modules to all connected devices
mix mob.push --all    # force-push every module
```

## Deploying

```bash
mix mob.deploy          # push changed BEAMs, restart
mix mob.deploy --native # full native rebuild + install
```
````

### Agent workflow example

A typical agent session for debugging or feature work:

```
1. mix mob.connect                        — connect to the running device node
2. Mob.Test.screen(node)                  — confirm which screen is showing
3. Mob.Test.assigns(node)                 — inspect current state
4. Mob.Test.tap(node, :some_button)       — interact with the UI
5. Mob.Test.screen(node)                  — confirm navigation happened
6. edit lib/my_app/screen.ex              — make a code change
7. mix mob.push                           — hot-push changed modules without restart
8. Mob.Test.assigns(node)                 — verify state updated as expected
```

For device API interactions, simulate the result rather than triggering real hardware:

```elixir
# Instead of actually opening the camera:
Mob.Test.tap(node, :take_photo)     # triggers handle_event → Mob.Camera.capture_photo
# Simulate the result:
Mob.Test.send_message(node, {:camera, :photo, %{path: "/tmp/test.jpg", width: 1920, height: 1080}})
Mob.Test.assigns(node)              # verify photo_path was stored
```

If you need to see the rendered UI, take a screenshot with the native MCP tool, then use `Mob.Test.find/2` to correlate what you see with the component tree.
