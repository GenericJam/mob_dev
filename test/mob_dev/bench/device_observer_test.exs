defmodule MobDev.Bench.DeviceObserverTest do
  use ExUnit.Case, async: true

  alias MobDev.Bench.{DeviceObserver, Probe}

  describe "subscribe/2" do
    test "nil node returns an unsubscribed observer with default state" do
      obs = DeviceObserver.subscribe(nil, [])
      refute obs.subscribed?
      assert obs.screen == :unknown
      assert obs.app == :unknown
      assert obs.events == []
    end

    test "non-existent node fails gracefully (subscribed? false)" do
      obs = DeviceObserver.subscribe(:"phantom@127.0.0.1", [])
      refute obs.subscribed?
      assert obs.screen == :unknown
    end
  end

  describe "apply_event/3 — state transitions" do
    setup do
      obs = DeviceObserver.subscribe(nil, [])
      {:ok, obs: obs}
    end

    test "screen_off sets screen to :off", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :screen_off, nil)
      assert obs2.screen == :off
    end

    test "screen_on sets screen to :on", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :screen_on, nil)
      assert obs2.screen == :on
    end

    test "did_enter_background sets app to :background", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :did_enter_background, nil)
      assert obs2.app == :background
    end

    test "did_become_active sets app to :running", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :did_become_active, nil)
      assert obs2.app == :running
    end

    test "will_terminate sets app to :suspended", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :will_terminate, nil)
      assert obs2.app == :suspended
    end

    test "memory_warning doesn't change screen/app state", %{obs: obs} do
      obs2 = DeviceObserver.apply_event(obs, :memory_warning, nil)
      assert obs2.screen == obs.screen
      assert obs2.app == obs.app
    end

    test "events are accumulated newest-first", %{obs: obs} do
      obs1 = DeviceObserver.apply_event(obs, :screen_off, nil)
      Process.sleep(2)
      obs2 = DeviceObserver.apply_event(obs1, :did_enter_background, nil)
      Process.sleep(2)
      obs3 = DeviceObserver.apply_event(obs2, :screen_on, nil)

      events = Enum.map(obs3.events, fn {_ts, ev, _} -> ev end)
      assert events == [:screen_on, :did_enter_background, :screen_off]
    end

    test "events list is capped at @max_events_kept", %{obs: obs} do
      final =
        Enum.reduce(1..200, obs, fn _, acc ->
          DeviceObserver.apply_event(acc, :memory_warning, nil)
        end)

      assert length(final.events) <= 100
    end
  end

  describe "consume_messages/1" do
    setup do
      obs = DeviceObserver.subscribe(nil, [])
      {:ok, obs: obs}
    end

    test "drains messages from the mailbox", %{obs: obs} do
      send(self(), {:mob_device, :screen_off})
      send(self(), {:mob_device, :did_enter_background})

      obs = DeviceObserver.consume_messages(obs)

      assert obs.screen == :off
      assert obs.app == :background
    end

    test "events from consume_messages preserved newest-first", %{obs: obs} do
      send(self(), {:mob_device, :screen_off})
      send(self(), {:mob_device, :screen_on})

      obs = DeviceObserver.consume_messages(obs)

      events = Enum.map(obs.events, fn {_ts, ev, _} -> ev end)
      assert events == [:screen_on, :screen_off]
      assert obs.screen == :on
    end

    test "messages with payload are accepted", %{obs: obs} do
      send(self(), {:mob_device, :thermal_state_changed, :serious})

      obs = DeviceObserver.consume_messages(obs)

      [{_ts, ev, payload}] = obs.events
      assert ev == :thermal_state_changed
      assert payload == :serious
    end

    test "non-mob_device messages are not consumed (left in mailbox)", %{obs: obs} do
      send(self(), :other_message)
      send(self(), {:mob_device, :screen_off})

      obs = DeviceObserver.consume_messages(obs)
      assert obs.screen == :off

      # The non-mob_device message should still be there.
      assert_receive :other_message
    end

    test "no messages → no change", %{obs: obs} do
      obs2 = DeviceObserver.consume_messages(obs)
      assert obs2 == obs
    end
  end

  describe "apply_to_probe/2" do
    test "observed screen state overrides probe's screen state" do
      obs = %DeviceObserver{
        node: nil,
        subscribed?: false,
        screen: :off,
        app: :unknown,
        last_event_ts_ms: nil,
        events: []
      }

      probe = %Probe{
        ts_ms: 0,
        reachability: :alive_rpc,
        app_process: :app_running,
        usb: :no_usb,
        screen: :on,
        battery_pct: 80,
        reason: nil
      }

      result = DeviceObserver.apply_to_probe(obs, probe)
      assert result.screen == :off
    end

    test "unknown observer state preserves probe's view" do
      obs = %DeviceObserver{
        node: nil,
        subscribed?: false,
        screen: :unknown,
        app: :unknown,
        last_event_ts_ms: nil,
        events: []
      }

      probe = %Probe{
        ts_ms: 0,
        reachability: :alive_rpc,
        app_process: :app_running,
        usb: :no_usb,
        screen: :off,
        battery_pct: 80,
        reason: nil
      }

      result = DeviceObserver.apply_to_probe(obs, probe)
      assert result.screen == :off
    end

    test "background app state translates to :app_running for probe" do
      obs = %DeviceObserver{
        node: nil,
        subscribed?: false,
        screen: :off,
        app: :background,
        last_event_ts_ms: nil,
        events: []
      }

      probe = %Probe{
        ts_ms: 0,
        reachability: :alive_rpc,
        app_process: :app_unknown,
        usb: :no_usb,
        screen: :unknown,
        battery_pct: nil,
        reason: nil
      }

      result = DeviceObserver.apply_to_probe(obs, probe)
      # background = still running, just not in foreground — battery bench
      # treats it the same as app_running.
      assert result.app_process == :app_running
    end

    test "suspended app state propagates to probe" do
      obs = %DeviceObserver{
        node: nil,
        subscribed?: false,
        screen: :off,
        app: :suspended,
        last_event_ts_ms: nil,
        events: []
      }

      probe = %Probe{
        ts_ms: 0,
        reachability: :alive_dist_only,
        app_process: :app_unknown,
        usb: :no_usb,
        screen: :unknown,
        battery_pct: nil,
        reason: nil
      }

      result = DeviceObserver.apply_to_probe(obs, probe)
      assert result.app_process == :app_suspended
    end
  end
end
