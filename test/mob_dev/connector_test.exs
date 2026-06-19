defmodule MobDev.ConnectorTest do
  use ExUnit.Case, async: true

  alias MobDev.Connector
  alias MobDev.Device

  # ── filter_only/2 ────────────────────────────────────────────────────────────

  describe "filter_only/2" do
    setup do
      devices = [
        %Device{serial: "ZY22CRLMWK", platform: :android},
        %Device{serial: "ZY22DP6HFL", platform: :android},
        %Device{serial: "00008110-001E1C3A34F8401E", platform: :ios}
      ]

      {:ok, devices: devices}
    end

    test "empty pattern list is a no-op (connect to all)", %{devices: devices} do
      assert Connector.filter_only(devices, []) == devices
    end

    test "matches a single serial substring", %{devices: devices} do
      assert [%Device{serial: "ZY22CRLMWK"}] = Connector.filter_only(devices, ["ZY22CRLMWK"])
    end

    test "matching is case-insensitive", %{devices: devices} do
      assert [%Device{serial: "ZY22CRLMWK"}] = Connector.filter_only(devices, ["zy22crlmwk"])
    end

    test "partial substrings match", %{devices: devices} do
      # both Motos share the ZY22 prefix
      result = Connector.filter_only(devices, ["ZY22"])
      assert length(result) == 2
    end

    test "multiple patterns union their matches", %{devices: devices} do
      result = Connector.filter_only(devices, ["CRLMWK", "00008110"])
      serials = Enum.map(result, & &1.serial)
      assert "ZY22CRLMWK" in serials
      assert "00008110-001E1C3A34F8401E" in serials
      refute "ZY22DP6HFL" in serials
    end

    test "no match yields an empty list", %{devices: devices} do
      assert Connector.filter_only(devices, ["nonexistent"]) == []
    end
  end

  # ── start_epmd/0 ─────────────────────────────────────────────────────────────

  describe "start_epmd/0" do
    test "returns without raising" do
      # epmd is present on any OTP install; just verify it doesn't crash.
      # Returns {output, exit_code} when epmd is found, :ok when not in PATH.
      result = Connector.start_epmd()
      assert result == :ok or match?({_, _}, result)
    end

    test "is safe to call multiple times" do
      # epmd -daemon is idempotent — subsequent calls exit 0 immediately.
      r1 = Connector.start_epmd()
      r2 = Connector.start_epmd()
      assert r1 == :ok or match?({_, _}, r1)
      assert r2 == :ok or match?({_, _}, r2)
    end
  end

  # ── handle_dist_start/2 ───────────────────────────────────────────────────────

  describe "handle_dist_start/2" do
    test "raises Mix.Error with epmd hint on generic failure" do
      assert_raise Mix.Error, ~r/epmd -daemon/, fn ->
        Connector.handle_dist_start({:error, :econnrefused}, :mob_secret)
      end
    end

    test "error message includes the failure reason" do
      assert_raise Mix.Error, ~r/econnrefused/, fn ->
        Connector.handle_dist_start({:error, :econnrefused}, :mob_secret)
      end
    end

    test "error message points to mix mob.doctor" do
      assert_raise Mix.Error, ~r/mix mob\.doctor/, fn ->
        Connector.handle_dist_start({:error, :something_else}, :mob_secret)
      end
    end

    test "error message includes the retry instruction" do
      assert_raise Mix.Error, ~r/mix mob\.connect/, fn ->
        Connector.handle_dist_start({:error, :enoent}, :mob_secret)
      end
    end

    @tag :integration
    test "sets cookie when Node.start succeeds" do
      # Requires distribution — only run with --only integration.
      # Ensures the success path doesn't raise.
      case Node.start(
             :"connector_test_#{System.unique_integer([:positive])}@127.0.0.1",
             :longnames
           ) do
        {:ok, _} ->
          Connector.handle_dist_start({:ok, self()}, :test_cookie)
          assert Node.get_cookie() == :test_cookie

        {:error, {:already_started, _}} ->
          Connector.handle_dist_start({:error, {:already_started, self()}}, Node.get_cookie())

        {:error, _reason} ->
          # EPMD not available in this CI environment — skip rather than fail.
          :ok
      end
    end

    @tag :integration
    test "sets cookie on already_started" do
      # already_started means distribution is running — cookie update should succeed.
      case Node.start(
             :"connector_test2_#{System.unique_integer([:positive])}@127.0.0.1",
             :longnames
           ) do
        result when result in [{:ok, self()}, {:error, {:already_started, self()}}] ->
          Connector.handle_dist_start(
            {:error, {:already_started, self()}},
            :already_started_cookie
          )

          assert Node.get_cookie() == :already_started_cookie

        {:error, _} ->
          :ok
      end
    end
  end
end
