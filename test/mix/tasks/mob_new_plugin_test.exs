defmodule Mix.Tasks.Mob.NewPluginTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.NewPlugin

  describe "invalid_option_message/1" do
    test "empty invalid list is :ok" do
      assert NewPlugin.invalid_option_message([]) == :ok
    end

    test "a bad-typed switch value is reported, not silently dropped" do
      assert {:error, msg} = NewPlugin.invalid_option_message([{"--tier", "abc"}])
      assert msg =~ "--tier abc"
      assert msg =~ "invalid option"
    end

    test "an unknown flag is reported" do
      assert {:error, msg} = NewPlugin.invalid_option_message([{"--bogus", nil}])
      assert msg =~ "--bogus"
    end

    test "multiple invalid options are all listed" do
      assert {:error, msg} =
               NewPlugin.invalid_option_message([{"--tier", "two"}, {"--nope", nil}])

      assert msg =~ "--tier two"
      assert msg =~ "--nope"
    end
  end
end
