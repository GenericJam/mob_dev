defmodule Mix.Tasks.Mob.ConnectTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Connect

  test "ensure_iex_started/0 starts the IEx application" do
    Application.stop(:iex)

    assert :ok = Connect.ensure_iex_started()
    assert {:ok, _} = Application.ensure_all_started(:iex)
  end
end
