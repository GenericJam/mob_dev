defmodule MobDev.OtpTraceTest do
  use ExUnit.Case, async: false

  alias MobDev.OtpTrace

  describe "capture/1" do
    test "records MFAs called inside the wrapped function" do
      result = OtpTrace.capture(fn -> Enum.map(1..5, &(&1 * 2)) end)

      # Enum is one of the modules called.
      assert MapSet.member?(result.modules, Enum)

      # And the specific Enum.map call appears.
      assert Enum.any?(result.mfas, fn
               {Enum, :map, 2} -> true
               _ -> false
             end)
    end

    test "records cross-module calls (lists, erlang BIFs, etc.)" do
      result = OtpTrace.capture(fn -> :lists.reverse([1, 2, 3]) end)

      assert MapSet.member?(result.modules, :lists)
    end

    test "elapsed_us is positive" do
      result = OtpTrace.capture(fn -> Process.sleep(5) end)
      assert result.elapsed_us > 0
    end

    test "excludes the tracer infrastructure modules" do
      result = OtpTrace.capture(fn -> :ok end)

      # The collector + trace module shouldn't show up in the captured MFAs
      # (the user is measuring their code, not our bookkeeping).
      refute MapSet.member?(result.modules, MobDev.OtpTrace)
      refute MapSet.member?(result.modules, MobDev.OtpTrace.Collector)
    end
  end
end
