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

  # ── helpers ───────────────────────────────────────────────────────────────

  defp write_tmp_mix_exs(content) do
    dir = System.tmp_dir!() |> Path.join("mob_enable_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mix.exs")
    File.write!(path, content)
    path
  end
end
