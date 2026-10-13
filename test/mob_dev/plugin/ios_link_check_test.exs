defmodule MobDev.Plugin.IosLinkCheckTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.IosLinkCheck

  describe "against real archives (MOB-470's shape)" do
    # Needs Xcode's iOS simulator SDK: builds tiny archives with clang.
    @describetag :macos_only
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      # A stand-in OTP runtime: its libbeam.a defines the one enif_* the
      # fixtures call, the way the real one defines the whole API.
      otp = Path.join(tmp, "otp")
      File.mkdir_p!(Path.join(otp, "erts-99/lib"))

      beam_o =
        compile!(tmp, "erl_nif.c", "int enif_make_atom(void *env, const char *n) { return 0; }")

      ar!(Path.join(otp, "erts-99/lib/libbeam.a"), [beam_o])

      # A stand-in mob checkout: mob core defines the permission hook plugins call.
      mob = Path.join(tmp, "mob")
      File.mkdir_p!(Path.join(mob, "ios"))

      File.write!(Path.join(mob, "ios/mob_nif.m"), """
      static int helper(void) { return 0; }
      void mob_register_permission_handler(const char *cap, void (*fn)(void *pid)) {
        (void)cap; (void)fn;
      }
      """)

      {:ok, otp: otp, mob: mob, spec: %{plugin: :fixture_plugin, module: :fixture_nif}}
    end

    test "an archive whose undefined symbols the BEAM, mob core and the SDK define passes",
         %{tmp_dir: tmp, otp: otp, mob: mob, spec: spec} do
      archive =
        archive!(tmp, "clean", """
        #include <stdlib.h>
        extern int enif_make_atom(void *env, const char *n);
        extern void mob_register_permission_handler(const char *cap, void (*fn)(void *pid));
        static void on_permission(void *pid) { (void)pid; }
        int fixture_nif_nif_init(void) {
          mob_register_permission_handler("fixture", on_permission);
          return enif_make_atom(0, "ok") + (int)(long)malloc(1);
        }
        """)

      assert IosLinkCheck.check(spec, :ios_sim, archive, [], otp_dir: otp, mob_dir: mob) == :ok
    end

    test "a dangling reference in code a dead-stripping link drops fails, naming plugin, symbol and member",
         %{tmp_dir: tmp, otp: otp, mob: mob, spec: spec} do
      archive =
        archive!(tmp, "mob470", """
        extern int enif_make_atom(void *env, const char *n);
        extern void *ggml_dl_load_library(const char *path);
        int fixture_nif_nif_init(void) { return enif_make_atom(0, "ok"); }
        // Nothing calls this, so -dead_strip removes it (MOB-470: ggml's dl_* helpers).
        void *fixture_load_backend(const char *p) { return ggml_dl_load_library(p); }
        """)

      # The shape that hid MOB-470: the app's dead-stripping link passes, the
      # same link without -dead_strip fails.
      assert {_, 0} = link(tmp, archive, ["-Xlinker", "-dead_strip"], otp)
      assert {_, status} = link(tmp, archive, [], otp)
      assert status != 0

      assert {:error, msg} =
               IosLinkCheck.check(spec, :ios_sim, archive, [], otp_dir: otp, mob_dir: mob)

      assert msg =~ "fixture_plugin"
      assert msg =~ "_ggml_dl_load_library"
      assert msg =~ "mob470.o"
      refute msg =~ "_enif_make_atom"
    end

    test "mob core's symbols are allowed only from the mob checkout it is given",
         %{tmp_dir: tmp, otp: otp, spec: spec} do
      archive =
        archive!(tmp, "uses_mob", """
        extern void mob_register_permission_handler(const char *cap, void (*fn)(void *pid));
        int fixture_nif_nif_init(void) { mob_register_permission_handler("x", 0); return 0; }
        """)

      assert {:error, msg} = IosLinkCheck.check(spec, :ios_sim, archive, [], otp_dir: otp)
      assert msg =~ "_mob_register_permission_handler"
    end
  end

  describe "defined_symbols/1" do
    test "lists external functions, globals and ObjC classes, not static ones" do
      source = """
      static int hidden(void) { return 0; }
      static const char *also_hidden = "x";
      extern int declared_elsewhere(void);
      int counter = 0;
      void mob_register_permission_handler(const char *cap,
                                           void (*fn)(void *pid)) {
        (void)cap;
      }
      @implementation MobNode
      @end
      """

      assert Enum.sort(IosLinkCheck.defined_symbols(source)) ==
               Enum.sort([
                 "_counter",
                 "_mob_register_permission_handler",
                 "_OBJC_CLASS_$_MobNode",
                 "_OBJC_METACLASS_$_MobNode"
               ])
    end
  end

  describe "tbd_name/1" do
    test "ObjC class symbols are looked up by class name, C symbols as they are" do
      assert IosLinkCheck.tbd_name("_OBJC_CLASS_$_EAGLContext") == "EAGLContext"
      assert IosLinkCheck.tbd_name("_OBJC_METACLASS_$_UIView") == "UIView"
      assert IosLinkCheck.tbd_name("_glBindBuffer") == "_glBindBuffer"
    end
  end

  describe "sdk_exports/2" do
    @describetag :tmp_dir

    test "matches whole names only", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "Lib.tbd"), """
      exports:
        - symbols: [ _glBindBuffer, _glBindBufferBase ]
          objc-classes: [ EAGLContext ]
      """)

      assert IosLinkCheck.sdk_exports(tmp, ["_glBindBuffer", "_glBind", "EAGLContext", "EAGL"]) ==
               MapSet.new(["_glBindBuffer", "EAGLContext"])
    end
  end

  defp compile!(dir, name, source) do
    src = Path.join(dir, name)
    obj = Path.rootname(src) <> ".o"
    File.write!(src, source)

    {out, status} =
      System.cmd(
        "xcrun",
        ["-sdk", "iphonesimulator", "clang", "-arch", "arm64"] ++
          ["-mios-simulator-version-min=17.0", "-ffunction-sections", "-c", src, "-o", obj],
        stderr_to_stdout: true
      )

    assert status == 0, out
    obj
  end

  defp ar!(archive, objects) do
    {out, status} = System.cmd("xcrun", ["ar", "rcs", archive | objects], stderr_to_stdout: true)
    assert status == 0, out
    archive
  end

  defp archive!(dir, name, source) do
    ar!(Path.join(dir, "lib#{name}.a"), [compile!(dir, "#{name}.c", source)])
  end

  # A link like the app's: the archive's init symbol is the root, the BEAM
  # supplies enif_*.
  defp link(dir, archive, flags, otp) do
    System.cmd(
      "xcrun",
      ["-sdk", "iphonesimulator", "clang", "-arch", "arm64", "-mios-simulator-version-min=17.0"] ++
        ["-dynamiclib", "-Wl,-u,_fixture_nif_nif_init"] ++
        ["-Wl,-exported_symbol,_fixture_nif_nif_init", archive] ++
        [Path.join(otp, "erts-99/lib/libbeam.a")] ++
        flags ++ ["-o", Path.join(dir, "app.dylib")],
      stderr_to_stdout: true
    )
  end
end
