defmodule MobDev.NodeUtilTest do
  use ExUnit.Case, async: true

  alias MobDev.NodeUtil

  describe "start_host_dist/3" do
    # P17a: a second mob.connect / deploy on the same Mac died with
    # "the name mob_dev@127.0.0.1 seems to be in use". Each side runs in its
    # own peer VM so this test's VM never becomes distributed.
    setup do
      base = "mob_dev_nu_#{System.unique_integer([:positive])}"
      code_path = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

      {:ok, holder, _} =
        :peer.start(%{
          name: String.to_atom(base),
          host: ~c"127.0.0.1",
          longnames: true,
          connection: :standard_io
        })

      # The held name makes net_kernel fail to start, which it reports loudly;
      # that failure is the point of the test.
      quiet = [~c"-kernel", ~c"logger_level", ~c"emergency"]
      {:ok, fresh, _} = :peer.start(%{connection: :standard_io, args: quiet ++ code_path})

      on_exit(fn ->
        for peer <- [holder, fresh], Process.alive?(peer), do: :peer.stop(peer)
      end)

      %{base: base, fresh: fresh}
    end

    test "falls back to a per-process name when the default is held", %{base: base, fresh: fresh} do
      assert {:ok, node} = :peer.call(fresh, NodeUtil, :start_host_dist, [nil, :c, base])

      assert Atom.to_string(node) =~ Regex.compile!("^#{base}_\\d+@127\\.0\\.0\\.1$")
      assert :peer.call(fresh, Node, :get_cookie, []) == :c
    end

    test "an explicit name that is held is an error, not silently renamed",
         %{base: base, fresh: fresh} do
      assert {:error, _} =
               :peer.call(fresh, NodeUtil, :start_host_dist, [:"#{base}@127.0.0.1", :c, base])

      refute :peer.call(fresh, Node, :alive?, [])
    end
  end
end
