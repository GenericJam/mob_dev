defmodule MobDev.TunnelAdbMissingTest do
  # async: false — mutates the OS-process-global PATH. Kept out of the main
  # (async) tunnel_test so it never overlaps a concurrent reader.
  use ExUnit.Case, async: false

  alias MobDev.Tunnel

  describe "adb absent from PATH (iOS-only Mac)" do
    setup do
      original = System.get_env("PATH")

      # Point PATH at a dir that has epmd (ports_in_use queries it too) but not
      # adb, so we exercise exactly the missing-adb path.
      dir = Path.join(System.tmp_dir!(), "mob_dev_no_adb_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      case :os.find_executable(~c"epmd") do
        false -> flunk("epmd not found on PATH — cannot set up the no-adb fixture")
        epmd -> File.ln_s!(to_string(epmd), Path.join(dir, "epmd"))
      end

      System.put_env("PATH", dir)
      refute System.find_executable("adb"), "fixture leaked an adb on PATH"

      on_exit(fn ->
        if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "ports_in_use/1 degrades to a MapSet instead of crashing on :enoent" do
      # Regression: run_adb shelled out to a missing `adb`; System.cmd raised
      # :enoent inside a linked Task, propagating an exit that killed the whole
      # `mix mob.connect` for iOS-only Macs. It must now return the (adb-less)
      # port set without raising — forwards simply read as "none".
      assert %MapSet{} = Tunnel.ports_in_use()
    end
  end
end
