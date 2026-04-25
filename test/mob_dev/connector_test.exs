defmodule MobDev.ConnectorTest do
  use ExUnit.Case, async: true

  alias MobDev.Connector

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
      Connector.start_epmd()
      Connector.start_epmd()
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
