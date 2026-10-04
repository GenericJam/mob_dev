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
  | `:guard`   | string   | none      | Macro naming a narrowed entry (see below) |
  | `:extra_static_libs` | map | none | Per-ABI archives to link with this NIF |

  Valid `:archs` values: `:all`, `:ios`, `:android`, `:ios_sim`,
  `:ios_device`, `:android_arm64`, `:android_arm32`.

  When `:archs` is a strict subset of a target platform's archs (e.g.
  `[:ios_device]` for iOS), set `:guard` to a C-identifier macro name. The
  generated tables select a guarded project entry on exactly the targets its
  `:archs` cover, by the compiler's own target: the Zig table gates it on
  `@import("builtin").target` (the simulator ABI on iOS, the CPU on Android),
  and the C table wraps the forward declaration and row in `#if <arch test>`
  (`TARGET_OS_SIMULATOR`, `__aarch64__`, `__arm__`, or `1` when the entry covers
  the platform). No build option is involved, so it works with any app's
  build files (MOB-376). The guards of the built-in NIFs in `default_nifs/0`
  are different: each is a feature switch that mob_new's build files set
  (`build_options.<flag>` for Zig, `-D<guard>` for C).

  ## Defaults

  See `default_nifs/0` for the baked-in NIF set. It mirrors the hand-edited
  `driver_tab_ios.c` / `driver_tab_android.c` files mob shipped through
  v0.5.18 — `regen/1` against an empty user list produces byte-equivalent
  output to those files.
  """

  # Top-level platforms cover both arches; per-arch "platforms" are
  # accepted by `on_platform?/2` so cross-compile callers (e.g.
  # `NativeBuild.project_nif_zig_args/1`) can filter entries against a
  # specific ABI.
  @type platform :: :ios | :android | arch()
  @type arch ::
          :all
          | :ios
          | :android
          | :ios_sim
          | :ios_device
          | :android_arm64
          | :android_arm32

  @type extra_static_lib_arch ::
          :ios_sim
          | :ios_device
          | :android_arm64
          | :android_arm32
          | :android_x86_64

  @type nif_entry :: %{
          required(:module) => atom(),
          optional(:init) => String.t(),
          optional(:builtin) => boolean(),
          optional(:archs) => [arch()],
          optional(:guard) => String.t(),
          optional(:extra_static_libs) => %{optional(extra_static_lib_arch()) => Path.t()}
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

  @valid_extra_static_lib_archs [
    :ios_sim,
    :ios_device,
    :android_arm64,
    :android_arm32,
    :android_x86_64
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
      },
      # EMLX NIF — statically linked when the project enables MLX via
      # `mix mob.enable mlx`. The guard means the entry only fires when
      # the build defines MOB_STATIC_EMLX_NIF, so apps that don't use Nx
      # pay zero size cost. See MobDev.MLXDownloader for tarball fetching.
      %{
        module: :emlx_nif,
        archs: [:ios_device, :ios_sim],
        guard: "MOB_STATIC_EMLX_NIF"
      },
      # NxEigen NIF (Eigen-backed Nx backend) — statically linked when the
      # project enables it via `mix mob.enable nxeigen`. Available on iOS
      # AND Android (Eigen is header-only C++; mob_dev cross-compiles
      # libnx_eigen.a per arch). Guard `MOB_STATIC_NX_EIGEN_NIF` keeps the
      # entry zero-cost for apps that don't use Nx. See MobDev.NxEigenNif
      # for the cross-compile.
      %{
        module: :nx_eigen,
        archs: [:all],
        guard: "MOB_STATIC_NX_EIGEN_NIF"
      },
      # TFLite NIF (TensorFlow Lite Nx backend) — statically linked when
      # the project enables it via `mix mob.enable tflite`. Cross-platform:
      # NNAPI on Android (vendor GPU/NPU HAL), CoreML on iOS (Apple
      # Neural Engine). The TFLite runtime itself
      # (`libtensorflowlite_jni.so` on Android,
      # `TensorFlowLiteC.framework` on iOS) ships as a separate dynamic
      # library bundled with the .apk / .app — only the NIF init has to be
      # static. See `MobDev.TfliteNif` for the per-arch cross-compile and
      # `MobDev.TfliteDownloader` for the runtime fetch/cache.
      %{
        module: :tflite_nif,
        archs: [:all],
        guard: "MOB_STATIC_TFLITE_NIF"
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

      Map.has_key?(entry, :extra_static_libs) and
          not valid_extra_static_libs?(entry.extra_static_libs) ->
        {:error,
         ":extra_static_libs must be a non-empty map of concrete arch => path string, got " <>
           inspect(entry.extra_static_libs)}

      true ->
        validate_archs(Map.get(entry, :archs, [:all]))
    end
  end

  def validate_entry(other), do: {:error, "expected a map with :module, got #{inspect(other)}"}

  # Per-ABI external static archives to add to the app link for this NIF. This
  # lets a project NIF declare `extern` symbols and resolve them against an
  # archive that is only valid for the current target ABI.
  defp valid_extra_static_libs?(%{} = libs) when map_size(libs) > 0 do
    Enum.all?(libs, fn {arch, path} ->
      arch in @valid_extra_static_lib_archs and is_binary(path)
    end)
  end

  defp valid_extra_static_libs?(_), do: false

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
  archs (i.e. it's present on this platform but not all of its arches). Such
  an entry needs a `:guard`, so the generated tables register it only on its
  archs.
  """
  @spec needs_guard?(nif_entry(), platform()) :: boolean()
  def needs_guard?(entry, platform) do
    entry_archs = Map.get(entry, :archs, [:all]) |> expand_archs() |> MapSet.new()
    platform_archs = platform_archs(platform) |> MapSet.new()
    on_platform?(entry, platform) and not MapSet.subset?(platform_archs, entry_archs)
  end

  defp platform_archs(:ios), do: [:ios_sim, :ios_device]
  defp platform_archs(:android), do: [:android_arm64, :android_arm32]
  # Per-arch "platforms" — used by `NativeBuild.project_nif_zig_args/1`
  # to filter user NIF entries against a specific ABI when the iOS or
  # Android build path needs to cross-compile per-ABI (e.g. Android's
  # arm64 + armv7 .sos each get their own static-NIF set). Each is a
  # singleton list so `on_platform?/2`'s intersection check still
  # behaves the way the broader `:ios`/`:android` callers expect.
  defp platform_archs(:ios_device), do: [:ios_device]
  defp platform_archs(:ios_sim), do: [:ios_sim]
  defp platform_archs(:android_arm64), do: [:android_arm64]
  defp platform_archs(:android_arm32), do: [:android_arm32]

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
      if(uses_target_conditionals?(applicable, platform),
        do: "#include <TargetConditionals.h>\n\n",
        else: []
      ),
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
    # iOS: each guarded NIF (e.g. :sqlite3_nif on device only, :emlx_nif
    # when EMLX is enabled) gets its own comptime flag, threaded in via
    # `b.addOptions` in build_device.zig. Flag name is derived from the
    # `:guard` value — see guard_flag_name/1.
    plain =
      nifs
      |> Enum.reject(&needs_guard_in_zig?(&1, platform))
      |> Enum.map(fn nif ->
        "extern fn #{init_fn(nif)}() callconv(.c) ?*anyopaque;\n"
      end)

    guarded = Enum.filter(nifs, &needs_guard_in_zig?(&1, platform))

    guard_imports =
      case guarded do
        [] ->
          []

        _ ->
          flag_decls =
            guarded
            |> Enum.uniq_by(&zig_flag/1)
            |> Enum.map(fn nif ->
              "const #{zig_flag(nif)} = #{zig_guard_value(nif, platform)};\n"
            end)

          [
            "\n",
            "// Comptime flags threaded from build.zig via b.addOptions().\n",
            "// Each per-feature flag defaults to false; the build sets it to true\n",
            "// when the project opts into the corresponding statically-linked NIF.\n",
            "const build_options = @import(\"build_options\");\n",
            project_guard_import(guarded),
            flag_decls,
            "\n",
            Enum.map(guarded, fn nif ->
              "extern fn #{init_fn(nif)}() callconv(.c) ?*anyopaque;\n"
            end)
          ]
      end

    [plain, guard_imports]
  end

  # Only a table with a project-NIF guard needs `builtin`; the rest stay
  # byte-identical to what earlier versions generated.
  defp project_guard_import(guarded) do
    if Enum.all?(guarded, &template_guard?(&1.guard)) do
      []
    else
      [
        "// A project NIF's :guard flag is true on the targets its :archs cover.\n",
        "const builtin = @import(\"builtin\");\n"
      ]
    end
  end

  defp needs_guard_in_zig?(nif, platform) do
    guarded?(nif) and on_platform?(nif, platform)
  end

  # The guards mob_new's build files define: each built-in NIF's feature switch
  # (zig `build_options.<flag>`, C `-D<guard>`). Any other guard is a project's
  # own and selects its entry by target arch instead.
  defp template_guard?(guard), do: Enum.any?(default_nifs(), &(&1[:guard] == guard))

  # Which of the platform's archs the entry covers: :all, or the one arch.
  defp arch_scope(nif, platform) do
    entry_archs = Map.get(nif, :archs, [:all]) |> expand_archs() |> MapSet.new()

    case Enum.filter(platform_archs(platform), &MapSet.member?(entry_archs, &1)) do
      [arch] -> arch
      _ -> :all
    end
  end

  defp zig_guard_value(nif, platform) do
    if template_guard?(nif.guard) do
      "build_options.#{guard_flag_name(nif.guard)}"
    else
      case arch_scope(nif, platform) do
        :all -> "true"
        :ios_sim -> "builtin.target.abi == .simulator"
        :ios_device -> "builtin.target.abi != .simulator"
        :android_arm64 -> "builtin.target.cpu.arch == .aarch64"
        :android_arm32 -> "(builtin.target.cpu.arch == .arm or builtin.target.cpu.arch == .thumb)"
      end
    end
  end

  # The preprocessor line that opens a guarded entry in the C table:
  # `#ifdef <guard>` for a built-in feature switch (unchanged from earlier
  # versions); for a project NIF the target-arch test alone. The guard macro
  # plays no part there: `mix mob.release --ios` defines it for every guarded
  # entry on the device (for C tables generated before 0.7.12), which would
  # pull in a simulator-only entry sharing that guard.
  defp c_guard_open(nif, platform) do
    if template_guard?(nif.guard) do
      "#ifdef #{nif.guard}\n"
    else
      arch_test =
        case arch_scope(nif, platform) do
          :all -> "1"
          :ios_sim -> "TARGET_OS_SIMULATOR"
          :ios_device -> "!TARGET_OS_SIMULATOR"
          :android_arm64 -> "defined(__aarch64__)"
          :android_arm32 -> "defined(__arm__)"
        end

      "#if #{arch_test}\n"
    end
  end

  defp uses_target_conditionals?(nifs, platform) do
    Enum.any?(nifs, fn nif ->
      guarded?(nif) and not template_guard?(nif.guard) and
        arch_scope(nif, platform) in [:ios_sim, :ios_device]
    end)
  end

  @doc """
  True when the entry carries a `:guard` key. A built-in NIF's guard (e.g.
  `MOB_STATIC_EMLX_NIF`) is a feature switch the build sets: `#ifdef` in C, a
  `build_options` flag in Zig. A project NIF's guard selects the entry on the
  targets its `:archs` cover, by the compiler's target, and is always on when
  the archs cover the whole platform.
  """
  @spec guarded?(nif_entry()) :: boolean()
  def guarded?(nif), do: Map.has_key?(nif, :guard)

  # Convention: MOB_STATIC_SQLITE_NIF → sqlite_static, MOB_STATIC_EMLX_NIF →
  # emlx_static. Lowercased, stripped of the `MOB_STATIC_` prefix and the
  # `_NIF` suffix. Future guards follow the same convention.
  defp guard_flag_name(guard) when is_binary(guard) do
    guard
    |> String.replace_prefix("MOB_STATIC_", "")
    |> String.replace_suffix("_NIF", "")
    |> String.downcase()
    |> Kernel.<>("_static")
  end

  # The comptime flag gating a guarded entry in the Zig table. A built-in NIF's
  # is its build option's name; a project NIF gets its own, named from its
  # module (already a C identifier: `<module>_nif_init`), so two entries that
  # share a :guard keep their own arch tests and any C macro works as a guard.
  defp zig_flag(nif) do
    if template_guard?(nif.guard), do: guard_flag_name(nif.guard), else: "#{nif.module}_on"
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

    sentinel_row =
      "    .{ .nif_init = null, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },\n"

    case guarded_nifs do
      [] ->
        [
          "export var erts_static_nif_tab = [_]ErtsStaticNif{\n",
          base_rows,
          sentinel_row,
          "};\n"
        ]

      [_ | _] ->
        # Build the table comptime — base rows + per-flag conditionally-added
        # guarded rows + sentinel. Each guarded NIF gets its own ErtsStaticNif
        # const, and the final array is selected via a branching block.
        per_nif_consts =
          Enum.map(guarded_nifs, fn nif ->
            init = init_fn(nif)
            builtin = if Map.get(nif, :builtin, false), do: "1", else: "0"

            "const #{nif_const_name(nif)} = ErtsStaticNif{ " <>
              ".nif_init = #{init}, .is_builtin = #{builtin}, " <>
              ".nif_mod = THE_NON_VALUE, .entry = null };\n"
          end)

        [
          "const base_nifs = [_]ErtsStaticNif{\n",
          base_rows,
          "};\n\n",
          per_nif_consts,
          "\n",
          "const sentinel = ErtsStaticNif{ .nif_init = null, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null };\n\n",
          zig_branching_table(guarded_nifs)
        ]
    end
  end

  # Builds the `export var erts_static_nif_tab = blk: { ... }` chain.
  # For N guarded NIFs we emit 2^N branches enumerating every subset of
  # active guards. N=1 → 2 branches (current sqlite-only behavior). N=2 →
  # 4 branches (sqlite + emlx). Higher N is theoretical for now.
  defp zig_branching_table(guarded_nifs) do
    n = length(guarded_nifs)
    subsets = subsets(guarded_nifs)

    branches =
      subsets
      # Most-specific subsets first (all flags true) so `if (a and b)` shadows
      # `if (a)` correctly.
      |> Enum.sort_by(&(-length(&1)))
      |> Enum.with_index()
      |> Enum.map(fn {active, idx} ->
        condition = zig_branch_condition(active, guarded_nifs)
        rows_expr = zig_branch_rows(active)
        keyword = if idx == 0, do: "if", else: "} else if"

        if active == [] do
          "} else {\n        break :blk #{rows_expr};\n"
        else
          "#{keyword} (#{condition}) {\n        break :blk #{rows_expr};\n"
        end
      end)

    case n do
      1 ->
        # Simpler shape for the common N=1 case — matches the legacy output.
        [nif] = guarded_nifs

        [
          "export var erts_static_nif_tab = blk: {\n",
          "    if (#{zig_flag(nif)}) {\n",
          "        break :blk base_nifs ++ [_]ErtsStaticNif{ #{nif_const_name(nif)}, sentinel };\n",
          "    } else {\n",
          "        break :blk base_nifs ++ [_]ErtsStaticNif{sentinel};\n",
          "    }\n",
          "};\n"
        ]

      _ ->
        [
          "export var erts_static_nif_tab = blk: {\n    ",
          Enum.intersperse(branches, "    "),
          "    }\n};\n"
        ]
    end
  end

  defp subsets([]), do: [[]]

  defp subsets([h | t]) do
    rest = subsets(t)
    rest ++ Enum.map(rest, &[h | &1])
  end

  defp zig_branch_condition([], _all), do: "true"

  defp zig_branch_condition(active, _all) do
    active
    |> Enum.map(&zig_flag/1)
    |> Enum.join(" and ")
  end

  defp zig_branch_rows([]) do
    "base_nifs ++ [_]ErtsStaticNif{sentinel}"
  end

  defp zig_branch_rows(active) do
    extras =
      active
      |> Enum.map(&nif_const_name/1)
      |> Enum.join(", ")

    "base_nifs ++ [_]ErtsStaticNif{ #{extras}, sentinel }"
  end

  defp nif_const_name(%{module: module}), do: "#{module}_const"

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

      if guarded?(nif) and on_platform?(nif, platform) do
        "#{c_guard_open(nif, platform)}#{decl}#endif\n"
      else
        decl
      end
    end)
  end

  defp static_nif_tab(nifs, platform) do
    rows =
      Enum.map(nifs, fn nif ->
        row = format_row(nif)

        if guarded?(nif) and on_platform?(nif, platform) do
          "#{c_guard_open(nif, platform)}    #{row}\n#endif\n"
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
