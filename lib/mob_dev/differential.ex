defmodule MobDev.Differential do
  require Logger

  @moduledoc """
  Drive `Mob.Differential.compare/3` against two live device nodes.

  Mob's product claim is one design, both platforms. `mob` ships the pure
  comparator; this module is the observer side of that: sample the semantic
  tree from each device, feed the pair through the comparator, report.

  The comparator itself runs **on one of the device nodes**, via `:rpc.call`,
  not in this process. Two reasons:

  * A device with a recent `mob` already has `Mob.Differential` loaded. The
    host (this process) may not: `mob_dev` pins the `mob` dep at a Hex
    version that need not match what the app was built against.
  * Feeding the trees to a comparator on the device keeps the tree payloads
    from crossing the dist boundary twice.

  The iOS node is chosen by convention: iOS shipped first in this project,
  and the comparator is symmetric (either device would give the same answer).
  If the iOS node's `mob` does not carry `Mob.Differential` yet, the call
  falls over to Android; if neither side does, that is reported as
  `{:error, :differential_unavailable}` rather than being hidden as a
  divergence. Note the semantic implication: while both devices have the
  comparator, the iOS device's `mob` version decides what "compare" means.
  If a comparator refinement lands on one platform before the other, the
  answer follows the iOS build, not the newer of the two.

  ## What this does *not* do yet

  * No fixture management. Both apps are already running the screen you
    want to compare; orchestrating the same fixture across two devices is a
    separate change on top of this.

  ## Divergences emit to the defect bus

  On a `{:divergence, ...}` result the run also emits a
  `Mob.Defect.Capsule` onto `Mob.Defect.Bus` (kind: `:divergence`, owner:
  `:mob`). This is MOB-159 phase 2 — the observer half of the closing
  loop that phase 1 built in `mob`.

  The capsule's fingerprint key is `%{fixture: fixture, reason: reason,
  path: path}` — so runs that both omit `:fixture` group with each other
  on `reason` + `path`, but a run that passes `:fixture` never groups
  with a run that omits it (they hash a different key). Pass `:fixture`
  as a caller-supplied identifier when you want the same divergence in
  the same fixture to group across runs; omit it for ad-hoc runs where
  grouping by `reason` + `path` alone is what you want.

  `:ok` and the documented `{:error, _}` variants do not emit — nothing to
  report on a clean run, and a harness gap (`:not_ready`,
  `:differential_unavailable`, `:tree_error`, `:comparator_error`) is not
  a framework defect. A novel result shape logs a warning and is likewise
  not emitted (see the fallback clause of the `emit` helper); adding a new
  taxonomy member is an explicit decision to compare or skip it, not
  silent absorption.

  The emit path is a no-op when the resolved `mob` version does not
  export `Mob.Defect.emit_divergence/2` — the dep spec allows a 0.7.x
  `mob` for consumers who have not moved to 0.8.1 yet, and the older
  library has no defect bus to emit onto. Callers who require the emit
  should pin `mob >= 0.8.1` in their own `mix.exs`.

  ## Usage

      MobDev.Differential.run(:"my_app_ios@127.0.0.1", :"my_app_android_emulator_5554@127.0.0.1", fixture: :counter_screen)
      #=> :ok | {:divergence, %{path: [...], reason: :type, ios: ..., android: ...}}
      #=> {:error, :not_ready | :differential_unavailable | {:tree_error | :comparator_error, node, term}}
  """

  @typedoc "Node name reachable over Erlang distribution."
  @type node_name :: node()

  @typedoc "Reason a run could not produce a comparison result."
  @type run_error ::
          :not_ready
          | :differential_unavailable
          | {:tree_error, node_name(), term()}
          | {:comparator_error, node_name(), term()}

  @type result :: :ok | {:divergence, map()} | {:error, run_error()}

  @default_rpc_timeout 15_000
  @known_opts [:frame_tolerance_dp, :rpc_timeout, :rpc, :fixture]

  @doc """
  Sample `Mob.Test.view_tree/1` on both nodes and compare.

  Options:
    * `:frame_tolerance_dp` - forwarded to `Mob.Differential.compare/3`.
    * `:rpc_timeout` - per-RPC timeout in ms. Default `#{@default_rpc_timeout}`.
      A run performs up to three sequential RPCs (iOS sample, Android
      sample, one comparator dispatch), so the worst-case wall clock is
      roughly `3 * rpc_timeout`.
    * `:rpc` - module implementing `:rpc.call/5`. For tests. Real callers
      should not pass this.
    * `:fixture` - a caller-supplied identifier for what is being compared
      (an atom, string, or module). Recorded on the emitted defect capsule's
      fingerprint key when a divergence is reported, so the same divergence
      in the same fixture groups across runs. Omit for ad-hoc runs where
      grouping across fixtures is acceptable.

  Unknown keys raise `ArgumentError` rather than being silently ignored:
  a run that thinks it tightened `frame_tolerance_dp` but actually used
  the default is worse than a loud failure.
  """
  @spec run(node_name(), node_name(), keyword()) :: result()
  def run(ios_node, android_node, opts \\ []) do
    Keyword.validate!(opts, @known_opts)
    rpc = Keyword.get(opts, :rpc, :rpc)
    timeout = Keyword.get(opts, :rpc_timeout, @default_rpc_timeout)
    fixture = Keyword.get(opts, :fixture)
    compare_opts = Keyword.take(opts, [:frame_tolerance_dp])

    result =
      with {:ok, ios_tree} <- sample(rpc, ios_node, timeout),
           {:ok, android_tree} <- sample(rpc, android_node, timeout) do
        call_comparator(
          [ios_node, android_node],
          rpc,
          ios_tree,
          android_tree,
          compare_opts,
          timeout
        )
      end

    emit(result, fixture)
    result
  end

  # Only a confirmed divergence is a framework defect. `:ok` is a clean
  # comparison; `{:error, ...}` names a harness gap that would file the
  # harness's own state as a defect if we let it through (`:not_ready`,
  # `:differential_unavailable`, `:tree_error`, `:comparator_error`).
  #
  # Explicit clauses per documented shape so a novel `run_error` variant
  # (added when a future failure mode joins the taxonomy) hits the loud
  # fallback rather than being silently absorbed as "not a defect".
  defp emit({:divergence, div}, fixture) do
    # `function_exported?/3` returns false for an unloaded module — the
    # BEAM does not auto-load a module named as an argument. `Code.ensure_loaded?/1`
    # forces the load (or reports the miss), and then the export check
    # actually reflects the resolved `mob` version.
    #
    # Guard for a `mob` older than 0.8.1: the dep spec allows it, and a
    # bare call to `Mob.Defect.emit_divergence/2` there would raise
    # `UndefinedFunctionError` and turn a divergence return into a
    # crash. See the moduledoc; callers who need the emit pin
    # `mob >= 0.8.1` themselves.
    if Code.ensure_loaded?(Mob.Defect) and
         function_exported?(Mob.Defect, :emit_divergence, 2) do
      apply(Mob.Defect, :emit_divergence, [div, [fixture: fixture]])
    else
      :ok
    end
  end

  defp emit(:ok, _fixture), do: :ok
  defp emit({:error, :not_ready}, _fixture), do: :ok
  defp emit({:error, :differential_unavailable}, _fixture), do: :ok
  defp emit({:error, {:tree_error, _node, _reason}}, _fixture), do: :ok
  defp emit({:error, {:comparator_error, _node, _reason}}, _fixture), do: :ok

  defp emit(other, _fixture) do
    Logger.error(
      "[MobDev.Differential] unknown result shape, not emitted as a defect: " <>
        inspect(other)
    )

    :ok
  end

  defp sample(rpc, node, timeout) do
    case rpc.call(node, Mob.Test, :view_tree, [node], timeout) do
      # A well-formed tree with at least one child at the root. Both
      # platforms produce a synthetic root wrapper (UIWindow scan, root
      # ComposeView), so a root with `children: []` means the app has not
      # rendered anything yet. Compared to another empty root, that would
      # report `:ok` (identically nothing shown) and hide a run where
      # neither device had actually booted the screen under test; call it
      # `:not_ready` instead.
      %{children: [_ | _]} = tree ->
        {:ok, tree}

      %{children: []} ->
        {:error, :not_ready}

      # Errors surfaced by the view_tree NIF itself. Example: Android
      # returns `{:error, :not_loaded}` when the app was regenerated from a
      # template that predates `MobBridge.uiViewTree()`. Distinct from
      # `:not_ready` so a caller can tell "app has not drawn yet" from
      # "app is broken".
      {:error, reason} ->
        {:error, {:tree_error, node, reason}}

      # Distribution error: cannot compare what did not arrive.
      {:badrpc, reason} ->
        {:error, {:tree_error, node, reason}}

      other ->
        {:error, {:tree_error, node, other}}
    end
  end

  # Try each node in order until one has `Mob.Differential`. iOS first by
  # convention. If neither does, both apps predate the comparator and the
  # honest answer is `:differential_unavailable`: reporting it as a
  # divergence would file the harness's own gap as a framework defect.
  defp call_comparator([], _rpc, _ios, _android, _opts, _timeout),
    do: {:error, :differential_unavailable}

  defp call_comparator([node | rest], rpc, ios_tree, android_tree, opts, timeout) do
    case rpc.call(node, Mob.Differential, :compare, [ios_tree, android_tree, opts], timeout) do
      :ok ->
        :ok

      {:divergence, _} = d ->
        d

      # `{:error, :not_ready}` is the comparator's own answer when a tree
      # it was handed is unusable; pass it through, do not fall over to the
      # other node (rerunning would just repeat the same answer).
      {:error, :not_ready} ->
        {:error, :not_ready}

      # Any other `{:error, _}` from the comparator is a novel shape not in
      # the documented `run_error` set. Wrap it as `:comparator_error` so
      # callers pattern-matching on the taxonomy do not silently miss it.
      {:error, _} = other ->
        {:error, {:comparator_error, node, other}}

      {:badrpc, {:EXIT, {:undef, _}}} ->
        call_comparator(rest, rpc, ios_tree, android_tree, opts, timeout)

      {:badrpc, reason} ->
        {:error, {:comparator_error, node, reason}}

      other ->
        {:error, {:comparator_error, node, other}}
    end
  end
end
