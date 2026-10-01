# mix mob.smoke replays agent-device flows and judges them with the app's own counters
- Date: 2026-09-30
- Status: accepted

## Context
There was no repeatable way to drive a Mob app through its screens on a real
device and get a verdict. `agent-device` (0.21.1) already records UI flows as
`.ad` scripts and replays them on Android serials and iOS UDIDs, so mob_dev
does not need its own driver. Its replay alone is not a verdict a Mob project
can trust, for reasons found while wiring it up:

- `agent-device test --json` prints `"success": true` when scripts fail. Only
  `data.failed` / `data.notRun` say what happened. The exit status is
  non-zero on failure, but is not documented as the contract.
- A replay that taps the wrong app, or a launcher that never brings ours up,
  can still pass its own steps. Mob apps expose `Mob.Diag.health/0`: stores'
  `lost`/`resets`, the listener's `undeliverable`, and the receipt store's
  cumulative `recorded` count. Those say whether *this* app saw the flows and
  survived them.
- Those counters live in the app's BEAM (`:persistent_term`/`:atomics`) and
  start from zero when it boots. Recorded flows begin with
  `open <app> --relaunch`, which boots a new BEAM per flow, and its
  distribution comes up about 3 s after boot (`Mob.Dist`).
- `Mob.Agent.Receipts.count/0` is the number of rows *retained*, capped at
  256. On a busy app it reads 256 before and after, so it cannot measure a
  flow.
- `test` takes a device claim per script. A lease held by the caller, even
  from the same workspace, makes those per-script sessions fail with
  REPLAY_DIVERGENCE "device … is owned by session …".
- Android allows one UiAutomation client. mobile-mcp's
  `com.mobilenext.mobilecli.DeviceServer` holding it makes every snapshot fail
  with "Android snapshot helper output could not be parsed", which names
  nothing.

## Decision
- With health on (the default), `mix mob.smoke` runs `agent-device test
  <flow>.ad` **once per flow**, sequentially per device, with
  `--serial`/`--udid`, `--json`, `--artifacts-dir <root>/<device>/<flow>` and
  `--reporter junit:<path>-<device>-<flow>.xml`. Health and the BEAM's OS pid
  (`:os.getpid/0`) are read before the first flow and after each one, so every
  flow has its own before/after pair inside one BEAM lifetime as far as a
  single relaunch per flow goes. A pair from two different pids is compared
  against zero, which is exact for a freshly booted BEAM. After each flow the
  task waits up to 15 s for the node (`Node.connect`, then one
  `Connector.connect_all(restart: false)` re-attach, which finds an Android
  app re-registered under the bare `<app>_android` name and forwards its
  port). `--fail-fast` is decided by the task, on the verdict's own per-flow
  criterion (`MobDev.Smoke.failed?/1`: a failed or refused replay, a non-zero
  exit, or a health *failure*; never a warning or note), and remaining flows
  count as not run. (Correction: the first version halted only on a failed or
  not-run replay, so a flow that replayed cleanly but lost a store's table
  ran the next flow anyway, though the verdict then failed it.)
- With `--no-health` there is nothing to read between flows, so the flows run
  as one suite: `agent-device test '<flows>/*.ad'` (agent-device expands the
  glob), `--artifacts-dir <root>/<device>`, `--fail-fast` passed through.
- `--retries <n>` is always passed, `0` included. Without the flag
  agent-device falls back to a script's own `context retries=`, so omitting
  `0` (as the first version did) let a recorded script retry anyway.
- All paths are absolute: the agent-device daemon does not share our cwd.
- The verdict is computed by `MobDev.Smoke` (pure): a device fails on any
  failed or not-run flow, on zero executed flows, on a non-zero exit with an
  otherwise clean report, on a run agent-device refused (counted as a flow not
  run, with the refusal named), when it is blocked, and on any health failure
  finding. No device selected is a failure too.
- Health findings per flow: a rise in any store's `lost`/`resets` or in
  `listener.undeliverable` is a **failure** naming the flow. No new receipts
  (`stores[Mob.Agent.Receipts].store.recorded`) while the flow executed is a
  **warning** (a flow may legitimately touch nothing that records one). Health
  unreadable after a flow (node never came back) is a **warning** naming the
  flow. An unreachable node before the flows, or a mob without the functions
  (`< 0.9.5` for `health/0`, `< 0.9.7` for `listener`, no
  `Mob.Agent.Receipts` entry in `stores`), is a note: the check could not run,
  and the output says so. A receipts entry with no `store` key is a freshly
  booted app whose receipt store has not been written yet, and counts as 0
  recorded. (Correction: the first version treated that as "not counted",
  which on a device dropped the delta of every flow run against a fresh app.)
- A flow whose health snapshot before or after it did not read (unreachable
  node, or mob without `health/0`) is *unchecked*, and the run says so
  (MOB-347). The summary's
  health column reads `not checked (<reason>)` when no flow on the device was
  checked, or appends `k of n flow(s) not checked (<reason>)` to the counts
  when some were. A passing run claims "the app held up" only when every
  flow was checked (or `--no-health`, unchanged); otherwise its last line is
  `All flows passed; app health not checked on:` followed by one
  `<device>: <reason>` line per device, like the failure list. Exit stays 0:
  unchecked is not failed. (Correction: the first version printed
  `0 failure(s), 0 warning(s)` and "the app held up" for a run that never
  reached the node.)
