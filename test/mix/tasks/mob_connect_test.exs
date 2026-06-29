defmodule Mix.Tasks.Mob.ConnectTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Connect

  test "ensure_iex_started/0 starts the IEx application" do
    Application.stop(:iex)

    assert :ok = Connect.ensure_iex_started()
    assert {:ok, _} = Application.ensure_all_started(:iex)
  end

  describe "resolve_platforms/2" do
    test "no flags uses the supplied default" do
      assert Connect.resolve_platforms([], [:android, :ios]) == {:ok, [:android, :ios]}
      assert Connect.resolve_platforms([], [:ios]) == {:ok, [:ios]}
    end

    test "--ios-only restricts to iOS, overriding the default" do
      assert Connect.resolve_platforms([ios_only: true], [:android, :ios]) == {:ok, [:ios]}
    end

    test "--android-only restricts to Android, overriding the default" do
      assert Connect.resolve_platforms([android_only: true], [:android, :ios]) ==
               {:ok, [:android]}
    end

    test "combining both flags is an error" do
      assert {:error, message} =
               Connect.resolve_platforms([ios_only: true, android_only: true], [:android, :ios])

      assert message =~ "--ios-only"
      assert message =~ "--android-only"
    end
  end
end
