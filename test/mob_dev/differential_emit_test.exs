defmodule MobDev.DifferentialEmitTest do
  # async: false — `Mob.Defect.Bus` is process-global on the local BEAM
  # (ETS + persistent_term + a named GenServer), and this suite uses
  # `Bus.reset()` between assertions. That reset would nuke another
  # async test's subscription mid-run. Kept in its own module so the rest
  # of MobDev.DifferentialTest stays async.
  use ExUnit.Case, async: false

  alias MobDev.Differential

  # Same FakeRPC pattern as MobDev.DifferentialTest, duplicated here rather
  # than extracted to a shared helper so the split lives in exactly one
  # place (this file's `async: false`).
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

  setup do
    Mob.Defect.Bus.start()
    Mob.Defect.Bus.reset()
    Mob.Defect.Bus.unsubscribe()
    {:ok, _ref} = Mob.Defect.Bus.subscribe()
    :ok
  end

  defp divergence_rpc(div) do
    ios = tree(:root, children: [tree(:button, label: "Go")])
    android = tree(:root, children: [tree(:text, label: "Go")])

    start_rpc(%{
      {@ios, Mob.Test, :view_tree} => ios,
      {@android, Mob.Test, :view_tree} => android,
      {@ios, Mob.Differential, :compare} => {:divergence, div}
    })
  end

  test "a divergence result emits a capsule on the defect bus" do
    div = %{path: [0], reason: :type, ios: :button, android: :text}
    {rpc, _agent} = divergence_rpc(div)

    assert Differential.run(@ios, @android, rpc: rpc, fixture: :counter_screen) ==
             {:divergence, div}

    assert_receive {:mob_defect, capsule}, 500
    assert capsule.kind == :divergence
    assert capsule.owner == :mob
    assert capsule.evidence.reason == :type
    assert capsule.evidence.path == [0]
    assert capsule.evidence.ios == :button
    assert capsule.evidence.android == :text
    assert capsule.evidence.fixture == :counter_screen
  end

  test "an :ok result does not emit" do
    same = tree(:root, children: [tree(:button, label: "OK")])

    {rpc, _} =
      start_rpc(%{
        {@ios, Mob.Test, :view_tree} => same,
        {@android, Mob.Test, :view_tree} => same,
        {@ios, Mob.Differential, :compare} => :ok
      })

    assert Differential.run(@ios, @android, rpc: rpc, fixture: :any) == :ok
    refute_receive {:mob_defect, _}, 100
    assert Mob.Defect.Bus.class_count() == 0
  end

  test "an {:error, :not_ready} result does not emit" do
    {rpc, _} =
      start_rpc(%{
        {@ios, Mob.Test, :view_tree} => empty_root(:UIWindow),
        {@android, Mob.Test, :view_tree} => tree(:root)
      })

    assert Differential.run(@ios, @android, rpc: rpc, fixture: :any) ==
             {:error, :not_ready}

    refute_receive {:mob_defect, _}, 100
  end

  test "an {:error, :differential_unavailable} result does not emit" do
    same = tree(:root, children: [tree(:button, label: "OK")])

    {rpc, _} =
      start_rpc(%{
        {@ios, Mob.Test, :view_tree} => same,
        {@android, Mob.Test, :view_tree} => same
        # No comparator response — both nodes return :undef.
      })

    assert Differential.run(@ios, @android, rpc: rpc) ==
             {:error, :differential_unavailable}

    refute_receive {:mob_defect, _}, 100
  end

  test "same fixture + reason + path fingerprint the same across tree-value changes" do
    div_a = %{path: [0], reason: :type, ios: :button, android: :text}
    div_b = %{path: [0], reason: :type, ios: :switch, android: :text}

    {rpc_a, _} = divergence_rpc(div_a)
    Differential.run(@ios, @android, rpc: rpc_a, fixture: :counter_screen)
    assert_receive {:mob_defect, capsule_a}, 500

    Mob.Defect.Bus.reset()

    {rpc_b, _} = divergence_rpc(div_b)
    Differential.run(@ios, @android, rpc: rpc_b, fixture: :counter_screen)
    assert_receive {:mob_defect, capsule_b}, 500

    assert capsule_a.fingerprint == capsule_b.fingerprint
  end

  test "different fixture fingerprints differently" do
    div = %{path: [0], reason: :type, ios: :button, android: :text}

    {rpc_a, _} = divergence_rpc(div)
    Differential.run(@ios, @android, rpc: rpc_a, fixture: :counter_screen)
    assert_receive {:mob_defect, capsule_a}, 500

    Mob.Defect.Bus.reset()

    {rpc_b, _} = divergence_rpc(div)
    Differential.run(@ios, @android, rpc: rpc_b, fixture: :other_screen)
    assert_receive {:mob_defect, capsule_b}, 500

    refute capsule_a.fingerprint == capsule_b.fingerprint
  end

  test "omitting :fixture still emits (nil fixture ok)" do
    div = %{path: [0], reason: :type, ios: :button, android: :text}
    {rpc, _} = divergence_rpc(div)

    Differential.run(@ios, @android, rpc: rpc)
    assert_receive {:mob_defect, capsule}, 500
    assert capsule.evidence.fixture == nil
  end
end