- When the node is unreachable before the first flow, it is awaited once
  after that flow under its expected name (the same 15 s wait as after a
  relaunch, then a re-attach): recorded flows open the app with `--relaunch`,
  so an app that was not running usually is by then, and the later flows get
  checked. Only once, so an app without dist (or, on iOS, one relaunched
  without its dist cookie, MOB-348) costs one wait, not one per flow.
- Attach with `Connector.connect_all(restart: false)`; the flows expect the
  running app.
- Claims are only looked at (`device status --json`), never taken. A device
  with a listed claim (stale claims are hidden by agent-device) is skipped,
  reported with the owner's session and workspace, and fails the run.
- The UiAutomation conflict gets a hint naming
  `adb -s <serial> shell pkill -f mobilecli.DeviceServer`. It is not run for
  the user: mobile-mcp may be in use by another agent.
- Device selection is `MobDev.TaskTargets` (as `mob.deploy`/`mob.uninstall`):
  flows drive the UI, so a lone phone is not auto-selected.
- An iPhone discovered over the LAN only has its IP as `serial`, which
  agent-device cannot address; it is reported as blocked rather than guessed.
- (Added 2026-10-01, MOB-343.) The documented workaround for flows recorded
  on an iOS simulator is that the user deletes their
  `# agent-device:target-v1` identity lines; the task prints the command
  when it sees the failure and changes nothing. agent-device takes each step's
  recorded identity (role/id/label, the ancestry of containers above it, its
  sibling index) from its simulator accessibility bridge, but replay
  verifies it against an XCTest snapshot (`snapshot_capture backend=xctest`
  in the replay's diagnostics; the recording's press logs
  `producer=simulator-ax-bridge`). Inside a SwiftUI `ScrollView` the two
  trees differ: XCTest labels the content container with its first child's
  text, so agent-device keeps it where the bridge's unlabeled one is pruned.
  The recorded `ancestry[0]` is `scrollview`, the replayed one
  `other/☀️`, and every tap fails with IDENTITY_MISMATCH even though the
  selector matches. A recording that fell back to XCTest instead passes that
  check and fails the next one: dispatch resolves through the bridge, and the
  sibling index differs (12 vs 13, the first child's own text node). A
  20-line SwiftUI app (no mob) fails identically, on agent-device 0.21.1 and
  0.21.19. It has no flag or variable choosing either tree, so the lines go:
  agent-device documents a step without one as a normal, selector-resolved
  replay, and mob's selectors start with the tap tag (`id="open_dice"`). On
  an iOS simulator an IDENTITY_MISMATCH (read from
  `error.details.divergence.cause.code`) gets a hint with the `sed` command
  that deletes the flow's lines. The task does not delete them itself: the
  check also catches a genuinely wrong element, and the file is the user's.

Rejected: one suite run with a single before/after pair (a loss in an early
flow is erased by the next flow's relaunch, and the final BEAM reads clean);
`Mob.Agent.Receipts.count/0` for the delta (bounded, see above); holding our
own lease around the run (breaks `test`); trusting the top-level `success`;
failing on zero receipts (too many flows legitimately record none).
Also rejected for MOB-343: stripping the identity lines inside `mob.smoke`
(it would hide a real wrong-element divergence and rewrite a user's file);
changing mob's SwiftUI tree (the mismatch is between two readers of one
stock `ScrollView`/`VStack`, reproduced without mob).

## Consequences
- Requires `agent-device` on PATH; the task raises with
  `npm i -g agent-device` otherwise. Flows are recorded by hand (README,
  "Smoke flows on devices"); `--save-script` must be an absolute path.
- Per-flow runs cost one agent-device start per flow, and JUnit output is one
  file per device and flow rather than one per device.
- A flow that relaunches the app more than once, or crashes it and is
  relaunched mid-flow, is only checked from its last BEAM's boot.
- The JSON shapes are pinned to agent-device 0.21.1 in
  `test/mob_dev/smoke_test.exs`. A shape change surfaces as "printed JSON
  that is not a test report", counted as a flow not run, never a pass.
- The "did not reach the app" warning needs mob >= 0.9.7, where native taps
  first get receipts (MOB-305). On an older app (no `listener` section in
  health) it is a note instead, so a working flow is never flagged (release
  review, codex, 2026-09-30).
- Verified on a Moto G power 5G 2024 (Android 15, mob 0.9.7): two flows passed
  with exit 0 and per-flow receipt deltas (+4, +2). Earlier runs on the same
  phone and on a Pixel_8_arm emulator showed the failure paths: a lock screen
  or system overlay, and a snapshot-helper install failure, each named with
  the failing step, hint and artifacts, exit 1. The device runs found the
  per-BEAM counters, the capped `Receipts.count/0` and the fresh receipt store.
  iOS (`--udid`) is not yet verified on a device.
