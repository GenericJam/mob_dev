defmodule Mix.Tasks.Mob.AddNif do
  @moduledoc """
  Scaffolds a new statically-linked NIF in the current Mob project.

      mix mob.add_nif <name>                   # default: --type elixir-only
      mix mob.add_nif <name> --type c          # also drops c_src/<name>.c skeleton
      mix mob.add_nif <name> --type zigler     # Zigler-backed (inline ~Z)
      mix mob.add_nif <name> --type rustler    # Rustler-backed (Cargo crate at native/<name>/)
      mix mob.add_nif <name> --module MyApp.Nifs.Audio   # custom Elixir module name

  Three things change after a successful run:

    * `lib/<app>/nifs/<name>.ex` — Elixir stub module exporting the NIF
      function placeholders. Each function returns `:erlang.nif_error/1` so
      the BEAM raises a clear "NIF not loaded" error if the native side
      hasn't loaded yet, instead of silently returning the stub's body.

    * `mob.exs` — `:static_nifs` list under `config :mob_dev,` gains
      `%{module: :<name>, archs: [:all]}`. If `:static_nifs` doesn't exist
      yet the entry creates it. The schema lives in
      `MobDev.StaticNifs` — see its module doc for arch values and
      per-arch guards.

    * (with `--type c`) `c_src/<name>.c` — a minimal C skeleton with the
      ERL_NIF_INIT macro pre-wired to the registered name. Wire it into
      your build (Android CMakeLists.txt or iOS build.zig) by adding the
      file to the static archive that links into `libbeam.a`.

  `mix mob.regen_driver_tab` is composed into the same Igniter run, so
  `priv/generated/driver_tab_{ios,android}.c` updates appear in the same
  diff as the stub and `mob.exs` edit. One command, everything wired.

  ## Why a static NIF and not a `dlopen`'d `.so`

  iOS App Store rejects bundled `.dylib` files. Android's loader uses
  `RTLD_LOCAL` by default, which hides `enif_*` symbols from a
  dlopen'd child library. Both platforms force the same answer: link
  the NIF init function into the main binary alongside the BEAM, and
  register it in the static NIF table at link time. See
  `MobDev.StaticNifs` for the full rationale.

  ## Phase 3 of the build-system migration

  This task is the first Igniter-backed surface in mob_dev — it
  validates the AST-aware code-generation approach before the heavier
  Phase 4 (`mob.enable` migration) and Phase 5 (`mob.new --liveview`
  rewrite) follow.
  """
  @shortdoc "Scaffold a new statically-linked NIF"

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :mob,
      schema: [type: :string, module: :string, demo: :boolean],
      defaults: [type: "elixir-only", demo: false],
      positional: [:name]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    %{name: name} = igniter.args.positional
    options = igniter.args.options
    demo? = options[:demo] == true

    with :ok <- validate_name(name),
         :ok <- validate_type(options[:type]),
         :ok <- validate_demo(demo?, options[:type]) do
      module = resolve_module(igniter, name, options[:module])

      type = options[:type]

      igniter
      |> add_elixir_stub(module, name, type, demo?)
      |> add_static_nif_entry(name)
      |> maybe_add_c_skeleton(name, type, demo?)
      |> maybe_add_zigler_dep(type)
      |> maybe_add_rustler(name, type, demo?)
      |> maybe_add_demo_screen(module, name, type, demo?)
      # Run regen automatically after Igniter commits — keeps the user-facing
      # flow to a single command (`mix mob.add_nif foo`) instead of "add the
      # NIF, then remember to run regen". `add_task` queues the task to run
      # AFTER all Igniter file writes are applied, so the just-modified
      # mob.exs is on disk by the time regen reads it.
      |> Igniter.add_task("mob.regen_driver_tab")
      |> maybe_add_demo_notice(module, name, demo?)
    else
      {:error, msg} -> Igniter.add_issue(igniter, msg)
    end
  end

  # ── Validation ────────────────────────────────────────────────────────────

  defp validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error,
         "NIF name must be snake_case starting with a letter (got: #{inspect(name)}). " <>
           "Examples: audio_engine, sqlite3_nif, my_nif."}

      String.length(name) > 64 ->
        {:error, "NIF name too long (max 64 chars; got #{String.length(name)})"}

      true ->
        :ok
    end
  end

  defp validate_type(type) when type in ["elixir-only", "c", "zigler", "rustler"], do: :ok

  defp validate_type(other) do
    {:error, "Unknown --type #{inspect(other)}. Supported: elixir-only, c, zigler, rustler."}
  end

  defp validate_demo(true, "elixir-only") do
    # --demo generates a screen that calls the NIF and shows the result.
    # An elixir-only stub has nothing to call, so the demo would render
    # a permanent "NIF not loaded" — confusing rather than illustrative.
    # Force the user to pick a native backend so the demo actually works.
    {:error,
     "--demo requires a native backend so the screen has something to call.\n" <>
       "  Use --type c, --type zigler, or --type rustler."}
  end

  defp validate_demo(_demo?, _type), do: :ok

  # ── Module name resolution ────────────────────────────────────────────────

  defp resolve_module(_igniter, _name, explicit) when is_binary(explicit) do
    Module.concat([explicit])
  end

  defp resolve_module(igniter, name, nil) do
    app = Igniter.Project.Application.app_name(igniter)
    base = app |> to_string() |> Macro.camelize()
    nif_camel = name |> Macro.camelize()
    Module.concat([base, "Nifs", nif_camel])
  end

  # ── Elixir stub ───────────────────────────────────────────────────────────

  defp add_elixir_stub(igniter, module, name, type, demo?) do
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      # Re-run idempotency: leave the existing module alone. If the user has
      # added their own functions to the stub we don't want to clobber them.
      igniter
    else
      Igniter.Project.Module.create_module(
        igniter,
        module,
        stub_body(module, name, type, demo?)
      )
    end
  end

  # When `demo?` is true, the example function in every backend is
  # replaced by `greet/0` returning a known string ("Hello from C!" /
  # "Hello from Zig!" / "Hello from Rust!"). The demo screen knows to
  # call `greet/0`; this keeps the screen template type-agnostic.
  defp stub_body(module, name, "rustler", demo?) do
    app = module |> Module.split() |> List.first() |> Macro.underscore()

    """
    @moduledoc \"\"\"
    Statically-linked NIF stub for `:#{name}` (rustler-backed).

    The Rust source lives at `native/#{name}/src/lib.rs`. Rustler
    invokes Cargo to build it into a NIF library at compile time and
    binds each `#[rustler::nif]`-annotated function as a function on
    this module. Replace the example `add_one/1` with your real surface.

    > **⚠️  Static linking note.** Rustler's default flow produces a
    > dynamically-loaded `.so` library, which is incompatible with Mob's
    > static-link requirement (iOS App Store rejects bundled `.dylib`s;
    > Android `RTLD_LOCAL` hides parent symbols from children). To make
    > this work on-device you'll need to build the Rust crate as a
    > `staticlib` and wire the resulting archive into `ios/build.zig`
    > + `android/jni/` manually. The host-dev path (`mix phx.server`,
    > sim) works out of the box.
    \"\"\"

    use Rustler, otp_app: :#{app}, crate: "#{name}"

    # Function stubs. Rustler replaces these at load time with the
    # bindings generated from `native/#{name}/src/lib.rs`. Until then,
    # the `:erlang.nif_error/1` body raises clearly instead of silently
    # returning the stub value.
    #{rustler_function_stub(demo?)}
    """
    |> indent_for_module()
    |> wrap_module(module)
  end

  defp stub_body(module, name, "zigler", demo?) do
    app = module |> Module.split() |> List.first() |> Macro.underscore()

    """
    @moduledoc \"\"\"
    Statically-linked NIF stub for `:#{name}` (zigler-backed).

    The Zig source is inlined via `~Z` below. Zigler compiles it through
    its build pipeline and exposes each `pub fn` as a NIF function on this
    module. Replace the example `add_one/1` with your real surface.

    > **⚠️  Static linking note.** Zigler's default flow produces a
    > dynamically-loaded `.so` library, which is incompatible with Mob's
    > static-link requirement (iOS App Store rejects bundled `.dylib`s;
    > Android `RTLD_LOCAL` hides parent symbols from children). To make
    > this work on-device you'll need to wire the Zigler-compiled archive
    > into your `ios/build.zig` + `android/jni/` pipeline manually. The
    > host-dev path (`mix phx.server`, sim) works out of the box.

    > **⚠️  Zig toolchain note.** Zigler 0.15.x pins its own Zig version
    > (0.15.2) and downloads it via `mix zig.get` into the user-cache
    > directory. `mix mob.add_nif --type zigler` runs `zig.get`
    > automatically — without it, Zigler falls back to `System.find_executable("zig")`
    > and uses whatever's on PATH (typically the wrong version).

    > **⚠️  macOS 26 (Sequoia/Tahoe) note.** As of Zig 0.15.2, Zig's
    > bundled `compiler_rt` references `__availability_version_check`
    > and related symbols that aren't available when linking with
    > macOS 26's SDK. Compile fails with `undefined symbol:
    > __availability_version_check` and a cascade of POSIX symbols.
    > Linux and older macOS are unaffected. Tracking upstream — once
    > Zigler supports Zig 0.16+ this resolves itself.
    \"\"\"

    use Zig, otp_app: :#{app}

    ~Z\"\"\"
    #{zigler_inline_code(demo?)}
    \"\"\"
    """
    |> indent_for_module()
    |> wrap_module(module)
  end

  defp stub_body(module, name, _type, demo?) do
    """
    @moduledoc \"\"\"
    Statically-linked NIF stub for `:#{name}`.

    The init function `#{name}_nif_init` is registered in the per-app
    `priv/generated/driver_tab_{ios,android}.c` static table (regenerated
    by `mix mob.regen_driver_tab` from `mob.exs`'s `:static_nifs`). At
    BEAM startup the runtime resolves `load_nif/2` against that table
    and binds the C functions you implement in `c_src/#{name}.c` (or
    your zigler/rustler equivalent) to these placeholders.

    Until then, every function below raises `:erlang.nif_error(:nif_not_loaded)`
    so a missing native side surfaces as a loud, traceable error instead
    of a silent stub return.
    \"\"\"

    @on_load :load_nif

    @doc false
    def load_nif do
      # Static NIFs don't read a path — the second arg to load_nif must
      # still be passed but is ignored when the module is in the static
      # NIF table. Pass 0 by convention.
      :erlang.load_nif(~c"#{name}", 0)
    end

    # ── Public NIF surface ───────────────────────────────────────────
    # Add one stub per native function. Each must return
    # `:erlang.nif_error/1` so a not-yet-implemented native side errors
    # loudly instead of returning the stub body.

    #{c_function_stub(demo?)}
    """
    |> indent_for_module()
    |> wrap_module(module)
  end

  # Per-backend example-function helpers. Kept after the last `stub_body/4`
  # clause so the compiler's "clauses grouped" warning stays clean.

  defp rustler_function_stub(true), do: "def greet(), do: :erlang.nif_error(:nif_not_loaded)"

  defp rustler_function_stub(false),
    do: "def add_one(_input), do: :erlang.nif_error(:nif_not_loaded)"

  defp zigler_inline_code(true) do
    """
    /// Demo NIF — replace with your real Zig surface.
    pub fn greet() []const u8 {
        return "Hello from Zig!";
    }
    """
    |> String.trim_trailing()
  end

  defp zigler_inline_code(false) do
    """
    /// Example NIF — replace with your real Zig surface.
    pub fn add_one(input: i64) i64 {
        return input + 1;
    }
    """
    |> String.trim_trailing()
  end

  defp c_function_stub(true) do
    """
    @doc \"\"\"
    Demo NIF entry point — returns "Hello from C!" when the native
    side is loaded.
    \"\"\"
    def greet(), do: :erlang.nif_error(:nif_not_loaded)
    """
    |> String.trim_trailing()
  end

  defp c_function_stub(false) do
    """
    @doc \"\"\"
    Example NIF entry point. Replace with your own functions.
    \"\"\"
    def hello(_arg), do: :erlang.nif_error(:nif_not_loaded)
    """
    |> String.trim_trailing()
  end

  defp wrap_module(body, _module), do: body

  defp indent_for_module(body), do: body

  # ── mob.exs :static_nifs append ───────────────────────────────────────────

  defp add_static_nif_entry(igniter, name) do
    entry_ast = Sourceror.parse_string!(~s|%{module: :#{name}, archs: [:all]}|)
    initial_ast = Sourceror.parse_string!(~s|[%{module: :#{name}, archs: [:all]}]|)
    nif_atom = String.to_atom(name)

    igniter
    |> Igniter.create_or_update_elixir_file("mob.exs", "import Config\n", &{:ok, &1})
    |> Igniter.update_elixir_file("mob.exs", fn zipper ->
      # NOTE: `modify_config_code` is the LOW-level entry point and does NOT
      # unwrap `{:code, ast}` tuples (that's a `configure/6`-only convenience).
      # Pass the raw AST node directly here, otherwise the tuple shows up
      # as `{:code, [...]}` literally in the generated mob.exs.
      Igniter.Project.Config.modify_config_code(
        zipper,
        [:static_nifs],
        :mob_dev,
        initial_ast,
        updater: fn zipper -> append_to_list(zipper, entry_ast, nif_atom) end
      )
    end)
  end

  defp append_to_list(zipper, entry_ast, nif_atom) do
    code = zipper |> Sourceror.Zipper.node() |> Sourceror.to_string()

    cond do
      String.contains?(code, "module: :#{nif_atom}") ->
        # Already present — leave as-is so re-runs are idempotent.
        {:ok, zipper}

      true ->
        case zipper |> Sourceror.Zipper.node() do
          list when is_list(list) ->
            {:ok, Sourceror.Zipper.replace(zipper, list ++ [entry_ast])}

          # Sourceror sometimes hands us a literal AST node (the existing
          # value isn't a list yet). Replace with a fresh single-element list.
          _ ->
            {:ok, Igniter.Code.Common.replace_code(zipper, [entry_ast])}
        end
    end
  end

  # ── Optional C skeleton ───────────────────────────────────────────────────

  defp maybe_add_c_skeleton(igniter, name, "c", demo?) do
    path = "c_src/#{name}.c"

    if File.exists?(path) do
      # Re-run idempotency: don't overwrite a C file the user may have edited.
      igniter
    else
      module = resolve_module(igniter, name, igniter.args.options[:module])
      Igniter.create_new_file(igniter, path, c_skeleton(name, module, demo?))
    end
  end

  defp maybe_add_c_skeleton(igniter, _name, _other, _demo?), do: igniter

  # ── Optional Hex dep (zigler/rustler) ─────────────────────────────────────

  defp maybe_add_zigler_dep(igniter, "zigler") do
    # Use the GenericJam/zigler fork's zig-016-port branch — Zigler's
    # upstream 0.15.2 pin breaks on macOS 26 (Sequoia/Tahoe) because
    # Zig 0.15.x's stdlib references absent libSystem symbols. The fork
    # ports priv/beam/ to Zig 0.16.0 (which works on macOS 26).
    #
    # Once upstream Zigler ships 0.16, this flips back to a hex pin.
    # Track upstream issue #578 + closed PR #579.
    #
    # `mix zig.get` is still queued so Zigler's executable_path lookup
    # finds the cached Zig before falling through to PATH (which on
    # mob developer machines points at 0.17-dev, the wrong stdlib for
    # the port — needs 0.16.0 specifically).
    igniter
    |> Igniter.Project.Deps.add_dep(
      {:zigler, github: "GenericJam/zigler", branch: "zig-016-port"}
    )
    |> Igniter.add_task("zig.get")
  end

  defp maybe_add_zigler_dep(igniter, _other), do: igniter

  # ── Rustler: dep + Cargo project skeleton ─────────────────────────────────

  defp maybe_add_rustler(igniter, name, "rustler", demo?) do
    module = resolve_module(igniter, name, igniter.args.options[:module])

    igniter
    |> Igniter.Project.Deps.add_dep({:rustler, "~> 0.32"})
    |> create_file_if_missing("native/#{name}/Cargo.toml", cargo_toml(name))
    |> create_file_if_missing("native/#{name}/src/lib.rs", rust_lib_rs(name, module, demo?))
    |> create_file_if_missing("native/#{name}/.gitignore", "/target\n")
    |> create_file_if_missing("native/#{name}/.cargo/config.toml", cargo_config_toml())
  end

  defp maybe_add_rustler(igniter, _name, _other, _demo?), do: igniter

  # macOS host link requires `-undefined dynamic_lookup` because `cdylib`
  # crates reference `enif_*` symbols that aren't resolved until the BEAM
  # `dlopen`s the produced library. Linux's `ld.bfd`/`ld.lld` defers
  # undefined symbols by default; macOS `ld64` errors on them. Without
  # this file, first `mix compile` on a Mac scaffolded with `--type
  # rustler` fails with `Undefined symbols: _enif_raise_exception,
  # _enif_schedule_nif` and the user has to know to search "Rustler
  # macOS undefined symbols" to find the fix.
  defp cargo_config_toml do
    """
    # Generated by `mix mob.add_nif --type rustler`.
    #
    # macOS-only: rustler's default cdylib crate references enif_* symbols
    # that are only resolved at BEAM dlopen time. macOS ld64 errors on
    # them without `-undefined dynamic_lookup`. Harmless on Linux (those
    # linkers defer by default and ignore the rustflags scope here since
    # both target triples below are Apple-only).

    [target.aarch64-apple-darwin]
    rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]

    [target.x86_64-apple-darwin]
    rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]
    """
  end

  defp create_file_if_missing(igniter, path, content) do
    if File.exists?(path) do
      # Re-run idempotency: don't overwrite hand-edited Cargo manifests
      # or Rust sources.
      igniter
    else
      Igniter.create_new_file(igniter, path, content)
    end
  end

  defp cargo_toml(name) do
    """
    [package]
    name = "#{name}"
    version = "0.1.0"
    edition = "2021"

    [lib]
    name = "#{name}"
    # `staticlib` is required for Mob's iOS/Android device builds
    # (the .a gets linked into the main binary). `cdylib` keeps the
    # host-dev `mix compile` path working — produces priv/native/<name>.so
    # for the BEAM to dlopen on Mac/Linux dev.
    crate-type = ["staticlib", "cdylib"]

    [dependencies]
    # 0.37+ derives the static-NIF init symbol from CARGO_CRATE_NAME
    # (`<crate>_nif_init`), which matches what Mob's driver_tab
    # declares. Older versions (≤0.36) hardcode `nif_init` and
    # require manual symbol-renaming to use with Mob's static link.
    rustler = "0.37"

    # ─── DROP WHEN UPSTREAM RUSTLER MERGES THE ANDROID DLSYM FIX ───────────────
    # Rustler 0.37's nif_filler uses `dlopen(NULL)` to find `enif_*` symbols.
    # On Android (Bionic), that handle doesn't see the app's RTLD_GLOBAL-promoted
    # .so, so every NIF init panics with `undefined symbol: enif_priv_data`.
    # The GenericJam fork patches the Android branch to do `dladdr` + `dlopen(self,
    # RTLD_NOLOAD)` for an explicit self-handle. Other platforms are unchanged.
    #
    # Once upstream merges (or a release containing the fix lands on crates.io),
    # bump the `rustler = "0.37"` line above to that version and DELETE this
    # whole [patch.crates-io] block. Tracker: https://github.com/GenericJam/mob/issues/7
    [patch.crates-io]
    rustler = { git = "https://github.com/GenericJam/rustler.git", branch = "genericjam-android-rtld-default" }
    """
  end

  defp rust_lib_rs(name, module, demo?) do
    """
    // native/#{name}/src/lib.rs — Rustler-backed NIF for `:#{name}`.
    //
    // Each #[rustler::nif] function becomes a NIF callable from the
    // matching Elixir stub function. The `init!` macro at the bottom
    // registers them with the BEAM at module load time.
    //
    // See https://hexdocs.pm/rustler for the full type-mapping table
    // and codegen details.

    #{rust_example_fn(demo?)}

    rustler::init!("#{module}", [#{rust_init_list(demo?)}]);
    """
  end

  defp rust_example_fn(true) do
    """
    #[rustler::nif]
    fn greet() -> String {
        "Hello from Rust!".to_string()
    }
    """
    |> String.trim_trailing()
  end

  defp rust_example_fn(false) do
    """
    #[rustler::nif]
    fn add_one(input: i64) -> i64 {
        input + 1
    }
    """
    |> String.trim_trailing()
  end

  defp rust_init_list(true), do: "greet"
  defp rust_init_list(false), do: "add_one"

  defp c_skeleton(name, module, demo?) do
    # First arg to ERL_NIF_INIT is the BEAM module name — what
    # load_nif matches against. For Elixir modules that's
    # `Elixir.<DotPath>` (atomized by the BEAM as the full name).
    nif_module_name = "Elixir." <> (module |> Module.split() |> Enum.join("."))

    """
    /*
     * c_src/#{name}.c — statically-linked NIF for `:#{name}`.
     *
     * This file is linked into the app's main binary alongside libbeam.a
     * (NOT loaded via dlopen — see MobDev.StaticNifs for why). The
     * generated driver_tab_{ios,android}.c registers `#{name}_nif_init`
     * so `load_nif/2` from the Elixir stub binds these functions in.
     *
     * Wire this file into your platform builds (TODO: scaffolded
     * auto-wire — see mob/issues.md #18):
     *   - Android: add to android/app/src/main/jni/CMakeLists.txt as
     *     a target_sources entry on the main library target.
     *   - iOS: add a `b.addCSourceFile`-style addCObject block in
     *     ios/build.zig and ios/build_device.zig with these flags
     *     (after enif_keepalive, before the link step):
     *
     *       installAndCollect(b, objects_step, &objs, addCObject(b, .{
     *           .name = "#{name}",
     *           .source = "absolute/path/to/c_src/#{name}.c",
     *           .target = target,
     *           .optimize = optimize,
     *           .c_flags = c_flags_base ++ &[_][]const u8{
     *               "-DSTATIC_ERLANG_NIF",
     *               "-DSTATIC_ERLANG_NIF_LIBNAME=#{name}",
     *           },
     *           // ... mob_dir/otp_root/erts_vsn/sdkroot ...
     *       }), "#{name}.o");
     *
     * The two -D flags are mandatory:
     *   -DSTATIC_ERLANG_NIF                  selects the static-link
     *                                         dispatch path in erl_nif.h.
     *   -DSTATIC_ERLANG_NIF_LIBNAME=#{name}  overrides the init symbol
     *                                         name to `#{name}_nif_init`
     *                                         (matches driver_tab's
     *                                         declaration). Without it,
     *                                         the symbol would mangle to
     *                                         `Elixir.<...>_nif_init`
     *                                         which is invalid C and
     *                                         won't compile.
     */

    #include <erl_nif.h>

    #{c_example_fn(demo?)}

    static ErlNifFunc nif_funcs[] = {
        #{c_funcs_table_entry(demo?)}
    };

    /* First arg is the BEAM module name — what `:erlang.load_nif/2`
     * matches against the static-NIF table. For Elixir modules this is
     * the fully-qualified `Elixir.<DotPath>` form. The init function's
     * SYMBOL name is decoupled and comes from -DSTATIC_ERLANG_NIF_LIBNAME
     * on the compile line. */
    ERL_NIF_INIT(#{nif_module_name}, nif_funcs, NULL, NULL, NULL, NULL)
    """
  end

  defp c_example_fn(true) do
    """
    static ERL_NIF_TERM greet(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        (void)argc;
        (void)argv;
        return enif_make_string(env, "Hello from C!", ERL_NIF_LATIN1);
    }
    """
    |> String.trim_trailing()
  end

  defp c_example_fn(false) do
    """
    static ERL_NIF_TERM hello(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        (void)argc;
        (void)argv;
        return enif_make_atom(env, "hello_from_native");
    }
    """
    |> String.trim_trailing()
  end

  defp c_funcs_table_entry(true), do: ~s|{"greet", 0, greet, 0}|
  defp c_funcs_table_entry(false), do: ~s|{"hello", 1, hello, 0}|

  # ── Demo screen + post-scaffold notice ────────────────────────────────────

  defp maybe_add_demo_screen(igniter, module, name, type, true) when type != "elixir-only" do
    screen_module = Module.concat([module, "Screen"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, screen_module)

    if exists? do
      # User may have edited the screen; don't clobber on re-run.
      igniter
    else
      Igniter.Project.Module.create_module(
        igniter,
        screen_module,
        demo_screen_body(module, name, type)
      )
    end
  end

  defp maybe_add_demo_screen(igniter, _module, _name, _type, _demo?), do: igniter

  defp demo_screen_body(module, name, type) do
    """
    @moduledoc \"\"\"
    Demo screen for the `:#{name}` NIF (#{type}-backed).

    Tap "Run NIF" to call `#{inspect(module)}.greet/0` and render the
    returned string. Each call also goes through `Logger.info/1`, so if
    you're connected to the device via `mix mob.connect`, the call shows
    up in your Mac-side IEx as well.

    Generated by `mix mob.add_nif #{name} --type #{type} --demo`.
    Safe to delete — net-additive, no other module references this.
    \"\"\"
    use Mob.Screen

    require Logger

    alias #{inspect(module)}, as: Nif

    def mount(_params, _session, socket) do
      {:ok, Mob.Socket.assign(socket, result: nil, calls: 0, error: nil)}
    end

    def render(assigns) do
      ~MOB\"\"\"
      <Scroll background={:background}>
        <Column background={:background} padding={:space_lg}>
          <Text text="#{Module.split(module) |> List.last()} NIF" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
          <Spacer size={8} />
          <Text text="#{type}-backed" text_size={:xs} text_color={:muted} padding={4} />
          <Spacer size={24} />
          <Button
            text="Run NIF"
            background={:primary}
            text_color={:on_primary}
            text_size={:lg}
            padding={:space_md}
            fill_width={true}
            on_tap={{self(), :run}}
          />
          <Spacer size={16} />
          <Text text={status_label(assigns)} text_size={:md} text_color={status_color(assigns)} padding={:space_sm} />
        </Column>
      </Scroll>
      \"\"\"
    end

    def handle_info({:tap, :run}, socket) do
      calls = socket.assigns.calls + 1

      try do
        result = Nif.greet()
        Logger.info("[#{name}-nif] call \#{calls} returned: \#{inspect(result)}")
        {:noreply, Mob.Socket.assign(socket, result: result, calls: calls, error: nil)}
      rescue
        e ->
          Logger.error("[#{name}-nif] call \#{calls} crashed: \#{Exception.message(e)}")
          {:noreply,
           Mob.Socket.assign(socket,
             error: Exception.message(e),
             calls: calls,
             result: nil
           )}
      end
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    defp status_label(%{result: nil, error: nil}), do: "Tap Run NIF above to call the NIF."

    defp status_label(%{result: r, calls: n, error: nil}) do
      "Result (call \#{n}): " <> to_safe_string(r)
    end

    defp status_label(%{error: msg, calls: n}) do
      "Call \#{n} failed: " <> msg
    end

    defp status_color(%{error: nil, result: nil}), do: :muted
    defp status_color(%{error: nil}), do: :primary
    defp status_color(_), do: :on_surface

    # The NIF can return a charlist (C), a Zig []const u8 (binary), or
    # a Rust String (binary). Render all of them as a binary for the
    # on-screen Text node.
    defp to_safe_string(result) when is_binary(result), do: result
    defp to_safe_string(result) when is_list(result), do: List.to_string(result)
    defp to_safe_string(result), do: inspect(result)
    """
    |> indent_for_module()
    |> wrap_module(Module.concat([module, "Screen"]))
  end

  # Print the wiring instructions AFTER Igniter applies its file changes
  # so the message comes last in stdout, right where the user is looking.
  # We piggyback on Igniter's notices system rather than emitting raw
  # `Mix.shell().info/1` so the message survives `--dry-run` and shows
  # up in the same place as other generator output.
  defp maybe_add_demo_notice(igniter, module, name, true) do
    screen = Module.concat([module, "Screen"])

    Igniter.add_notice(igniter, demo_notice_text(module, screen, name))
  end

  defp maybe_add_demo_notice(igniter, _module, _name, _demo?), do: igniter

  defp demo_notice_text(module, screen, name) do
    """
    Demo screen created: #{inspect(screen)}

    The screen calls `#{inspect(module)}.greet/0` on tap. Three ways to
    see it:

    1. Quick test from IEx (no app changes — easiest):

       mix mob.connect            # connects to your running app
       # In iex:
       node = hd(Node.list())     # or use the printed node name
       :rpc.call(node, Mob.Test, :navigate, [#{inspect(screen)}])

    2. Wire into your existing home screen — add to its render:

       {nav_button("#{name} demo", :open_#{name}_demo)}

       and a `handle_info({:tap, :open_#{name}_demo}, ...)` clause:

       def handle_info({:tap, :open_#{name}_demo}, socket) do
         {:noreply, Mob.Socket.push_screen(socket, #{inspect(screen)})}
       end

    3. Make it the root screen (replaces your home) in your App module's
       navigation/1 callback:

       stack(:main, root: #{inspect(screen)})

    Each call also logs via `Logger.info` so the result shows up in your
    Mac-side IEx if you're connected via `mix mob.connect`.
    """
  end
end
