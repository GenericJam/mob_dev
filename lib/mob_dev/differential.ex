defmodule MobDev.Differential do
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
  * No sink. The result is returned to the caller; wiring divergences into a
    defect bus is MOB-159.

  ## Usage

      MobDev.Differential.run(:"my_app_ios@127.0.0.1", :"my_app_android_emulator_5554@127.0.0.1")
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
  @known_opts [:frame_tolerance_dp, :rpc_timeout, :rpc]

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

  Unknown keys raise `ArgumentError` rather than being silently ignored:
  a run that thinks it tightened `frame_tolerance_dp` but actually used
  the default is worse than a loud failure.
  """
  @spec run(node_name(), node_name(), keyword()) :: result()
  def run(ios_node, android_node, opts \\ []) do
    Keyword.validate!(opts, @known_opts)
    rpc = Keyword.get(opts, :rpc, :rpc)
    timeout = Keyword.get(opts, :rpc_timeout, @default_rpc_timeout)
    compare_opts = Keyword.take(opts, [:frame_tolerance_dp])

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
