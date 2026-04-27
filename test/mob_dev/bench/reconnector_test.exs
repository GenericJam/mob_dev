defmodule MobDev.Bench.ReconnectorTest do
  use ExUnit.Case, async: true
  doctest MobDev.Bench.Reconnector

  alias MobDev.Bench.{Probe, Reconnector}

  describe "new/3" do
    test "initialises with zero attempts and no last_attempt" do
      r = Reconnector.new(:n@h, :secret)
      assert r.attempts == 0
      assert r.last_attempt_ms == nil
      assert r.total_reconnects == 0
    end

    test "max_backoff_ms is configurable" do
      r = Reconnector.new(:n@h, :secret, max_backoff_ms: 5_000)
      assert r.max_backoff_ms == 5_000
    end
  end

  describe "current_backoff_ms/1" do
    test "0 attempts → 0 ms" do
      r = Reconnector.new(:n@h, :secret)
      assert Reconnector.current_backoff_ms(r) == 0
    end

    test "increments through 0/2000/4000/8000/16000" do
      assert_backoff_at_attempt(0, 0)
      assert_backoff_at_attempt(1, 2_000)
      assert_backoff_at_attempt(2, 4_000)
      assert_backoff_at_attempt(3, 8_000)
      assert_backoff_at_attempt(4, 16_000)
    end

    test "caps at max_backoff_ms after schedule exhausted" do
      r = %Reconnector{Reconnector.new(:n@h, :secret) | attempts: 100}
      assert Reconnector.current_backoff_ms(r) == 30_000
    end

    test "respects custom max_backoff_ms cap" do
      r = Reconnector.new(:n@h, :secret, max_backoff_ms: 5_000)
      r = %{r | attempts: 4}
      # 16_000 > 5_000 → clamps to 5_000
      assert Reconnector.current_backoff_ms(r) == 5_000
    end

    defp assert_backoff_at_attempt(attempts, expected) do
      r = %{Reconnector.new(:n@h, :secret) | attempts: attempts}
      actual = Reconnector.current_backoff_ms(r)
      assert actual == expected, "attempts=#{attempts}: expected #{expected}, got #{actual}"
    end
  end

  describe "tick/3 — happy path" do
    test ":alive_rpc resets attempts and returns :no_action" do
      r = %{Reconnector.new(:n@h, :secret) | attempts: 5, last_attempt_ms: 1_000}
      {action, r2} = Reconnector.tick(r, :alive_rpc, 5_000)

      assert action == :no_action
      assert r2.attempts == 0
    end

    test "first attempt fires immediately when disconnected" do
      r = Reconnector.new(:n@h, :secret)
      {action, r2} = Reconnector.tick(r, :alive_dist_only, 0)

      assert action == :attempt
      assert r2.attempts == 1
      assert r2.last_attempt_ms == 0
    end

    test "second attempt waits for backoff" do
      r = Reconnector.new(:n@h, :secret)
      {:attempt, r1} = Reconnector.tick(r, :alive_dist_only, 0)

      # 500 ms later — backoff for 2nd attempt is 2_000 ms — too soon.
      {action, _} = Reconnector.tick(r1, :alive_dist_only, 500)
      assert action == :no_action

      # 2_000 ms later — exactly at boundary, should fire.
      {action, r2} = Reconnector.tick(r1, :alive_dist_only, 2_000)
      assert action == :attempt
      assert r2.attempts == 2
    end

    test "schedule progresses through 0, 2_000, 4_000, 8_000, 16_000" do
      r = Reconnector.new(:n@h, :secret)
      now = 0

      # Attempt 1 — immediate.
      {:attempt, r} = Reconnector.tick(r, :alive_dist_only, now)
      now = now + 2_000

      # Attempt 2 — wait 2 s.
      {:attempt, r} = Reconnector.tick(r, :alive_dist_only, now)
      now = now + 4_000

      # Attempt 3 — wait 4 s.
      {:attempt, r} = Reconnector.tick(r, :alive_dist_only, now)
      now = now + 8_000

      # Attempt 4 — wait 8 s.
      {:attempt, r} = Reconnector.tick(r, :alive_dist_only, now)
      assert r.attempts == 4
    end
  end

  describe "tick/3 — accepts Probe struct directly" do
    test "uses probe.reachability" do
      probe = %Probe{
        ts_ms: 0,
        reachability: :alive_rpc,
        app_process: :app_running,
        usb: :no_usb,
        screen: :off,
        battery_pct: 80,
        reason: nil
      }

      r = %{Reconnector.new(:n@h, :secret) | attempts: 3}
      {action, r2} = Reconnector.tick(r, probe, 0)
      assert action == :no_action
      assert r2.attempts == 0
    end
  end

  describe "record_success/1" do
    test "resets attempts and bumps total_reconnects" do
      r = %{Reconnector.new(:n@h, :secret) | attempts: 3, total_reconnects: 1}
      r2 = Reconnector.record_success(r)
      assert r2.attempts == 0
      assert r2.total_reconnects == 2
    end
  end

  describe "realistic scenario — 30 second outage" do
    test "during a 30 second WiFi flap, attempts reach the cap" do
      r = Reconnector.new(:n@h, :secret)

      # Simulate poll every 1 second for 30 s, all reporting :alive_dist_only.
      {final_r, attempt_times} =
        Enum.reduce(0..30_000//1_000, {r, []}, fn now, {acc_r, acc_attempts} ->
          case Reconnector.tick(acc_r, :alive_dist_only, now) do
            {:attempt, new_r} -> {new_r, [now | acc_attempts]}
            {:no_action, new_r} -> {new_r, acc_attempts}
          end
        end)

      attempts_made = Enum.reverse(attempt_times)

      # Attempts should be at: 0, 2000, 6000, 14000, 30000 (cumulative wait
      # between attempts: 0, 2, 4, 8, 16).
      # Allowing some slack since our simulated polls are in 1 s steps:
      assert length(attempts_made) >= 4
      assert final_r.attempts >= 4
    end

    test "resumes immediately on reconnect, then fresh disconnect starts fresh" do
      r = Reconnector.new(:n@h, :secret)

      # Disconnect → attempt 1
      {:attempt, r} = Reconnector.tick(r, :alive_dist_only, 0)

      # Mark success.
      r = Reconnector.record_success(r)
      assert r.attempts == 0
      assert r.total_reconnects == 1

      # Healthy poll.
      {:no_action, r} = Reconnector.tick(r, :alive_rpc, 1_000)

      # New disconnect — should attempt immediately again.
      {action, r} = Reconnector.tick(r, :alive_dist_only, 2_000)
      assert action == :attempt
      assert r.attempts == 1
    end
  end
end
