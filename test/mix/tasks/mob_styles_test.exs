defmodule Mix.Tasks.Mob.StylesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "with no styles configured, points at the activation recipe" do
    out = capture_io(fn -> Mix.Tasks.Mob.Styles.run([]) end)
    assert out =~ "No style packages activated"
    assert out =~ "config :mob, :styles"
  end
end
