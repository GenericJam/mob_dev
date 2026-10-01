defmodule MobDev.ZigBuildTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MobDev.ZigBuild

  # Real zig 0.17 (`--error-style minimal`) output of an iOS plugin NIF whose
  # ObjC compile fails, trimmed to the parts the report reads.
  @objc_failure """
  run xcrun (mob_demo_perm_nif.o) failure
  /private/tmp/app/plugins/mob_demo_perm/priv/native/ios/mob_demo_perm_nif.m:55:43: error: use of undeclared identifier 'mob344_undeclared_symbol'
     55 | static int mob344_injected(void) { return mob344_undeclared_symbol; }
        |                                           ^~~~~~~~~~~~~~~~~~~~~~~~
  1 error generated.
  error: process exited with error code 1

  Build Summary: 41/45 steps succeeded (1 failed)
  binary transitive failure
  +- install generated to MobPluginDemo transitive failure
     +- run xcrun (MobPluginDemo) transitive failure
        +- run xcrun (mob_demo_perm_nif.o) failure
  """

  @sources [
    {:mob_camera, "/Users/k/code/mob_camera/priv/native/ios/mob_camera_nif.m"},
    {:mob_demo_perm, "/tmp/app/plugins/mob_demo_perm/priv/native/ios/mob_demo_perm_nif.m"}
  ]

  describe "report/4" do
    test "a failed plugin NIF compile names the plugin and quotes the compiler error" do
      assert {:error, msg} =
               ZigBuild.report(@objc_failure, 2, "zig build binary (iOS sim)", @sources)

      assert msg =~ "zig build binary (iOS sim) exited 2"
      assert msg =~ "plugin mob_demo_perm: mob_demo_perm_nif.m failed to compile"
      assert msg =~ "error: use of undeclared identifier 'mob344_undeclared_symbol'"
      # The plugin that compiled fine isn't blamed, and the failure isn't
      # listed a second time as an anonymous step.
      refute msg =~ "mob_camera"
      refute msg =~ "failed step"
      refute msg =~ "process exited with error code"
    end

    test "a clang fatal error (missing header or module) is quoted too" do
      output = """
      run xcrun (mob_camera_nif.o) failure
      /Users/k/code/mob_camera/priv/native/ios/mob_camera_nif.m:12:9: fatal error: 'erl_nif.h' file not found
      1 error generated.
      error: process exited with error code 1
      """

      assert {:error, msg} = ZigBuild.report(output, 2, "zig build binary (iOS sim)", @sources)
      assert msg =~ "plugin mob_camera: mob_camera_nif.m failed to compile"
      assert msg =~ "fatal error: 'erl_nif.h' file not found"
    end

    test "a failure outside any plugin NIF still reports the failing step and its error" do
      output = """
      compile obj beam_main 1 errors
      /p/ios/beam_main.m:3:1: error: unknown type name 'oops'
      error: the following build command failed with exit code 1:
      """

      assert {:error, msg} = ZigBuild.report(output, 1, "zig build binary (iOS sim)", @sources)
      assert msg =~ "failed step: compile obj beam_main"
      assert msg =~ "/p/ios/beam_main.m:3:1: error: unknown type name 'oops'"
      refute msg =~ "plugin "
    end

    test "a successful build with a warning-only compile is ok and lists the warned step" do
      output = """
      run xcrun (mob_camera_nif.o) w
      /Users/k/code/mob_camera/priv/native/ios/mob_camera_nif.m:581:25: warning: 'isVideoOrientationSupported' is deprecated
      1 warning generated.
      """

      assert {:ok, ["run xcrun (mob_camera_nif.o)"]} =
               ZigBuild.report(output, 0, "zig build binary (iOS sim)", @sources)
    end
  end

  describe "run/4 against a real zig build" do
    @describetag :requires_zig
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      File.write!(Path.join(dir, "build.zig"), """
      const std = @import("std");
      pub fn build(b: *std.Build) void {
          const src = b.option([]const u8, "src", "") orelse "warn_nif.c";
          const run = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-c" });
          run.addFileArg(b.path(src));
          run.addArg("-o");
          const out = run.addOutputFileArg(b.fmt("{s}.o", .{std.fs.path.stem(src)}));
          b.getInstallStep().dependOn(&b.addInstallFile(out, "nif.o").step);
      }
      """)

      # zig caches both the build step and `zig cc` itself; a source it has
      # compiled before replays from cache without printing its warning again.
      # A per-run comment keeps every compile (and its output) real.
      stamp = "/* #{System.os_time()}-#{System.unique_integer([:positive])} */\n"

      File.write!(
        Path.join(dir, "warn_nif.c"),
        stamp <> "#define A 1\n#define A 2\nint warn_fn(void) { return A; }\n"
      )

      File.write!(
        Path.join(dir, "bad_nif.c"),
        stamp <> "int bad_fn(void) { return not_declared; }\n"
      )

      :ok
    end

    defp zig_build(dir, src) do
      args = ["build", "--build-file", Path.join(dir, "build.zig"), "-Dsrc=#{src}"]

      sources = [{:fake_plugin, Path.join(dir, src)}]

      out =
        capture_io(fn ->
          send(self(), {:result, ZigBuild.run(args, "zig build (test)", sources)})
        end)

      assert_received {:result, result}
      {result, out}
    end

    test "a compile that only warns succeeds without a `failed command` line", %{tmp_dir: dir} do
      {result, out} = zig_build(dir, "warn_nif.c")

      assert result == :ok
      assert out =~ "macro redefined"
      refute out =~ "failed command"
      assert out =~ "compiler warnings (not failures; the build succeeded)"
    end

    test "a compile error fails the build, naming the plugin and the error", %{tmp_dir: dir} do
      {result, _out} = zig_build(dir, "bad_nif.c")

      assert {:error, msg} = result
      assert msg =~ "plugin fake_plugin: bad_nif.c failed to compile"
      assert msg =~ "error: use of undeclared identifier 'not_declared'"
    end
  end
end
