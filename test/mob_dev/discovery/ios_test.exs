defmodule MobDev.Discovery.IOSTest do
  use ExUnit.Case, async: true

  alias MobDev.Discovery.IOS
  alias MobDev.Device

  # ── parse_simctl_json/1 ───────────────────────────────────────────────────────

  describe "parse_simctl_json/1" do
    test "parses a booted simulator" do
      json =
        Jason.encode!(%{
          "devices" => %{
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
              %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Booted"}
            ]
          }
        })

      [device] = IOS.parse_simctl_json(json)
      assert device.serial == "ABC-123"
      assert device.name == "iPhone 15"
      assert device.platform == :ios
      assert device.type == :simulator
      assert device.status == :booted
      assert device.version == "iOS 18.0"
    end

    test "skips non-booted simulators" do
      json =
        Jason.encode!(%{
          "devices" => %{
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
              %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Shutdown"},
              %{"udid" => "DEF-456", "name" => "iPhone 16", "state" => "Booted"}
            ]
          }
        })

      devices = IOS.parse_simctl_json(json)
      assert length(devices) == 1
      assert hd(devices).serial == "DEF-456"
    end

    test "returns empty list when no devices object" do
      json = Jason.encode!(%{"devices" => %{}})
      assert IOS.parse_simctl_json(json) == []
    end

    test "parses multiple booted simulators across runtimes" do
      json =
        Jason.encode!(%{
          "devices" => %{
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0" => [
              %{"udid" => "A1", "name" => "iPhone 14", "state" => "Booted"}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
              %{"udid" => "B2", "name" => "iPhone 15", "state" => "Booted"}
            ]
          }
        })

      devices = IOS.parse_simctl_json(json)
      assert length(devices) == 2
      serials = Enum.map(devices, & &1.serial)
      assert "A1" in serials
      assert "B2" in serials
    end

    test "assigns node name to each device" do
      app = Mix.Project.config()[:app]
      # UDID "ABC-123" → strip hyphens "ABC123" → first 8 lowercase → "abc123"
      json =
        Jason.encode!(%{
          "devices" => %{
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
              %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Booted"}
            ]
          }
        })

      [device] = IOS.parse_simctl_json(json)
      assert device.node == :"#{app}_ios_abc123@127.0.0.1"
    end
  end

  # ── parse_simctl_text/1 ───────────────────────────────────────────────────────

  describe "parse_simctl_text/1" do
    test "parses booted simulator line" do
      text = """
      == Booted ==
          iPhone 17 (78354490-EF38-44D7-A437-DD941C20524D) (Booted)
      """

      [device] = IOS.parse_simctl_text(text)
      assert device.serial == "78354490-EF38-44D7-A437-DD941C20524D"
      assert device.name == "iPhone 17"
      assert device.platform == :ios
    end

    test "skips shutdown simulator lines" do
      text = """
      == Shutdown ==
          iPhone 14 (AABB-CCDD-1234-5678-ABCDEFABCDEF) (Shutdown)
      """

      assert IOS.parse_simctl_text(text) == []
    end

    test "parses multiple booted simulators" do
      text = """
          iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEFFFFFF) (Booted)
          iPad Pro  (FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBAAAAA1) (Booted)
      """

      devices = IOS.parse_simctl_text(text)
      assert length(devices) == 2
    end
  end

  # ── parse_runtime_version/1 ───────────────────────────────────────────────────

  describe "parse_runtime_version/1" do
    test "parses iOS-18-0 style" do
      assert IOS.parse_runtime_version("com.apple.CoreSimulator.SimRuntime.iOS-18-0") ==
               "iOS 18.0"
    end

    test "parses iOS-17-4 style" do
      assert IOS.parse_runtime_version("com.apple.CoreSimulator.SimRuntime.iOS-17-4") ==
               "iOS 17.4"
    end

    test "falls back gracefully for unknown format" do
      assert IOS.parse_runtime_version("some.unknown.runtime.foo") == "foo"
    end
  end

  # ── integration: list_simulators/0 ───────────────────────────────────────────

  @tag :integration
  test "list_simulators returns a list" do
    result = IOS.list_simulators()
    assert Enum.all?(result, &match?(%Device{}, &1))
  end

  # ── build_simctl_env/2 ───────────────────────────────────────────────────────
  # Pure-function helper extracted from launch_app/3 so the override surface
  # is unit-testable without spawning simctl. Covers the `mix mob.deploy
  # --node-suffix X --dist-port N` plumbing — once those reach IOS.launch_app
  # they must come out as the right SIMCTL_CHILD_* vars (mob_beam.m strips
  # the prefix at startup, so the child process sees MOB_NODE_SUFFIX /
  # MOB_DIST_PORT directly).

  describe "build_simctl_env/2" do
    test "always emits MOB_DIST_PORT (default 9100) and MOB_SIM_RUNTIME_DIR" do
      env = IOS.build_simctl_env([], "/tmp/runtime")
      assert {"SIMCTL_CHILD_MOB_DIST_PORT", "9100"} in env
      assert {"SIMCTL_CHILD_MOB_SIM_RUNTIME_DIR", "/tmp/runtime"} in env
    end

    test "explicit :dist_port overrides the default" do
      env = IOS.build_simctl_env([dist_port: 9120], "/tmp/runtime")
      assert {"SIMCTL_CHILD_MOB_DIST_PORT", "9120"} in env
      refute {"SIMCTL_CHILD_MOB_DIST_PORT", "9100"} in env
    end

    test "omits MOB_NODE_SUFFIX when :node_suffix is nil (auto-derive in mob_beam.m)" do
      env = IOS.build_simctl_env([], "/tmp/runtime")
      keys = Enum.map(env, fn {k, _} -> k end)
      refute "SIMCTL_CHILD_MOB_NODE_SUFFIX" in keys
    end

    test "omits MOB_NODE_SUFFIX when :node_suffix is the empty string" do
      env = IOS.build_simctl_env([node_suffix: ""], "/tmp/runtime")
      keys = Enum.map(env, fn {k, _} -> k end)
      refute "SIMCTL_CHILD_MOB_NODE_SUFFIX" in keys
    end

    test "emits MOB_NODE_SUFFIX when :node_suffix is a non-empty string" do
      env = IOS.build_simctl_env([node_suffix: "alt"], "/tmp/runtime")
      assert {"SIMCTL_CHILD_MOB_NODE_SUFFIX", "alt"} in env
    end

    test "passes node_suffix verbatim (no sanitisation at this layer)" do
      env = IOS.build_simctl_env([node_suffix: "Has-Dashes_And_Underscores"], "/tmp/runtime")
      assert {"SIMCTL_CHILD_MOB_NODE_SUFFIX", "Has-Dashes_And_Underscores"} in env
    end

    test "combines :dist_port + :node_suffix overrides cleanly" do
      env = IOS.build_simctl_env([dist_port: 9120, node_suffix: "alt"], "/tmp/runtime")
      assert {"SIMCTL_CHILD_MOB_DIST_PORT", "9120"} in env
      assert {"SIMCTL_CHILD_MOB_NODE_SUFFIX", "alt"} in env
    end
  end

  # ── EPMD node resolution (MOB-283) ───────────────────────────────────────────
  # A phone's EPMD can list more than one Mob app; mob.connect must attach to
  # this project's node, at the IP the node is actually named after.

  # NAMES_REQ reply: 4-byte EPMD port (4369), then one line per node.
  @two_apps <<0, 0, 17, 17>> <>
              "name muster_app_ios at port 9102\nname scanner_sample_ios at port 9101\n"

  describe "parse_epmd_names/1" do
    test "returns every registered node, not just the first" do
      assert IOS.parse_epmd_names(@two_apps) == [
               {"muster_app_ios", 9102},
               {"scanner_sample_ios", 9101}
             ]
    end

    test "an EPMD with nothing registered yields no entries" do
      assert IOS.parse_epmd_names(<<0, 0, 17, 17>>) == []
    end
  end

  describe "select_ios_node/2" do
    test "picks the project's node when another app's is listed first" do
      entries = IOS.parse_epmd_names(@two_apps)
      assert IOS.select_ios_node(entries, "scanner_sample_ios") == {"scanner_sample_ios", 9101}
    end

    test "another app's node alone is not the project's node" do
      entries = [{"muster_app_ios", 9102}]
      assert IOS.select_ios_node(entries, "scanner_sample_ios") == nil
    end

    test "an app whose name extends the project's is not a suffixed match" do
      # project `scanner` → base `scanner_ios`; `scanner_sample` is a different app
      assert IOS.select_ios_node([{"scanner_sample_ios", 9101}], "scanner_ios") == nil
    end

    test "accepts the MOB_NODE_SUFFIX form <app>_ios_<suffix>" do
      entries = [{"muster_app_ios", 9102}, {"scanner_sample_ios_alt", 9103}]

      assert IOS.select_ios_node(entries, "scanner_sample_ios") ==
               {"scanner_sample_ios_alt", 9103}
    end

    test "the unsuffixed node wins over a suffixed one" do
      entries = [{"scanner_sample_ios_alt", 9103}, {"scanner_sample_ios", 9101}]
      assert IOS.select_ios_node(entries, "scanner_sample_ios") == {"scanner_sample_ios", 9101}
    end

    test "with no project app, falls back to the first *_ios node" do
      entries = [{"mob_dev", 9000}, {"muster_app_ios", 9102}, {"scanner_sample_ios", 9101}]
      assert IOS.select_ios_node(entries, nil) == {"muster_app_ios", 9102}
    end

    test "with no project app and no *_ios node, returns nil" do
      assert IOS.select_ios_node([{"mob_dev", 9000}], nil) == nil
    end
  end

  describe "choose_usb_node/2" do
    # Second argument: EPMD probes of the cable-attached phone's own other
    # addresses (its mDNS name's IPv4s), never arbitrary LAN hosts.
    @wifi "10.0.0.121"
    @link_local "169.254.1.100"
    @app {:ok, "scanner_sample_ios", 9101}

    test "same BEAM on WiFi and link-local → the WiFi IP it is named after" do
      assert IOS.choose_usb_node({@link_local, @app}, [{@wifi, @app}]) ==
               {:registered, @wifi, "scanner_sample_ios", 9101}
    end

    test "the other address lists the app at a different dist port → link-local" do
      other = {@wifi, {:ok, "scanner_sample_ios", 9633}}

      assert IOS.choose_usb_node({@link_local, @app}, [other]) ==
               {:registered, @link_local, "scanner_sample_ios", 9101}
    end

    test "the other address lists a different node name → link-local" do
      other = {@wifi, {:ok, "scanner_sample_ios_alt", 9101}}

      assert IOS.choose_usb_node({@link_local, @app}, [other]) ==
               {:registered, @link_local, "scanner_sample_ios", 9101}
    end

    test "two other addresses both agree → link-local, not a guess between them" do
      probes = [{@wifi, @app}, {"100.101.102.103", @app}]

      assert IOS.choose_usb_node({@link_local, @app}, probes) ==
               {:registered, @link_local, "scanner_sample_ios", 9101}
    end

    test "link-local lists nothing → prediction, even if another address lists the app" do
      assert IOS.choose_usb_node({@link_local, {:error, :not_ios_node}}, [{@wifi, @app}]) ==
               {:predicted, @link_local}
    end

    test "nothing registered anywhere → link-local prediction" do
      probes = [{@wifi, {:error, :not_ios_node}}]

      assert IOS.choose_usb_node({@link_local, {:error, :not_ios_node}}, probes) ==
               {:predicted, @link_local}
    end

    test "no link-local IP → :none, even if another address lists the app" do
      assert IOS.choose_usb_node(nil, [{@wifi, @app}]) == :none
    end
  end

  describe "epmd_names/3" do
    # A local listener stands in for EPMD; the request bytes are ignored.
    defp serve_once(fun) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      spawn_link(fn ->
        {:ok, s} = :gen_tcp.accept(listen)
        fun.(s)
      end)

      port
    end

    test "reads a reply EPMD writes in pieces, up to close" do
      port =
        serve_once(fn s ->
          :gen_tcp.send(s, <<0, 0, 17, 17>>)
          Process.sleep(50)
          :gen_tcp.send(s, "name scanner_sample_ios at port 9101\n")
          :gen_tcp.close(s)
        end)

      assert IOS.epmd_names("127.0.0.1", port, 1_000) ==
               {:ok, <<0, 0, 17, 17>> <> "name scanner_sample_ios at port 9101\n"}
    end

    test "a peer that trickles bytes and never closes is cut off at the deadline" do
      # Stops once the client has closed (send fails), so nothing outlives the test.
      trickle = fn trickle, s ->
        with :ok <- :gen_tcp.send(s, "x") do
          Process.sleep(50)
          trickle.(trickle, s)
        end
      end

      port = serve_once(&trickle.(trickle, &1))
      task = Task.async(fn -> IOS.epmd_names("127.0.0.1", port, 300) end)

      assert Task.yield(task, 1_500) == {:ok, {:error, :epmd_unreachable}}
    end
  end

  describe "same_phone_ipv4s/3" do
    test "a resolver that never answers yields no addresses, within the deadline" do
      hang = fn _ip -> Process.sleep(:infinity) end
      task = Task.async(fn -> IOS.same_phone_ipv4s("169.254.1.100", hang, 200) end)

      assert Task.yield(task, 1_500) == {:ok, []}
    end
  end
end
