defmodule Mix.Tasks.Mob.AddNif do
  @moduledoc """
  Scaffolds a new statically-linked NIF in the current Mob project.

      mix mob.add_nif <name>                   # default: --type elixir-only
      mix mob.add_nif <name> --type c          # also drops c_src/<name>.c skeleton
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

  After the run, regenerate the driver_tab to pick up the new entry:

      mix mob.regen_driver_tab

  (this is a notice the task prints — Phase 0 plans to wire regen into
  `mix compile` so manual invocation goes away.)

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
      schema: [type: :string, module: :string],
      defaults: [type: "elixir-only"],
      positional: [:name]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    %{name: name} = igniter.args.positional
    options = igniter.args.options

    with :ok <- validate_name(name),
         :ok <- validate_type(options[:type]) do
      module = resolve_module(igniter, name, options[:module])

      igniter
      |> add_elixir_stub(module, name)
      |> add_static_nif_entry(name)
      |> maybe_add_c_skeleton(name, options[:type])
      |> Igniter.add_notice(after_notice(name))
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

  defp validate_type(type) when type in ["elixir-only", "c"], do: :ok

  defp validate_type(other) do
    {:error,
     "Unknown --type #{inspect(other)}. Supported: elixir-only, c. " <>
       "(zigler/rustler land in later iters.)"}
  end

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

  defp add_elixir_stub(igniter, module, name) do
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      # Re-run idempotency: leave the existing module alone. If the user has
      # added their own functions to the stub we don't want to clobber them.
      igniter
    else
      Igniter.Project.Module.create_module(igniter, module, stub_body(module, name))
    end
  end

  defp stub_body(module, name) do
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

    @doc \"\"\"
    Example NIF entry point. Replace with your own functions.
    \"\"\"
    def hello(_arg), do: :erlang.nif_error(:nif_not_loaded)
    """
    |> indent_for_module()
    |> wrap_module(module)
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

  defp maybe_add_c_skeleton(igniter, name, "c") do
    path = "c_src/#{name}.c"

    if File.exists?(path) do
      # Re-run idempotency: don't overwrite a C file the user may have edited.
      igniter
    else
      Igniter.create_new_file(igniter, path, c_skeleton(name))
    end
  end

  defp maybe_add_c_skeleton(igniter, _name, _other), do: igniter

  defp c_skeleton(name) do
    """
    /*
     * c_src/#{name}.c — statically-linked NIF for `:#{name}`.
     *
     * This file is linked into the app's main binary alongside libbeam.a
     * (NOT loaded via dlopen — see MobDev.StaticNifs for why). The
     * generated driver_tab_{ios,android}.c registers `#{name}_nif_init`
     * so `load_nif/2` from the Elixir stub binds these functions in.
     *
     * Wire this file into your platform builds:
     *   - Android: add to android/app/src/main/jni/CMakeLists.txt as
     *     a target_sources entry on the main library target.
     *   - iOS: add as a `b.addCSourceFile` step in ios/build.zig and
     *     ios/build_device.zig, alongside driver_tab_ios.c.
     */

    #include <erl_nif.h>

    static ERL_NIF_TERM hello(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        (void)argc;
        (void)argv;
        return enif_make_atom(env, "hello_from_native");
    }

    static ErlNifFunc nif_funcs[] = {
        {"hello", 1, hello, 0}
    };

    /* The init function name MUST match `<name>_nif_init` so the generated
     * driver_tab declares + dispatches it correctly. The 4th arg ("schema
     * version") is unused for static NIFs — pass 0. */
    ERL_NIF_INIT(#{name}, nif_funcs, NULL, NULL, NULL, NULL)
    """
  end

  # ── Post-run notice ───────────────────────────────────────────────────────

  defp after_notice(name) do
    """
    Added NIF `:#{name}`. Next step:

      mix mob.regen_driver_tab

    This regenerates priv/generated/driver_tab_{ios,android}.c so the new
    entry appears in the static NIF table. Skipping this step means
    `load_nif/2` will fall back to dlopen at runtime and fail.
    """
  end
end
