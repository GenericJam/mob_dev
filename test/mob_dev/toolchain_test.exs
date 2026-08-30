defmodule MobDev.ToolchainTest do
  use ExUnit.Case, async: true

  alias MobDev.Toolchain

  test "required Zig version stays in lockstep with .tool-versions" do
    tool_versions = File.read!(Path.expand("../../.tool-versions", __DIR__))

    assert tool_versions =~ "zig #{Toolchain.required_zig_version()}"
  end

  test "accepts the exact required Zig version" do
    version = Toolchain.required_zig_version()
    assert Toolchain.zig_status_from_result({version <> "\n", 0}) == {:ok, version}
  end

  test "rejects Zig 0.15.x" do
    assert Toolchain.zig_status_from_result({"0.15.2\n", 0}) ==
             {:version_mismatch, "0.15.2"}
  end

  test "rejects another nightly" do
    assert Toolchain.zig_status_from_result({"0.17.0-dev.270+different\n", 0}) ==
             {:version_mismatch, "0.17.0-dev.270+different"}
  end

  test "rejects a failed version command" do
    assert Toolchain.zig_status_from_result({"dyld failure\n", 127}) ==
             {:version_command_failed, "dyld failure", 127}
  end
end
