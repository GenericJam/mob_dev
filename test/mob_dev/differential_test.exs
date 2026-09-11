defmodule MobDev.DifferentialTest do
  use ExUnit.Case, async: true

  alias MobDev.Differential

  # Reversion-bar-first tests. Each of MobDev.Differential's behaviours has a
  # test the whole suite fails without, and I check that by mutating the
  # source. That's the bar the review rounds on this epic have kept catching
  # my tests fail: a suite that passes against realistic mutations is a suite
  # that tells the caller nothing about the shipped code.

  # Fake :rpc that answers per-{node, module, function}. Reads its responses
  # from the caller's process dictionary; the orchestrator makes every call
  # from the same process it was invoked in, so this is a stable seam without
  # dynamic module generation.
  defmodule FakeRPC do
    def call(node, module, fun, args, _timeout) do
      key = {node, module, fun}
      Process.put({:calls, self()}, [{key, args} | Process.get({:calls, self()}, [])])

      case Map.get(Process.get(:responses, %{}), key) do
        nil -> {:badrpc, {:EXIT, {:undef, [{module, fun, length(args), []}]}}}
        value when is_function(value, 1) -> value.(args)
        value -> value
      end
    end
  end

  defp start_rpc(responses) do
    Process.put(:responses, responses)
    Process.put({:calls, self()}, [])
    {FakeRPC, self()}
  end

  defp calls(_owner), do: Process.get({:calls, self()}, []) |> Enum.reverse()

  defp tree(type, opts \\ []) do
    %{
      type: type,
      class: nil,
      label: Keyword.get(opts, :label),
      value: nil,
      frame: Keyword.get(opts, :frame),
      bg_color: nil,
      text_color: nil,
      children: Keyword.get(opts, :children, [leaf()])
    }
  end

  # A minimal non-empty child so a root tree is treated as "rendered". Empty
  # roots are separately meaningful (`:not_ready`).
  defp leaf,
    do: %{
      type: :leaf,
      class: nil,
      label: nil,
      value: nil,
      frame: nil,
      bg_color: nil,
      text_color: nil,
      children: []
    }

  defp empty_root(type) do
    %{
      type: type,
      class: nil,
      label: nil,
      value: nil,
      frame: nil,
      bg_color: nil,
      text_color: nil,
      children: []
    }
  end

  @ios :"app_ios@127.0.0.1"
  @android :"app_android@127.0.0.1"

  describe "happy path" do
    test "identical trees compare :ok" do
      same = tree(:root, children: [tree(:button, label: "OK")])

      {rpc, agent} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          {@ios, Mob.Differential, :compare} => :ok
        })

      assert Differential.run(@ios, @android, rpc: rpc) == :ok

      # Both trees were sampled, and the compare was dispatched to the iOS
      # node (convention). Nobody else got called.
      call_keys = calls(agent) |> Enum.map(&elem(&1, 0))

      assert call_keys == [
               {@ios, Mob.Test, :view_tree},
               {@android, Mob.Test, :view_tree},
               {@ios, Mob.Differential, :compare}
             ]
    end

    test "a divergence flows through, and iOS/Android tree order into compare/3 is preserved" do
      # The comparator's `:ios` and `:android` fields have to correspond to the
      # trees they were labelled with. If run/3 ever swapped the arg pair on
      # the way in, every reported divergence would silently reverse the two
      # sides. So the fake reads the args and derives the response from them
      # rather than returning a hardcoded shape.
      ios = tree(:root, children: [tree(:button, label: "Go")])
      android = tree(:root, children: [tree(:text, label: "Go")])

      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => ios,
          {@android, Mob.Test, :view_tree} => android,
          {@ios, Mob.Differential, :compare} => fn [ios_arg, android_arg, _opts] ->
            {:divergence,
             %{
               path: [0],
               reason: :type,
               ios: hd(ios_arg.children).type,
               android: hd(android_arg.children).type
             }}
          end
        })

      assert Differential.run(@ios, @android, rpc: rpc) ==
               {:divergence, %{path: [0], reason: :type, ios: :button, android: :text}}
    end
  end

  describe "device not ready" do
    test "an iOS empty root short-circuits to {:error, :not_ready}" do
      # A device that has not rendered yet returns a synthetic root with no
      # children. Two identically-empty roots would compare as `:ok`, and a
      # green run on a phone that never actually booted the screen under
      # test is worse than a loud not-ready.
      {rpc, agent} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => empty_root(:UIWindow),
          {@android, Mob.Test, :view_tree} => tree(:root)
        })

      assert Differential.run(@ios, @android, rpc: rpc) == {:error, :not_ready}

      refute Enum.any?(calls(agent), fn {{_, m, _}, _} -> m == Mob.Differential end),
             "the comparator must not run when a sample is missing"
    end

    test "an Android empty root short-circuits to {:error, :not_ready}" do
      # Symmetric to the iOS case: the check must fire regardless of which
      # side is empty. If only iOS were guarded, an Android that has not
      # booted the screen would slip through to a spurious `:ok`.
      {rpc, agent} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => tree(:root),
          {@android, Mob.Test, :view_tree} => empty_root(:ComposeView)
        })

      assert Differential.run(@ios, @android, rpc: rpc) == {:error, :not_ready}

      refute Enum.any?(calls(agent), fn {{_, m, _}, _} -> m == Mob.Differential end),
             "the comparator must not run when a sample is missing"
    end

    test "a :badrpc on a view_tree sample is reported as a tree_error with the node" do
      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => {:badrpc, :timeout},
          {@android, Mob.Test, :view_tree} => tree(:root)
        })

      assert {:error, {:tree_error, @ios, :timeout}} = Differential.run(@ios, @android, rpc: rpc)
    end

    test "an {:error, reason} from view_tree/1 is a tree_error, NOT :not_ready" do
      # Real case: Android's mob_nif returns `{:error, :not_loaded}` when the
      # app was regenerated from a template that predates
      # `MobBridge.uiViewTree()`. That must not be conflated with a device
      # that has not rendered yet: `:not_ready` is a re-run-later signal;
      # `:not_loaded` is a "your build is broken, no amount of waiting will
      # fix this" signal.
      {rpc, _} =
        start_rpc(%{
          {@android, Mob.Test, :view_tree} => {:error, :not_loaded},
          {@ios, Mob.Test, :view_tree} => tree(:root)
        })

      assert Differential.run(@ios, @android, rpc: rpc) ==
               {:error, {:tree_error, @android, :not_loaded}}
    end
  end

  describe "comparator availability" do
    test "falls over to Android when iOS's mob is too old for Mob.Differential" do
      # Not hypothetical: the comparator landed in mob master and is not on
      # Hex yet, so any app not built from a fresh checkout returns :undef
      # for Mob.Differential. The other device may be newer.
      same = tree(:root)

      {rpc, agent} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          # iOS: no Differential.
          # Android: has it.
          {@android, Mob.Differential, :compare} => :ok
        })

      assert Differential.run(@ios, @android, rpc: rpc) == :ok

      # Both nodes were tried, in the documented order.
      compare_targets =
        calls(agent)
        |> Enum.filter(fn {{_, m, _}, _} -> m == Mob.Differential end)
        |> Enum.map(fn {{n, _, _}, _} -> n end)

      assert compare_targets == [@ios, @android]
    end

    test "neither node has Mob.Differential is reported honestly" do
      # Both apps predate the comparator. Reporting `:ok` would be a silent
      # lie; the harness has no way to tell whether the trees agree.
      same = tree(:root)

      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same
          # No compare responses; both return :undef.
        })

      assert Differential.run(@ios, @android, rpc: rpc) ==
               {:error, :differential_unavailable}
    end

    test "the comparator's own {:error, :not_ready} is NOT retried on the other node" do
      # The comparator says the tree is unusable; the other node would tell
      # the same story. Retrying would double the cost and mask the harness
      # gap this exists to surface.
      same = tree(:root)

      {rpc, agent} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          {@ios, Mob.Differential, :compare} => {:error, :not_ready}
        })

      assert Differential.run(@ios, @android, rpc: rpc) == {:error, :not_ready}

      compare_targets =
        calls(agent)
        |> Enum.filter(fn {{_, m, _}, _} -> m == Mob.Differential end)
        |> Enum.map(fn {{n, _, _}, _} -> n end)

      assert compare_targets == [@ios],
             "an honest :not_ready from the comparator must not fan out to a second attempt"
    end

    test "a comparator {:error, novel_reason} is wrapped as :comparator_error (contract-drift guard)" do
      # The documented `run_error` taxonomy is a fixed set. If the comparator
      # ever grows a new `{:error, _}` reason, callers pattern-matching on
      # `:not_ready | :differential_unavailable | :tree_error | :comparator_error`
      # would silently miss it. Wrap anything that isn't the known
      # `:not_ready` so the taxonomy stays honest.
      same = tree(:root)

      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          {@ios, Mob.Differential, :compare} => {:error, :some_novel_reason}
        })

      assert {:error, {:comparator_error, @ios, {:error, :some_novel_reason}}} =
               Differential.run(@ios, @android, rpc: rpc)
    end

    test "a non-:undef :badrpc on the comparator is not a fallover trigger" do
      # Timeout, disconnect, anything else: the harness knows *this* call
      # failed but has no reason to believe the other node fares differently.
      # Reporting it as its own error keeps the failure mode distinct from
      # "the app is too old".
      same = tree(:root)

      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          {@ios, Mob.Differential, :compare} => {:badrpc, :timeout}
        })

      assert {:error, {:comparator_error, @ios, :timeout}} =
               Differential.run(@ios, @android, rpc: rpc)
    end
  end

  describe "options" do
    test "frame_tolerance_dp is forwarded to Mob.Differential.compare/3" do
      same = tree(:root)
      parent = self()

      {rpc, _} =
        start_rpc(%{
          {@ios, Mob.Test, :view_tree} => same,
          {@android, Mob.Test, :view_tree} => same,
          {@ios, Mob.Differential, :compare} => fn [_ios, _android, opts] ->
            send(parent, {:compare_opts, opts})
            :ok
          end
        })

      assert Differential.run(@ios, @android, rpc: rpc, frame_tolerance_dp: 5.0) == :ok

      assert_receive {:compare_opts, opts}
      assert opts[:frame_tolerance_dp] == 5.0
    end

    test "an unknown option raises rather than being silently ignored" do
      # A typo in a tolerance name would otherwise pass through unnoticed and
      # the run would use the default; that failure mode is exactly what a
      # neighbouring change (`mix mob.deploy` rejects unrecognised options)
      # was written to prevent.
      assert_raise ArgumentError, fn ->
        Differential.run(@ios, @android, frame_toleracne_dp: 5.0)
      end
    end

    test "rpc_timeout is forwarded to :rpc.call for all three round-trips" do
      parent = self()

      defmodule TimeoutRPC do
        def call(node, mod, fun, _args, timeout) do
          send(:mob_dev_differential_timeout_probe, {:timeout, node, mod, fun, timeout})

          case {mod, fun} do
            {Mob.Test, :view_tree} ->
              # Non-empty root so the pipeline reaches the comparator dispatch.
              %{
                type: :root,
                class: nil,
                label: nil,
                value: nil,
                frame: nil,
                bg_color: nil,
                text_color: nil,
                children: [
                  %{
                    type: :leaf,
                    class: nil,
                    label: nil,
                    value: nil,
                    frame: nil,
                    bg_color: nil,
                    text_color: nil,
                    children: []
                  }
                ]
              }

            {Mob.Differential, :compare} ->
              :ok
          end
        end
      end

      Process.register(parent, :mob_dev_differential_timeout_probe)

      assert Differential.run(@ios, @android, rpc: TimeoutRPC, rpc_timeout: 3_141) == :ok

      # All three sequential RPCs must have carried the caller's timeout.
      # If the comparator dispatch ever hardcoded a value, the third
      # assert would time out.
      assert_receive {:timeout, @ios, Mob.Test, :view_tree, 3_141}
      assert_receive {:timeout, @android, Mob.Test, :view_tree, 3_141}
      assert_receive {:timeout, @ios, Mob.Differential, :compare, 3_141}
    after
      Process.unregister(:mob_dev_differential_timeout_probe)
    end
  end
end
