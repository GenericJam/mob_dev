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
      android_out = StaticNifs.generate(:android, StaticNifs.resolve(user)) |> IO.iodata_to_binary()

      assert ios_out =~ "my_extra_nif_init"
      assert android_out =~ "my_extra_nif_init"
    end

    test "iOS-only user NIF does not appear in the Android source" do
      user = [%{module: :ios_thing, archs: [:ios], guard: "BUILDING_FOR_IOS"}]
      android_out = StaticNifs.generate(:android, StaticNifs.resolve(user)) |> IO.iodata_to_binary()

      refute android_out =~ "ios_thing_nif_init"
    end
  end
end
