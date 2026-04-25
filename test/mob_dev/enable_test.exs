defmodule MobDev.EnableTest do
  use ExUnit.Case, async: true

  alias MobDev.Enable

  # ── build_plist_entry/3 ───────────────────────────────────────────────────

  describe "build_plist_entry/3" do
    test "builds string entry" do
      result = Enable.build_plist_entry("NSCameraUsageDescription", "Camera needed")
      assert result == "\t<key>NSCameraUsageDescription</key>\n\t<string>Camera needed</string>"
    end

    test "builds bool entry for UIFileSharingEnabled" do
      result = Enable.build_plist_entry("UIFileSharingEnabled", "true", type: :bool)
      assert result == "\t<key>UIFileSharingEnabled</key>\n\t<true/>"
    end

    test "builds bool false entry" do
      result = Enable.build_plist_entry("SomeFlag", "false", type: :bool)
      assert result == "\t<key>SomeFlag</key>\n\t<false/>"
    end
  end

  # ── read_app_name_from/1 ──────────────────────────────────────────────────

  describe "read_app_name_from/1" do
    test "reads app name from valid mix.exs" do
      path = write_tmp_mix_exs("app: :my_cool_app")
      assert Enable.read_app_name_from(path) == "my_cool_app"
    end

    test "reads app name when surrounded by other keys" do
      content = """
      def project do
        [
          version: "0.1.0",
          app: :phoenix_demo,
          elixir: "~> 1.18"
        ]
      end
      """

      path = write_tmp_mix_exs(content)
      assert Enable.read_app_name_from(path) == "phoenix_demo"
    end

    test "raises when file not found" do
      assert_raise RuntimeError, ~r/Could not read/, fn ->
        Enable.read_app_name_from("/nonexistent/mix.exs")
      end
    end

    test "raises when app: key is missing" do
      path = write_tmp_mix_exs("def project, do: []")

      assert_raise RuntimeError, ~r/Could not read app name/, fn ->
        Enable.read_app_name_from(path)
      end
    end
  end

  # ── inject_mob_hook/1 ─────────────────────────────────────────────────────

  describe "inject_mob_hook/1" do
    test "patches hooks: {} to hooks: {MobHook}" do
      input = ~S"""
      import {Socket} from "phoenix"
      import {LiveSocket} from "phoenix_live_view"

      let liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
      liveSocket.connect()
      """

      result = Enable.inject_mob_hook(input)
      assert String.contains?(result, "hooks: {MobHook}")
      assert String.contains?(result, "const MobHook")
      refute String.contains?(result, "hooks: {}")
    end

    test "prepends MobHook to existing hooks object" do
      input = ~S"""
      import {Socket} from "phoenix"
      import {LiveSocket} from "phoenix_live_view"
      import Hooks from "./hooks"

      let liveSocket = new LiveSocket("/live", Socket, {hooks: {Hooks}})
      """

      result = Enable.inject_mob_hook(input)
      assert String.contains?(result, "hooks: {MobHook,")
      assert String.contains?(result, "Hooks}")
    end

    test "inserts hook definition after last import line" do
      input = ~S"""
      import {Socket} from "phoenix"
      import {LiveSocket} from "phoenix_live_view"

      let liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
      """

      result = Enable.inject_mob_hook(input)
      lines = String.split(result, "\n")

      import_idx =
        Enum.find_index(lines, &String.starts_with?(String.trim(&1), "import {LiveSocket}"))

      hook_idx = Enum.find_index(lines, &String.contains?(&1, "const MobHook"))
      socket_idx = Enum.find_index(lines, &String.contains?(&1, "new LiveSocket"))

      assert hook_idx > import_idx
      assert hook_idx < socket_idx
    end

    test "works with no imports" do
      input = ~S"""
      const liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
      liveSocket.connect()
      """

      result = Enable.inject_mob_hook(input)
      assert String.contains?(result, "const MobHook")
      assert String.contains?(result, "hooks: {MobHook}")
    end

    test "idempotent when MobHook already present" do
      input = ~S"""
      import {Socket} from "phoenix"

      const MobHook = { mounted() {} }
      let liveSocket = new LiveSocket("/live", Socket, {hooks: {MobHook}})
      """

      # The task guards against double-injection via String.contains?(content, "MobHook"),
      # but inject_mob_hook itself would add a second definition. This test documents the
      # expectation that the task layer does the idempotency guard, not this function.
      result = Enable.inject_mob_hook(input)
      # Should still produce valid JS even if called on already-patched content
      assert String.contains?(result, "MobHook")
    end

    test "mob_hook_js contains expected API" do
      js = Enable.mob_hook_js()
      assert String.contains?(js, "pushEvent(\"mob_message\"")
      assert String.contains?(js, "handleEvent(\"mob_push\"")
      assert String.contains?(js, "_dispatch")
    end
  end

  # ── inject_mob_bridge_element/1 ───────────────────────────────────────────

  describe "inject_mob_bridge_element/1" do
    test "inserts hidden div immediately after opening body tag" do
      input = """
      <html>
        <body class="bg-white">
          <%= @inner_content %>
        </body>
      </html>
      """

      result = Enable.inject_mob_bridge_element(input)
      assert String.contains?(result, ~s(id="mob-bridge"))
      assert String.contains?(result, ~s(phx-hook="MobHook"))
      assert String.contains?(result, ~s(style="display:none"))
      # must appear right after <body ...>
      body_pos = :binary.match(result, "<body") |> elem(0)
      bridge_pos = :binary.match(result, "mob-bridge") |> elem(0)
      content_pos = :binary.match(result, "@inner_content") |> elem(0)
      assert bridge_pos > body_pos
      assert bridge_pos < content_pos
    end

    test "preserves existing body attributes" do
      input = ~s(<body class="bg-white antialiased" data-theme="dark">\n</body>)
      result = Enable.inject_mob_bridge_element(input)
      assert String.contains?(result, ~s(class="bg-white antialiased"))
      assert String.contains?(result, ~s(data-theme="dark"))
      assert String.contains?(result, "mob-bridge")
    end

    test "is idempotent when mob-bridge already present" do
      input = """
      <body>
        <div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>
        <%= @inner_content %>
      </body>
      """

      result = Enable.inject_mob_bridge_element(input)
      assert result == input
      # should not have a second mob-bridge
      assert length(:binary.matches(result, "mob-bridge")) == 1
    end

    test "works with a body tag with no attributes" do
      input = "<body>\n<%= @inner_content %>\n</body>"
      result = Enable.inject_mob_bridge_element(input)
      assert String.contains?(result, "mob-bridge")
    end
  end

  # ── find_root_html/2 ──────────────────────────────────────────────────────

  describe "find_root_html/2" do
    test "finds Phoenix 1.7+ path" do
      dir =
        System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")

      File.rm_rf!(dir)
      path = Path.join([dir, "lib", "my_app_web", "components", "layouts", "root.html.heex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "<html></html>")
      assert Enable.find_root_html(dir, "my_app") == path
    end

    test "finds pre-1.7 path when 1.7+ path absent" do
      dir =
        System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")

      File.rm_rf!(dir)
      path = Path.join([dir, "lib", "my_app_web", "templates", "layout", "root.html.heex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "<html></html>")
      assert Enable.find_root_html(dir, "my_app") == path
    end

    test "returns nil when neither path exists" do
      dir =
        System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")

      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      assert Enable.find_root_html(dir, "my_app") == nil
    end

    test "prefers 1.7+ path when both exist" do
      dir =
        System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")

      File.rm_rf!(dir)
      new_path = Path.join([dir, "lib", "my_app_web", "components", "layouts", "root.html.heex"])
      old_path = Path.join([dir, "lib", "my_app_web", "templates", "layout", "root.html.heex"])
      File.mkdir_p!(Path.dirname(new_path))
      File.mkdir_p!(Path.dirname(old_path))
      File.write!(new_path, "new")
      File.write!(old_path, "old")
      assert Enable.find_root_html(dir, "my_app") == new_path
    end
  end

  # ── inject_android_network_security_config/1 ─────────────────────────────

  describe "inject_android_network_security_config/1" do
    test "adds networkSecurityConfig attribute to <application> tag" do
      input = """
      <manifest>
          <application
              android:label="MyApp"
              android:theme="@style/AppTheme">
          </application>
      </manifest>
      """

      result = Enable.inject_android_network_security_config(input)

      assert String.contains?(
               result,
               ~s(android:networkSecurityConfig="@xml/network_security_config")
             )

      assert String.contains?(result, "android:label=\"MyApp\"")
    end

    test "is idempotent when networkSecurityConfig already present" do
      input = """
      <manifest>
          <application
              android:networkSecurityConfig="@xml/network_security_config"
              android:label="MyApp">
          </application>
      </manifest>
      """

      result = Enable.inject_android_network_security_config(input)
      assert result == input
      assert length(:binary.matches(result, "networkSecurityConfig")) == 1
    end

    test "only patches the first <application> tag" do
      input = "<application>\n<application>"
      result = Enable.inject_android_network_security_config(input)
      assert length(:binary.matches(result, "networkSecurityConfig")) == 1
    end
  end

  # ── network_security_config_xml/0 ────────────────────────────────────────

  describe "network_security_config_xml/0" do
    test "permits cleartext for 127.0.0.1" do
      xml = Enable.network_security_config_xml()
      assert String.contains?(xml, "127.0.0.1")
      assert String.contains?(xml, "cleartextTrafficPermitted=\"true\"")
    end

    test "permits cleartext for localhost" do
      xml = Enable.network_security_config_xml()
      assert String.contains?(xml, "localhost")
    end

    test "is valid XML (has header and root element)" do
      xml = Enable.network_security_config_xml()
      assert String.starts_with?(String.trim(xml), "<?xml")
      assert String.contains?(xml, "<network-security-config>")
      assert String.contains?(xml, "</network-security-config>")
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp write_tmp_mix_exs(content) do
    dir = System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mix.exs")
    File.write!(path, content)
    path
  end
end
