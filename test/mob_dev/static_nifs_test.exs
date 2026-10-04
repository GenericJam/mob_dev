defmodule MobDev.StaticNifsTest do
  use ExUnit.Case, async: true

  alias MobDev.StaticNifs

  describe "default_nifs/0" do
    test "includes the OTP/Erlang built-ins that hand-edited driver_tab listed" do
      modules = StaticNifs.default_nifs() |> Enum.map(& &1.module)

      for m <- [
            :prim_tty,
            :erl_tracer,
            :prim_buffer,
            :prim_file,
            :zlib,
            :zstd,
            :prim_socket,
            :prim_net,
            :asn1rt_nif,
            :crypto,
            :mob_nif,
            :sqlite3_nif
          ] do
        assert m in modules, "expected #{inspect(m)} in defaults"
      end
    end

    test "asn1rt_nif and crypto are flagged builtin" do
      defaults = StaticNifs.default_nifs() |> Map.new(&{&1.module, &1})
      assert defaults[:asn1rt_nif].builtin == true
      assert defaults[:crypto].builtin == true
    end

    test "sqlite3_nif is iOS-device-only with MOB_STATIC_SQLITE_NIF guard" do
      defaults = StaticNifs.default_nifs() |> Map.new(&{&1.module, &1})
      assert defaults[:sqlite3_nif].archs == [:ios_device]
      assert defaults[:sqlite3_nif].guard == "MOB_STATIC_SQLITE_NIF"
    end

    test "emlx_nif is iOS-only with MOB_STATIC_EMLX_NIF guard" do
      defaults = StaticNifs.default_nifs() |> Map.new(&{&1.module, &1})
      assert :emlx_nif in Map.keys(defaults)
      assert defaults[:emlx_nif].archs == [:ios_device, :ios_sim]
      assert defaults[:emlx_nif].guard == "MOB_STATIC_EMLX_NIF"
    end
  end

  describe "init_fn/1" do
    test "derives <module>_nif_init by default" do
      assert StaticNifs.init_fn(%{module: :prim_tty}) == "prim_tty_nif_init"
      assert StaticNifs.init_fn(%{module: :crypto}) == "crypto_nif_init"
      assert StaticNifs.init_fn(%{module: :mob_nif}) == "mob_nif_nif_init"
      assert StaticNifs.init_fn(%{module: :asn1rt_nif}) == "asn1rt_nif_nif_init"
    end

    test "honors explicit :init override" do
      assert StaticNifs.init_fn(%{module: :foo, init: "weird_name"}) == "weird_name"
    end
  end

  describe "validate_entry/1" do
    test "accepts a minimal entry" do
      assert :ok = StaticNifs.validate_entry(%{module: :foo})
    end

    test "rejects unknown archs" do
      assert {:error, msg} = StaticNifs.validate_entry(%{module: :foo, archs: [:windows]})
      assert msg =~ "unknown archs"
    end

    test "rejects non-string :init" do
      assert {:error, msg} = StaticNifs.validate_entry(%{module: :foo, init: :atom_init})
      assert msg =~ ":init must be a string"
    end

    test "rejects non-boolean :builtin" do
      assert {:error, msg} = StaticNifs.validate_entry(%{module: :foo, builtin: 1})
      assert msg =~ ":builtin must be a boolean"
    end

    test "rejects non-string :guard" do
      assert {:error, _} = StaticNifs.validate_entry(%{module: :foo, guard: :foo})
    end

    test "accepts per-ABI extra static library paths" do
      assert :ok =
               StaticNifs.validate_entry(%{
                 module: :ghostty_vt,
                 archs: [:android_arm64],
                 extra_static_libs: %{android_arm64: "native/libghostty-vt.a"}
               })
    end

    test "rejects broad extra static library arch keys" do
      assert {:error, msg} =
               StaticNifs.validate_entry(%{
                 module: :ghostty_vt,
                 extra_static_libs: %{android: "native/libghostty-vt.a"}
               })

      assert msg =~ ":extra_static_libs"
    end

    test "rejects non-string extra static library paths" do
      assert {:error, msg} =
               StaticNifs.validate_entry(%{
                 module: :ghostty_vt,
                 extra_static_libs: %{android_arm64: :not_a_path}
               })

      assert msg =~ ":extra_static_libs"
    end

    test "rejects entry without :module" do
      assert {:error, _} = StaticNifs.validate_entry(%{archs: [:all]})
    end
  end

  describe "resolve/1" do
    test "user list extends defaults" do
      result = StaticNifs.resolve([%{module: :my_native}])
      modules = Enum.map(result, & &1.module)

      assert :my_native in modules
      assert :mob_nif in modules
    end

    test "user entries override defaults with same :module" do
      result = StaticNifs.resolve([%{module: :crypto, builtin: false, guard: "OFF_BY_DEFAULT"}])
      crypto = Enum.find(result, &(&1.module == :crypto))

      assert crypto.builtin == false
      assert crypto.guard == "OFF_BY_DEFAULT"
    end

    test "setting archs: [] removes a default entry" do
      result = StaticNifs.resolve([%{module: :sqlite3_nif, archs: []}])
      assert Enum.find(result, &(&1.module == :sqlite3_nif)) == nil
    end
  end

  describe "on_platform?/2" do
    test ":all archs apply to both platforms" do
      e = %{module: :x, archs: [:all]}
      assert StaticNifs.on_platform?(e, :ios)
      assert StaticNifs.on_platform?(e, :android)
    end

    test ":ios archs apply only to iOS" do
      e = %{module: :x, archs: [:ios]}
      assert StaticNifs.on_platform?(e, :ios)
      refute StaticNifs.on_platform?(e, :android)
    end

    test ":ios_device only is still on iOS, never on Android" do
      e = %{module: :x, archs: [:ios_device]}
      assert StaticNifs.on_platform?(e, :ios)
      refute StaticNifs.on_platform?(e, :android)
    end

    test "entries default to :all when archs is missing" do
      e = %{module: :x}
      assert StaticNifs.on_platform?(e, :ios)
      assert StaticNifs.on_platform?(e, :android)
    end
  end

  describe "needs_guard?/2" do
    test "false when entry covers all of the platform's archs" do
      assert StaticNifs.needs_guard?(%{module: :x, archs: [:all]}, :ios) == false
      assert StaticNifs.needs_guard?(%{module: :x, archs: [:ios]}, :ios) == false
    end

    test "true when entry is a strict subset of platform archs" do
      assert StaticNifs.needs_guard?(%{module: :x, archs: [:ios_device]}, :ios)
      assert StaticNifs.needs_guard?(%{module: :x, archs: [:android_arm64]}, :android)
    end

    test "false on platforms the entry doesn't apply to" do
      assert StaticNifs.needs_guard?(%{module: :x, archs: [:ios_device]}, :android) == false
    end
  end

  describe "generate/2 — iOS" do
    test "includes the standard ERTS NIFs in canonical order" do
      out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      # Every NIF that should appear on iOS is present
      for fn_name <- [
            "prim_tty_nif_init",
            "erl_tracer_nif_init",
            "prim_buffer_nif_init",
            "prim_file_nif_init",
            "zlib_nif_init",
            "zstd_nif_init",
            "prim_socket_nif_init",
            "prim_net_nif_init",
            "asn1rt_nif_nif_init",
            "crypto_nif_init",
            "mob_nif_nif_init",
            "sqlite3_nif_nif_init"
          ] do
        assert out =~ fn_name, "expected #{fn_name} in generated iOS source"
      end
    end

    test "wraps sqlite3_nif decl + table row in MOB_STATIC_SQLITE_NIF guard" do
      out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      assert out =~ ~r/#ifdef MOB_STATIC_SQLITE_NIF\nvoid \*sqlite3_nif_nif_init/
      assert out =~ ~r/#ifdef MOB_STATIC_SQLITE_NIF\n\s+\{sqlite3_nif_nif_init/
    end

    test "asn1rt_nif and crypto have is_builtin=1; everyone else is 0" do
      out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      # Crude but checks the right column
      assert out =~ "{asn1rt_nif_nif_init,   1, THE_NON_VALUE, NULL}"
      assert out =~ "{crypto_nif_init,       1, THE_NON_VALUE, NULL}"
      assert out =~ "{mob_nif_nif_init,      0, THE_NON_VALUE, NULL}"
      assert out =~ "{prim_tty_nif_init,     0, THE_NON_VALUE, NULL}"
    end

    test "table ends with NULL sentinel row" do
      out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()
      assert out =~ "{NULL,                  0, THE_NON_VALUE, NULL}"
    end

    test "driver_tab[] has inet + ram_file + sentinel" do
      out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()
      assert out =~ "{&inet_driver_entry, 0}"
      assert out =~ "{&ram_file_driver_entry, 0}"
    end

    test "is deterministic — same input ⇒ same output" do
      a = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()
      b = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()
      assert a == b
    end
  end

  describe "generate/2 — Android" do
    test "omits sqlite3_nif entirely (not declared on Android)" do
      out = StaticNifs.generate(:android, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      refute out =~ "sqlite3_nif_nif_init"
      refute out =~ "MOB_STATIC_SQLITE_NIF"
    end

    test "includes all the cross-platform NIFs that today's hand-edited file has" do
      out = StaticNifs.generate(:android, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      for fn_name <- [
            "prim_tty_nif_init",
            "erl_tracer_nif_init",
            "prim_buffer_nif_init",
            "prim_file_nif_init",
            "zlib_nif_init",
            "zstd_nif_init",
            "prim_socket_nif_init",
            "prim_net_nif_init",
            "asn1rt_nif_nif_init",
            "crypto_nif_init",
            "mob_nif_nif_init"
          ] do
        assert out =~ fn_name, "expected #{fn_name} in generated Android source"
      end
    end
  end

  describe "generate/2 — extension entries" do
    test "user-added NIF appears in the table for the platforms its archs cover" do
      user = [%{module: :my_extra}]
      ios_out = StaticNifs.generate(:ios, StaticNifs.resolve(user)) |> IO.iodata_to_binary()

      android_out =
        StaticNifs.generate(:android, StaticNifs.resolve(user)) |> IO.iodata_to_binary()

      assert ios_out =~ "my_extra_nif_init"
      assert android_out =~ "my_extra_nif_init"
    end

    test "iOS-only user NIF does not appear in the Android source" do
      user = [%{module: :ios_thing, archs: [:ios], guard: "BUILDING_FOR_IOS"}]

      android_out =
        StaticNifs.generate(:android, StaticNifs.resolve(user)) |> IO.iodata_to_binary()

      refute android_out =~ "ios_thing_nif_init"
    end
  end

  # ── Phase 6a: Zig output ──────────────────────────────────────────────────

  describe "generate/3 with format: :zig" do
    test "iOS Zig output uses extern struct + comptime sentinel" do
      out =
        StaticNifs.generate(:ios, StaticNifs.default_nifs(), format: :zig)
        |> IO.iodata_to_binary()

      assert out =~ "const ErtsStaticNif = extern struct"
      assert out =~ "const ErtsStaticDriver = extern struct"
      assert out =~ "export var driver_tab"
      assert out =~ "export var erts_static_nif_tab"
      assert out =~ "export fn erts_init_static_drivers"
    end

    test "iOS Zig output gates sqlite3_nif with comptime sqlite_static" do
      # The default set has sqlite3_nif declared as ios_device-only with
      # a guard. Zig output should comptime-gate via sqlite_static, not
      # a #ifdef.
      out =
        StaticNifs.generate(:ios, StaticNifs.default_nifs(), format: :zig)
        |> IO.iodata_to_binary()

      assert out =~ "sqlite_static"
      assert out =~ "build_options"
      assert out =~ "extern fn sqlite3_nif_nif_init"
      refute out =~ "#ifdef"
    end

    test "iOS Zig output gates emlx_nif with comptime emlx_static (default set)" do
      # Default nifs include :emlx_nif with guard "MOB_STATIC_EMLX_NIF" and
      # archs [:ios_device, :ios_sim]. Even though the archs match the full
      # iOS platform, the explicit guard should still gate the NIF.
      out =
        StaticNifs.generate(:ios, StaticNifs.default_nifs(), format: :zig)
        |> IO.iodata_to_binary()

      assert out =~ "const emlx_static = build_options.emlx_static"
      assert out =~ "extern fn emlx_nif_nif_init"
      assert out =~ "const emlx_nif_const = ErtsStaticNif"
    end

    test "iOS Zig output emits 2^N branching for multiple guards" do
      out =
        StaticNifs.generate(:ios, StaticNifs.default_nifs(), format: :zig)
        |> IO.iodata_to_binary()

      # sqlite3_nif + emlx_nif → 4 mutually-exclusive branches
      assert out =~ "if (sqlite_static and emlx_static)"
      assert out =~ "else if (sqlite_static)"
      assert out =~ "else if (emlx_static)"
      assert out =~ "} else {"
    end

    test "Android Zig output: sqlite/emlx absent, nx_eigen present and guarded" do
      out =
        StaticNifs.generate(:android, StaticNifs.default_nifs(), format: :zig)
        |> IO.iodata_to_binary()

      # sqlite is iOS-device-only, emlx is iOS-only — neither appears on Android.
      refute out =~ "sqlite_static"
      refute out =~ "emlx_static"

      # nx_eigen is opt-in on Android via the nx_eigen_static comptime flag
      # (set true when `mix mob.enable nxeigen` was run).
      assert out =~ "nx_eigen_static"
      assert out =~ "build_options"
    end

    # The `zig` binary isn't installed in CI (we don't compile Zig in the
    # Elixir test suite). Skip there via `mix test --exclude requires_zig`;
    # local dev runs with Zig on PATH still execute this.
    @tag :requires_zig
    test "produces parseable Zig source (round-trip via zig ast-check)" do
      for platform <- [:ios, :android] do
        out =
          StaticNifs.generate(platform, StaticNifs.default_nifs(), format: :zig)
          |> IO.iodata_to_binary()

        path = "/tmp/zig_ast_check_#{platform}.zig"
        File.write!(path, out)

        case System.cmd("zig", ["ast-check", path], stderr_to_stdout: true) do
          {_out, 0} ->
            :ok

          {bad_out, _} ->
            flunk("generated #{platform} Zig source fails ast-check:\n#{bad_out}")
        end
      end
    end

    test "user-added NIF appears in the Zig table" do
      user = [%{module: :my_extra}]

      out =
        StaticNifs.generate(:android, StaticNifs.resolve(user), format: :zig)
        |> IO.iodata_to_binary()

      assert out =~ "extern fn my_extra_nif_init"
      assert out =~ ".nif_init = my_extra_nif_init"
    end

    # MOB-376: a project NIF's :guard used to become `build_options.<flag>`,
    # which no mob_new build file declares, so the table didn't compile.
    test "a guarded project NIF's flag comes from the target arch, not build_options" do
      user = [
        %{module: :vendor_vt, archs: [:ios_device], guard: "MOB_STATIC_VENDOR_VT_NIF"},
        %{module: :sim_only, archs: [:ios_sim], guard: "MOB_STATIC_SIM_ONLY_NIF"},
        %{module: :both_ios, archs: [:ios], guard: "MOB_STATIC_BOTH_IOS_NIF"}
      ]

      ios =
        StaticNifs.generate(:ios, StaticNifs.resolve(user), format: :zig) |> IO.iodata_to_binary()

      assert ios =~ ~s|const builtin = @import("builtin");|
      assert ios =~ "const vendor_vt_on = builtin.target.abi != .simulator;"
      assert ios =~ "const sim_only_on = builtin.target.abi == .simulator;"
      assert ios =~ "const both_ios_on = true;"
      refute ios =~ "build_options.vendor_vt"
      # Built-in NIFs keep their build_options switch.
      assert ios =~ "const sqlite_static = build_options.sqlite_static;"

      android =
        StaticNifs.generate(
          :android,
          StaticNifs.resolve([
            %{module: :vt64, archs: [:android_arm64], guard: "MOB_STATIC_VT64_NIF"},
            %{module: :vt32, archs: [:android_arm32], guard: "MOB_STATIC_VT32_NIF"}
          ]),
          format: :zig
        )
        |> IO.iodata_to_binary()

      assert android =~ "const vt64_on = builtin.target.cpu.arch == .aarch64;"

      assert android =~
               "const vt32_on = (builtin.target.cpu.arch == .arm or builtin.target.cpu.arch == .thumb);"
    end

    test "project entries sharing a guard each keep their own arch test" do
      user = [
        %{module: :shared_dev, archs: [:ios_device], guard: "MOB_STATIC_SHARED_NIF"},
        %{module: :shared_sim, archs: [:ios_sim], guard: "MOB_STATIC_SHARED_NIF"}
      ]

      ios =
        StaticNifs.generate(:ios, StaticNifs.resolve(user), format: :zig) |> IO.iodata_to_binary()

      assert ios =~ "const shared_dev_on = builtin.target.abi != .simulator;"
      assert ios =~ "const shared_sim_on = builtin.target.abi == .simulator;"
    end

    test "a project guard alone (built-in guarded NIFs dropped) uses its own flag in the N=1 table" do
      drop_builtin_guarded =
        for %{guard: _} = nif <- StaticNifs.default_nifs(), do: %{module: nif.module, archs: []}

      user = [%{module: :sim_only, archs: [:ios_sim], guard: "MOB_STATIC_SIM_ONLY_NIF"}]

      ios =
        StaticNifs.generate(:ios, StaticNifs.resolve(drop_builtin_guarded ++ user), format: :zig)
        |> IO.iodata_to_binary()

      assert ios =~ "const sim_only_on = builtin.target.abi == .simulator;"
      assert ios =~ "    if (sim_only_on) {\n"
    end

    test "a table without project guards is unchanged: no builtin import" do
      for platform <- [:ios, :android] do
        out =
          StaticNifs.generate(platform, StaticNifs.default_nifs(), format: :zig)
          |> IO.iodata_to_binary()

        refute out =~ "@import(\"builtin\")"
      end
    end

    # Compiles the generated tables for each target and checks which NIF init
    # symbols each object references: the behaviour, not the text.
    @tag :requires_zig
    @tag :tmp_dir
    test "compiled tables reference a guarded project NIF only on the targets its :archs cover",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "build_options.zig"), """
      pub const sqlite_static = false;
      pub const emlx_static = false;
      pub const nx_eigen_static = false;
      pub const tflite_static = false;
      """)

      shared = [
        %{module: :shared_dev, archs: [:ios_device], guard: "MOB_STATIC_SHARED_NIF"},
        %{module: :shared_sim, archs: [:ios_sim], guard: "MOB_STATIC_SHARED_NIF"}
      ]

      # {platform, entries, [{target, modules whose init the object must reference}]}
      cases = [
        {:ios, [%{module: :vendor_vt, archs: [:ios_device], guard: "MOB_STATIC_VENDOR_VT_NIF"}],
         [{"aarch64-ios", [:vendor_vt]}, {"aarch64-ios-simulator", []}]},
        {:ios, shared,
         [{"aarch64-ios", [:shared_dev]}, {"aarch64-ios-simulator", [:shared_sim]}]},
        {:android, [%{module: :vt64, archs: [:android_arm64], guard: "MOB_STATIC_VT64_NIF"}],
         [{"aarch64-linux-android", [:vt64]}, {"arm-linux-androideabi", []}]}
      ]

      for {{platform, entries, targets}, i} <- Enum.with_index(cases),
          {target, expected} <- targets do
        src = Path.join(dir, "tab_#{i}_#{platform}.zig")
        obj = Path.join(dir, "tab_#{i}_#{target}.o")
        File.write!(src, StaticNifs.generate(platform, StaticNifs.resolve(entries), format: :zig))

        {out, status} =
          System.cmd(
            "zig",
            [
              "build-obj",
              "-target",
              target,
              "--dep",
              "build_options",
              "-Mroot=#{src}",
              "-Mbuild_options=#{Path.join(dir, "build_options.zig")}",
              "-femit-bin=#{obj}"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, "zig build-obj #{target} failed:\n#{out}"
        {symbols, 0} = System.cmd("nm", [obj])

        for %{module: module} <- entries do
          assert String.contains?(symbols, "#{module}_nif_init") == module in expected,
                 "#{target}: #{module}"
        end
      end
    end

    test "format: :c default produces C source (backward compat)" do
      c_out = StaticNifs.generate(:ios, StaticNifs.default_nifs()) |> IO.iodata_to_binary()

      c_out2 =
        StaticNifs.generate(:ios, StaticNifs.default_nifs(), format: :c) |> IO.iodata_to_binary()

      assert c_out == c_out2
      assert c_out =~ "ErtsStaticNif erts_static_nif_tab"
      refute c_out =~ "export var erts_static_nif_tab"
    end

    test "C table: each project guard is selected by its target-arch test alone" do
      ios =
        StaticNifs.generate(
          :ios,
          StaticNifs.resolve([
            %{module: :dev_only, archs: [:ios_device], guard: "MOB_STATIC_DEV_ONLY_NIF"},
            %{module: :sim_only, archs: [:ios_sim], guard: "MOB_STATIC_SIM_ONLY_NIF"},
            %{module: :both_ios, archs: [:ios], guard: "MOB_STATIC_BOTH_IOS_NIF"}
          ])
        )
        |> IO.iodata_to_binary()

      assert ios =~ "#include <TargetConditionals.h>"
      assert ios =~ "#if !TARGET_OS_SIMULATOR\nvoid *dev_only_nif_init(void);"
      assert ios =~ "#if TARGET_OS_SIMULATOR\nvoid *sim_only_nif_init(void);"
      assert ios =~ "#if 1\nvoid *both_ios_nif_init(void);"
      # The macro plays no part: `mix mob.release --ios` defines every guarded
      # entry's macro on the device, which must not pull in a simulator-only row.
      refute ios =~ "defined(MOB_STATIC_SIM_ONLY_NIF)"
      # Built-in feature switches are unchanged.
      assert ios =~ "#ifdef MOB_STATIC_SQLITE_NIF\n"

      whole_platform_only =
        StaticNifs.generate(
          :ios,
          StaticNifs.resolve([
            %{module: :both_ios, archs: [:ios], guard: "MOB_STATIC_BOTH_IOS_NIF"}
          ])
        )
        |> IO.iodata_to_binary()

      refute whole_platform_only =~ "TargetConditionals"

      sim_only =
        StaticNifs.generate(
          :ios,
          StaticNifs.resolve([
            %{module: :sim_only, archs: [:ios_sim], guard: "MOB_STATIC_SIM_ONLY_NIF"}
          ])
        )
        |> IO.iodata_to_binary()

      assert sim_only =~ "#include <TargetConditionals.h>"

      android =
        StaticNifs.generate(
          :android,
          StaticNifs.resolve([
            %{module: :vt64, archs: [:android_arm64], guard: "MOB_STATIC_VT64_NIF"},
            %{module: :vt32, archs: [:android_arm32], guard: "MOB_STATIC_VT32_NIF"}
          ])
        )
        |> IO.iodata_to_binary()

      assert android =~ "#if defined(__aarch64__)\nvoid *vt64_nif_init(void);"
      assert android =~ "#if defined(__arm__)\nvoid *vt32_nif_init(void);"
      refute android =~ "TargetConditionals"
    end

    test "a C table without project guards is unchanged: only #ifdef switches" do
      for platform <- [:ios, :android] do
        out = StaticNifs.generate(platform, StaticNifs.default_nifs()) |> IO.iodata_to_binary()
        refute out =~ "TargetConditionals"
        refute out =~ ~r/^#if /m
      end
    end
  end
end
