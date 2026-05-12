defmodule MobDev.StaticNifs do
  @moduledoc """
  Schema, defaults, and C-source generation for the static NIF table.

  The static NIF table lives in two C files inside an app's project:

      priv/generated/driver_tab_ios.c
      priv/generated/driver_tab_android.c

  Both are linked **before** `libbeam.a` so they override BEAM's empty
  built-in `erts_static_nif_tab[]`. With these in place, `load_nif/2`
  resolves to the in-binary init function instead of falling back to
  `dlopen`, which fails on iOS (App Store rejects bundled `.dylibs`) and
  on Android (RTLD_LOCAL hides the parent's `enif_*` symbols from
  child libraries).

  ## Declaring NIFs

  An app's `mob.exs` may add to or override the defaults via the
  `:static_nifs` key:

      config :mob_dev,
        static_nifs: [
          %{module: :my_native, archs: [:all]}
        ]

  Each entry is a map with these fields:

  | Field      | Type     | Default   | Meaning                                |
  |------------|----------|-----------|----------------------------------------|
  | `:module`  | atom     | required  | Erlang module name                     |
  | `:init`    | string   | derived   | Init fn name. Defaults to `<mod>_nif_init` |
  | `:builtin` | boolean  | `false`   | True for OTP-shipped libs              |
  | `:archs`   | [atom]   | `[:all]`  | Where this NIF should appear           |
  | `:guard`   | string   | none      | Preprocessor macro that gates the entry |

  Valid `:archs` values: `:all`, `:ios`, `:android`, `:ios_sim`,
  `:ios_device`, `:android_arm64`, `:android_arm32`.

  When `:archs` is a strict subset of a target platform's archs (e.g.
  `[:ios_device]` for iOS), set `:guard` to a preprocessor macro that the
  build defines only on those archs. The generated C file wraps both the
  forward declaration and the table row in `#ifdef <guard>`.

  ## Defaults

  See `default_nifs/0` for the baked-in NIF set. It mirrors the hand-edited
  `driver_tab_ios.c` / `driver_tab_android.c` files mob shipped through
  v0.5.18 — `regen/1` against an empty user list produces byte-equivalent
  output to those files.
  """

  @type platform :: :ios | :android
  @type arch ::
          :all
          | :ios
          | :android
          | :ios_sim
          | :ios_device
          | :android_arm64
          | :android_arm32

  @type nif_entry :: %{
          required(:module) => atom(),
          optional(:init) => String.t(),
          optional(:builtin) => boolean(),
          optional(:archs) => [arch()],
          optional(:guard) => String.t()
        }

  @valid_archs [
    :all,
    :ios,
    :android,
    :ios_sim,
    :ios_device,
    :android_arm64,
    :android_arm32
  ]

  @doc """
  Returns the baked-in NIF set used by every Mob app.

  These match the hand-edited `driver_tab_*.c` files in mob ≤ 0.5.18.
  Users append to this list via `:static_nifs` in `mob.exs`.
  """
  @spec default_nifs() :: [nif_entry()]
  def default_nifs do
    [
      %{module: :prim_tty},
      %{module: :erl_tracer},
      %{module: :prim_buffer},
      %{module: :prim_file},
      %{module: :zlib},
      %{module: :zstd},
      %{module: :prim_socket},
      %{module: :prim_net},
      %{module: :asn1rt_nif, builtin: true},
      %{module: :crypto, builtin: true},
      %{module: :mob_nif},
      %{
        module: :sqlite3_nif,
        archs: [:ios_device],
        guard: "MOB_STATIC_SQLITE_NIF"
      }
    ]
  end

  @doc """
  Combines the defaults with a user list (typically from
  `Application.get_env(:mob_dev, :static_nifs, [])`).

  Later entries with the same `:module` override earlier ones. This lets
  users replace a default entry — e.g. drop `:sqlite3_nif` by setting
  `archs: []` — without forking the default list.
  """
  @spec resolve(user_nifs :: [nif_entry()]) :: [nif_entry()]
  def resolve(user_nifs) when is_list(user_nifs) do
    (default_nifs() ++ user_nifs)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.module)
    |> Enum.reverse()
    |> Enum.reject(&(Map.get(&1, :archs, [:all]) == []))
  end

  @doc """
  Validates a single entry, returning `:ok` or `{:error, reason}`.
  """
  @spec validate_entry(nif_entry()) :: :ok | {:error, String.t()}
  def validate_entry(%{module: module} = entry) when is_atom(module) do
    cond do
      Map.has_key?(entry, :init) and not is_binary(entry.init) ->
        {:error, ":init must be a string, got #{inspect(entry.init)}"}

      Map.has_key?(entry, :builtin) and not is_boolean(entry.builtin) ->
        {:error, ":builtin must be a boolean, got #{inspect(entry.builtin)}"}

      Map.has_key?(entry, :guard) and not is_binary(entry.guard) ->
        {:error, ":guard must be a string, got #{inspect(entry.guard)}"}

      true ->
        validate_archs(Map.get(entry, :archs, [:all]))
    end
  end

  def validate_entry(other), do: {:error, "expected a map with :module, got #{inspect(other)}"}

  defp validate_archs(archs) when is_list(archs) do
    case Enum.reject(archs, &(&1 in @valid_archs)) do
      [] -> :ok
      bad -> {:error, "unknown archs: #{inspect(bad)}; valid: #{inspect(@valid_archs)}"}
    end
  end

  defp validate_archs(other), do: {:error, ":archs must be a list, got #{inspect(other)}"}

  @doc """
  Returns the init function name for an entry — either the explicit `:init`
  value or the conventional `<module>_nif_init`.
  """
  @spec init_fn(nif_entry()) :: String.t()
  def init_fn(%{init: init}) when is_binary(init), do: init
  def init_fn(%{module: module}), do: "#{module}_nif_init"

  @doc """
  Returns true if the entry should appear in the generated file for this
  platform (i.e. its archs intersect the platform's archs).
  """
  @spec on_platform?(nif_entry(), platform()) :: boolean()
  def on_platform?(entry, platform) do
    entry_archs = Map.get(entry, :archs, [:all]) |> expand_archs() |> MapSet.new()
    platform_archs = platform_archs(platform) |> MapSet.new()
    not MapSet.disjoint?(entry_archs, platform_archs)
  end

  @doc """
  Returns true if the entry's archs are a *strict* subset of the platform's
  archs (i.e. it's present on this platform but not all of its arches). When
  true, the generated entry must be wrapped in `#ifdef <guard>`.
  """
  @spec needs_guard?(nif_entry(), platform()) :: boolean()
  def needs_guard?(entry, platform) do
    entry_archs = Map.get(entry, :archs, [:all]) |> expand_archs() |> MapSet.new()
    platform_archs = platform_archs(platform) |> MapSet.new()
    on_platform?(entry, platform) and not MapSet.subset?(platform_archs, entry_archs)
  end

  defp platform_archs(:ios), do: [:ios_sim, :ios_device]
  defp platform_archs(:android), do: [:android_arm64, :android_arm32]

  defp expand_archs(archs) do
    Enum.flat_map(archs, fn
      :all -> [:ios_sim, :ios_device, :android_arm64, :android_arm32]
      :ios -> [:ios_sim, :ios_device]
      :android -> [:android_arm64, :android_arm32]
      other -> [other]
    end)
  end

  @doc """
  Generates the driver_tab source for one platform.

  Format is `:c` by default (produces `driver_tab_<platform>.c` matching
  the hand-edited reference files byte-for-byte). Pass `format: :zig`
  for the Phase 6a Zig output — same semantics, structured as
  comptime-friendly Zig (`extern struct` ABI types, `export` for the
  C-callable symbols, `if (sqlite_static) ... else ...` in place of
  `#ifdef`).

  Pure function — given the same nif list it always produces the same
  bytes.
  """
  @spec generate(platform(), [nif_entry()]) :: iodata()
  @spec generate(platform(), [nif_entry()], keyword()) :: iodata()
  def generate(platform, nifs, opts \\ []) when platform in [:ios, :android] do
    case Keyword.get(opts, :format, :c) do
      :c -> generate_c(platform, nifs)
      :zig -> generate_zig(platform, nifs)
    end
  end

  defp generate_c(platform, nifs) do
    applicable = Enum.filter(nifs, &on_platform?(&1, platform))

    [
      header(platform),
      driver_tab_block(),
      forward_decls(applicable, platform),
      "\n",
      static_nif_tab(applicable, platform)
    ]
  end

  defp generate_zig(platform, nifs) do
    applicable = Enum.filter(nifs, &on_platform?(&1, platform))

    [
      zig_header(platform),
      zig_extern_decls(applicable, platform),
      "\n",
      zig_driver_tab_block(),
      zig_static_nif_tab(applicable, platform)
    ]
  end

  # ── Zig output ────────────────────────────────────────────────────────────

  defp zig_header(:ios) do
    """
    //! driver_tab_ios.zig — Static NIF table generated by mix mob.regen_driver_tab.
    //! DO NOT EDIT. Regenerate via `mix mob.regen_driver_tab` after changing
    //! :static_nifs in mob.exs.
    //!
    //! Linked BEFORE libbeam.a so it overrides BEAM's empty built-in driver_tab.

    const ErtsStaticDriver = extern struct {
        de: ?*anyopaque,
        flags: c_int,
    };

    const ErtsStaticNif = extern struct {
        nif_init: ?*const fn () callconv(.c) ?*anyopaque,
        is_builtin: c_int,
        nif_mod: c_ulong,
        entry: ?*anyopaque,
    };

    const ErlDrvEntryStub = extern struct {
        de: ?*anyopaque,
        flags: c_int,
    };

    const THE_NON_VALUE: c_ulong = 0;

    extern var inet_driver_entry: ErlDrvEntryStub;
    extern var ram_file_driver_entry: ErlDrvEntryStub;

    """
  end

  defp zig_header(:android) do
    """
    //! driver_tab_android.zig — Static NIF table generated by mix mob.regen_driver_tab.
    //! DO NOT EDIT. Regenerate via `mix mob.regen_driver_tab` after changing
    //! :static_nifs in mob.exs.
    //!
    //! Linked BEFORE libbeam.a so it overrides BEAM's empty built-in driver_tab.

    const ErtsStaticDriver = extern struct {
        de: ?*anyopaque,
        flags: c_int,
    };

    const ErtsStaticNif = extern struct {
        nif_init: ?*const fn () callconv(.c) ?*anyopaque,
        is_builtin: c_int,
        nif_mod: c_ulong,
        entry: ?*anyopaque,
    };

    const ErlDrvEntryStub = extern struct {
        de: ?*anyopaque,
        flags: c_int,
    };

    const THE_NON_VALUE: c_ulong = 0;

    extern var inet_driver_entry: ErlDrvEntryStub;
    extern var ram_file_driver_entry: ErlDrvEntryStub;

    """
  end

  defp zig_extern_decls(nifs, platform) do
    # iOS: when a NIF needs a guard (e.g. sqlite3_nif on device only),
    # gate the extern declaration AND the table row on a comptime const
    # that's threaded through `b.addOptions` in build_device.zig.
    # We use `sqlite_static` as a convention for the only current guarded
    # NIF; future guards would extend this map.
    plain =
      nifs
      |> Enum.reject(&needs_guard_in_zig?(&1, platform))
      |> Enum.map(fn nif ->
        "extern fn #{init_fn(nif)}() callconv(.c) ?*anyopaque;\n"
      end)

    guard_imports =
      case Enum.filter(nifs, &needs_guard_in_zig?(&1, platform)) do
        [] ->
          []

        guarded ->
          [
            "\n",
            "// Comptime flag threaded from build.zig via b.addOptions().\n",
            "// Default false; the device build sets it to true to opt into\n",
            "// statically-linked exqlite (sqlite3_nif.a).\n",
            "const build_options = @import(\"build_options\");\n",
            "const sqlite_static = build_options.sqlite_static;\n",
            "\n",
            Enum.map(guarded, fn nif ->
              "extern fn #{init_fn(nif)}() callconv(.c) ?*anyopaque;\n"
            end)
          ]
      end

    [plain, guard_imports]
  end

  defp needs_guard_in_zig?(nif, platform) do
    needs_guard?(nif, platform) and Map.has_key?(nif, :guard)
  end

  defp zig_driver_tab_block do
    """
    export var driver_tab: [3]ErtsStaticDriver = .{
        .{ .de = &inet_driver_entry, .flags = 0 },
        .{ .de = &ram_file_driver_entry, .flags = 0 },
        .{ .de = null, .flags = 0 },
    };

    export fn erts_init_static_drivers() callconv(.c) void {}

    """
  end

  defp zig_static_nif_tab(nifs, platform) do
    plain_nifs = Enum.reject(nifs, &needs_guard_in_zig?(&1, platform))
    guarded_nifs = Enum.filter(nifs, &needs_guard_in_zig?(&1, platform))

    base_rows = Enum.map(plain_nifs, &zig_nif_row/1)

    sentinel =
      "    .{ .nif_init = null, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },\n"

    case guarded_nifs do
      [] ->
        [
          "export var erts_static_nif_tab = [_]ErtsStaticNif{\n",
          base_rows,
          sentinel,
          "};\n"
        ]

      [_ | _] ->
        # Build the table comptime — base rows + (conditionally) the guarded
        # rows + sentinel.
        guarded_rows = Enum.map(guarded_nifs, &zig_nif_row/1)

        [
          "const base_nifs = [_]ErtsStaticNif{\n",
          base_rows,
          "};\n\n",
          "const guarded_nifs = [_]ErtsStaticNif{\n",
          guarded_rows,
          "};\n\n",
          "const sentinel = ErtsStaticNif{ .nif_init = null, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null };\n\n",
          """
          export var erts_static_nif_tab = blk: {
              if (sqlite_static) {
                  break :blk base_nifs ++ guarded_nifs ++ [_]ErtsStaticNif{sentinel};
              } else {
                  break :blk base_nifs ++ [_]ErtsStaticNif{sentinel};
              }
          };
          """
        ]
    end
  end

  defp zig_nif_row(nif) do
    init = init_fn(nif)
    builtin = if Map.get(nif, :builtin, false), do: "1", else: "0"

    "    .{ .nif_init = #{init}, .is_builtin = #{builtin}, .nif_mod = THE_NON_VALUE, .entry = null },\n"
  end

  defp header(:ios) do
    """
    // driver_tab_ios.c — Static NIF table generated by mix mob.regen_driver_tab.
    // DO NOT EDIT. Regenerate via `mix mob.regen_driver_tab` after changing
    // :static_nifs in mob.exs.
    //
    // Linked BEFORE libbeam.a so it overrides BEAM's empty built-in driver_tab.

    #include <stddef.h>

    typedef struct { void* de; int flags; } ErtsStaticDriver;
    #define THE_NON_VALUE ((unsigned long)0)
    typedef struct {
        void* (*nif_init)(void);
        int   is_builtin;
        unsigned long nif_mod;
        void* entry;
    } ErtsStaticNif;

    typedef struct { void* de; int flags; } ErlDrvEntryStub;
    extern ErlDrvEntryStub inet_driver_entry;
    extern ErlDrvEntryStub ram_file_driver_entry;

    """
  end

  defp header(:android) do
    """
    // driver_tab_android.c — Static NIF table generated by mix mob.regen_driver_tab.
    // DO NOT EDIT. Regenerate via `mix mob.regen_driver_tab` after changing
    // :static_nifs in mob.exs.
    //
    // Linked BEFORE libbeam.a so it overrides BEAM's empty built-in driver_tab.

    #include <stddef.h>

    typedef struct { void* de; int flags; } ErtsStaticDriver;
    #define THE_NON_VALUE ((unsigned long)0)
    typedef struct {
        void* (*nif_init)(void);
        int   is_builtin;
        unsigned long nif_mod;
        void* entry;
    } ErtsStaticNif;

    typedef struct { void* de; int flags; } ErlDrvEntryStub;
    extern ErlDrvEntryStub inet_driver_entry;
    extern ErlDrvEntryStub ram_file_driver_entry;

    """
  end

  defp driver_tab_block do
    """
    ErtsStaticDriver driver_tab[] = {
        {&inet_driver_entry, 0},
        {&ram_file_driver_entry, 0},
        {NULL, 0}
    };

    void erts_init_static_drivers(void) {}

    """
  end

  defp forward_decls(nifs, platform) do
    Enum.map(nifs, fn nif ->
      decl = "void *#{init_fn(nif)}(void);\n"

      if needs_guard?(nif, platform) and Map.has_key?(nif, :guard) do
        "#ifdef #{nif.guard}\n#{decl}#endif\n"
      else
        decl
      end
    end)
  end

  defp static_nif_tab(nifs, platform) do
    rows =
      Enum.map(nifs, fn nif ->
        row = format_row(nif)

        if needs_guard?(nif, platform) and Map.has_key?(nif, :guard) do
          "#ifdef #{nif.guard}\n    #{row}\n#endif\n"
        else
          "    #{row}\n"
        end
      end)

    [
      "ErtsStaticNif erts_static_nif_tab[] = {\n",
      rows,
      "    {NULL,                  0, THE_NON_VALUE, NULL}\n};\n"
    ]
  end

  defp format_row(nif) do
    init = init_fn(nif)
    builtin = if Map.get(nif, :builtin, false), do: "1", else: "0"
    # Pad the init name to 22 chars so columns align like the hand-edited file.
    padded = String.pad_trailing("#{init},", 23)
    "{#{padded}#{builtin}, THE_NON_VALUE, NULL},"
  end
end
