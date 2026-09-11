# The differential orchestrator invokes the comparator on-device via RPC

Date: 2026-09-11
Status: accepted
Ticket: MOB-157

## Context

`Mob.Differential.compare/3` (mob, MOB-147) is a pure comparator of two
normalized view trees; it lives in the `mob` library so it can ship inside the
runtime that produces those trees. MOB-157 asked for the mob_dev side: an
orchestrator a test harness calls to sample two device BEAMs (one iOS, one
Android) and get back `:ok | {:divergence, _} | {:error, _}`.

The obvious shape is a pure host-side call , `Mob.Differential.compare(ios,
android)`. But mob_dev's `mix.exs` pins `{:mob, "~> 0.7.25"}`, and the
comparator merged into `mob` master has not yet cut a Hex release. Pulling in
the merged-but-unreleased comparator would mean either bumping the mob dep (a
choreography that isn't ours to force from this ticket) or vendoring the
comparator into mob_dev (a duplicate implementation to keep in sync).

Both devices already run BEAMs and already respond to `:rpc.call/5` (that is
how `Mob.Test.view_tree/1` is fetched today). Whichever device has a mob
release that includes `Mob.Differential` can run it in-process on data that is
already there.

## Decision

`MobDev.Differential.run(ios_node, android_node, opts)` samples both trees via
`:rpc.call(node, Mob.Test, :view_tree, [node])`, then invokes
`Mob.Differential.compare/3` **on one of the devices via RPC** rather than on
the host. The iOS device is tried first by convention; if it returns
`{:badrpc, {:EXIT, {:undef, _}}}` (i.e. its mob build predates the
comparator), the orchestrator falls over to the Android node. Only `:undef`
triggers fallover; any other `:badrpc` is a real error and surfaces as
`{:comparator_error, node, reason}`.

`{:error, :not_ready}` from the comparator is **not** retried on the other
node , `:not_ready` reflects tree shape, not comparator availability, so
running the same comparison a second time would just repeat the answer.

`sample/3` short-circuits with `{:error, :not_ready}` if either device returns
`:no_window` (device hasn't rendered yet). Only the comparator call itself
proceeds when both trees are in hand , running the comparator with a missing
tree would produce a bogus divergence.

The orchestrator forwards `frame_tolerance_dp` to the comparator via
`Keyword.take/2`, but does not forward its own `rpc_timeout`. The rpc argument
is injectable (`opts[:rpc]`) so the test suite can stub it.

## Consequences

* No cross-repo release choreography is needed to land MOB-157. Once the mob
  Hex release that carries `Mob.Differential` ships, mob_dev callers can move
  the comparator to the host by swapping `MobDev.Differential.run/3` for a
  direct call; the on-device path becomes the fallback for older device
  builds, not the primary path.
* Fallover order (iOS-then-Android) is arbitrary but honest. If the running
  fleet inverts (Android leads on comparator freshness), swap the tuple.
* The orchestrator surface is deliberately narrow: it returns exactly what the
  comparator returns, plus its own transport-level error shapes
  (`{:tree_error, node, reason}`, `{:comparator_error, node, reason}`,
  `:differential_unavailable`). Higher-level policy (retries, backoff, batch
  runs) belongs to the test harness, not here.

## Additional behaviours documented after pre-commit review

* **Semantic implication of iOS-first.** While both devices have the
  comparator loaded, the iOS device's `mob` version decides what "compare"
  means. If a comparator refinement lands on one platform before the other,
  the answer follows the iOS build, not the newer of the two. If that
  becomes the wrong tradeoff (e.g. Android leads on comparator freshness),
  swap the tuple.
* **Unknown options raise.** `run/3` validates its keyword list against
  `[:frame_tolerance_dp, :rpc_timeout, :rpc]` and raises `ArgumentError` on
  anything else. A run that thinks it tightened `frame_tolerance_dp` but
  actually used the default is a worse failure than a loud one. This lines
  up with a neighbouring change in the same Unreleased block (`mix
  mob.deploy` rejects unrecognised flags for the same reason).
* **Empty root at the sampler is `:not_ready`.** Both platforms produce a
  synthetic root wrapper during boot (`UIWindow` scan on iOS, root
  `ComposeView` on Android). A root with `children: []` means the app has
  not rendered anything yet. Comparing two empty roots would report `:ok`
  ("identically nothing shown") and hide a run where neither device
  actually booted the screen under test; `sample/3` short-circuits to
  `{:error, :not_ready}` instead.
* **`{:error, reason}` from `Mob.Test.view_tree/1` is a `:tree_error`,
  not `:not_ready`.** Real case: Android's `mob_nif` returns `{:error,
  :not_loaded}` when the Kotlin bridge predates `MobBridge.uiViewTree()`.
  That is a broken build, not a timing issue; the caller sees
  `{:error, {:tree_error, node, :not_loaded}}` and can distinguish
  "wait and retry" from "something is wrong with this app."
* **Worst-case wall clock is roughly `3 * rpc_timeout`.** The three RPCs
  (iOS sample, Android sample, one comparator dispatch) are sequential
  today. If that becomes a real bound, sample the two trees in parallel;
  they are independent.
