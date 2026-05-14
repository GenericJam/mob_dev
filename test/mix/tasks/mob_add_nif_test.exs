defmodule Mix.Tasks.Mob.AddNifTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "name validation" do
    test "rejects PascalCase names" do
      "AudioEngine"
      |> add_nif()
      |> assert_has_issue(&(&1 =~ "snake_case"))
    end

    test "rejects names that don't start with a letter" do
      "_audio"
      |> add_nif()
      |> assert_has_issue(&(&1 =~ "snake_case"))
    end

    test "rejects names with hyphens" do
      "audio-engine"
      |> add_nif()
      |> assert_has_issue(&(&1 =~ "snake_case"))
    end

    test "rejects empty names" do
      ""
      |> add_nif()
      |> assert_has_issue(&(&1 =~ "snake_case"))
    end

    test "accepts standard snake_case names" do
      "audio_engine"
      |> add_nif()
      |> refute_has_issue()
    end

    test "accepts names with digits after the leading letter" do
      "sqlite3_nif"
      |> add_nif()
      |> refute_has_issue()
    end
  end

  describe "type validation" do
    test "rejects unknown --type values" do
      "audio_engine"
      |> add_nif(["--type", "haskell"])
      |> assert_has_issue(&(&1 =~ "Unknown --type"))
    end

    test "accepts --type elixir-only (default)" do
      "audio_engine"
      |> add_nif()
      |> refute_has_issue()
    end

    test "accepts --type c" do
      "audio_engine"
      |> add_nif(["--type", "c"])
      |> refute_has_issue()
    end
  end

  describe "Elixir stub" do
    test "creates lib/<app>/nifs/<name>.ex by default" do
      "audio_engine"
      |> add_nif()
      |> assert_creates("lib/test/nifs/audio_engine.ex")
    end

    test "stub module declares @on_load and load_nif/0" do
      igniter = add_nif("audio_engine")
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "@on_load :load_nif"
      assert content =~ "def load_nif"
      assert content =~ ~s|:erlang.load_nif(~c"audio_engine", 0)|
    end

    test "stub fns return :erlang.nif_error so missing native side errors loudly" do
      igniter = add_nif("audio_engine")
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ":erlang.nif_error(:nif_not_loaded)"
    end

    test "--module overrides the default module name" do
      "audio_engine"
      |> add_nif(["--module", "Test.Audio"])
      |> assert_creates("lib/test/audio.ex")
    end
  end

  describe "mob.exs :static_nifs" do
    test "creates :static_nifs key when absent" do
      igniter =
        test_project(files: %{"mob.exs" => "import Config\nconfig :mob_dev, mob_dir: \"/x\"\n"})
        |> Igniter.compose_task("mob.add_nif", ["audio_engine"])

      file = Rewrite.source!(igniter.rewrite, "mob.exs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "static_nifs:"
      assert content =~ "module: :audio_engine"
      assert content =~ "archs: [:all]"
    end

    test "appends to existing :static_nifs without nuking other entries" do
      mob_exs = """
      import Config

      config :mob_dev,
        static_nifs: [%{module: :existing_one, archs: [:all]}]
      """

      igniter =
        test_project(files: %{"mob.exs" => mob_exs})
        |> Igniter.compose_task("mob.add_nif", ["audio_engine"])

      file = Rewrite.source!(igniter.rewrite, "mob.exs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "module: :existing_one"
      assert content =~ "module: :audio_engine"
    end

    test "is idempotent — re-adding the same NIF doesn't double up" do
      mob_exs = """
      import Config
      config :mob_dev, static_nifs: [%{module: :audio_engine, archs: [:all]}]
      """

      igniter =
        test_project(files: %{"mob.exs" => mob_exs})
        |> Igniter.compose_task("mob.add_nif", ["audio_engine"])

      file = Rewrite.source!(igniter.rewrite, "mob.exs")
      content = Rewrite.Source.get(file, :content)
      # Exactly one occurrence — re-running shouldn't append another row.
      assert content |> String.split("module: :audio_engine") |> length() == 2
    end
  end

  describe "C skeleton (--type c)" do
    test "creates c_src/<name>.c with --type c" do
      "audio_engine"
      |> add_nif(["--type", "c"])
      |> assert_creates("c_src/audio_engine.c")
    end

    test "C file pre-wires ERL_NIF_INIT to the Elixir.<Module> form" do
      # First arg to ERL_NIF_INIT must be the BEAM module name —
      # `Elixir.<DotPath>` for Elixir modules — so the static-NIF
      # table lookup matches what `:erlang.load_nif/2` is called
      # with from the Elixir stub. Empirically verified on iPhone:
      # using bare `audio_engine` makes BEAM fall through to dlopen
      # and fail because the entry.name doesn't match the module.
      # See mob.add_nif's c_skeleton/3 docstring for the full diagnosis.
      igniter = add_nif("audio_engine", ["--type", "c"])
      file = Rewrite.source!(igniter.rewrite, "c_src/audio_engine.c")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "ERL_NIF_INIT(Elixir.Test.Nifs.AudioEngine,"
    end

    test "elixir-only (default) does NOT create c_src/" do
      "audio_engine"
      |> add_nif()
      |> refute_creates("c_src/audio_engine.c")
    end
  end

  describe "--type zigler" do
    test "stub uses `use Zig` macro instead of @on_load + load_nif" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "use Zig, otp_app: :test"
      refute content =~ "@on_load"
      refute content =~ ":erlang.load_nif"
    end

    test "stub embeds an example pub fn in a ~Z sigil" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "~Z\""
      assert content =~ "pub fn add_one"
    end

    test "moduledoc warns about Mob's static-link incompatibility" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      # Surface the gotcha so users don't ship a dlopen'd .so by accident.
      assert content =~ "Static linking"
    end

    test "adds :zigler to mix.exs deps" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "mix.exs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ":zigler"
    end

    test "does NOT create c_src/<name>.c (zigler manages its own native side)" do
      "audio_engine"
      |> add_nif(["--type", "zigler"])
      |> refute_creates("c_src/audio_engine.c")
    end

    test "still appends to mob.exs :static_nifs" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "mob.exs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "module: :audio_engine"
    end

    test "queues mix zig.get so Zigler uses its own pinned Zig" do
      # Without this, Zigler 0.15.x falls back to System.find_executable("zig")
      # and uses whatever's on PATH (typically the wrong version).
      # zig.get downloads Zig 0.15.2 to the user-cache directory, which
      # Zigler's executable_path/0 checks before PATH.
      "audio_engine"
      |> add_nif(["--type", "zigler"])
      |> assert_has_task("zig.get", [])
    end

    test "moduledoc warns about the Zig toolchain pin (mix zig.get)" do
      igniter = add_nif("audio_engine", ["--type", "zigler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      # If we ever stop auto-running zig.get, this assertion still
      # tells users they need to.
      assert content =~ "zig.get"
    end
  end

  describe "--type rustler" do
    test "stub uses `use Rustler` with otp_app + crate" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "use Rustler, otp_app: :test, crate: \"audio_engine\""
    end

    test "stub keeps :erlang.nif_error fallback so missing native errors loudly" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ":erlang.nif_error(:nif_not_loaded)"
    end

    test "moduledoc warns about Mob's static-link incompatibility" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "Static linking"
    end

    test "adds :rustler to mix.exs deps" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "mix.exs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ":rustler"
    end

    test "creates native/<name>/Cargo.toml with the right [package] name" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/Cargo.toml")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ~s|name = "audio_engine"|
      assert content =~ "rustler"
    end

    test "Cargo.toml emits both staticlib and cdylib crate types" do
      # staticlib is required for Mob's iOS/Android device builds (the
      # .a gets linked into the main binary). cdylib keeps the host-dev
      # `mix compile` path working. Empirically verified end-to-end on
      # iPhone: removing staticlib here would leave the user stuck after
      # the host-dev demo works, with no path to actually ship.
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/Cargo.toml")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "staticlib"
      assert content =~ "cdylib"
    end

    test "Cargo.toml pins rustler 0.37+ for the per-crate nif_init symbol" do
      # Rustler 0.37+ derives the static-NIF init symbol name from
      # CARGO_CRATE_NAME as `<crate>_nif_init`, matching what Mob's
      # driver_tab declares. Older versions hardcode `nif_init` and
      # need manual symbol-renaming. Don't quietly downgrade this pin.
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/Cargo.toml")
      content = Rewrite.Source.get(file, :content)
      assert content =~ ~r/rustler\s*=\s*"0\.(3[7-9]|[4-9]\d)/
    end

    test "Cargo.toml patches rustler to the Android-dlsym-fix fork (mob#7)" do
      # Rustler 0.37's nif_filler uses dlopen(NULL) to find enif_* symbols.
      # On Bionic that handle doesn't see the app's RTLD_GLOBAL-promoted .so
      # — every NIF init panics with `undefined symbol: enif_priv_data`.
      # The GenericJam fork patches the Android branch. Without this
      # [patch.crates-io] block in the scaffolded Cargo.toml, a user who
      # follows the docs hits the panic on first Android deploy and has
      # to figure out the workaround themselves. Drop the block (and this
      # test) once upstream rustler ships the fix.
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/Cargo.toml")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "[patch.crates-io]"
      assert content =~ "github.com/GenericJam/rustler"
      assert content =~ "genericjam-android-rtld-default"

      # The block must carry a "drop when upstream merges" cue. Without it,
      # someone bumps the rustler version, forgets the patch, and either
      # (a) breaks Android again, or (b) keeps shipping a workaround forever.
      assert content =~ ~r/DROP WHEN|once upstream/i
    end

    test "creates native/<name>/src/lib.rs with rustler::init! pointing at the Elixir module" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/src/lib.rs")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "#[rustler::nif]"
      assert content =~ "fn add_one"
      assert content =~ ~s|rustler::init!("Elixir.Test.Nifs.AudioEngine"|
    end

    test "creates native/<name>/.gitignore with /target" do
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/.gitignore")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "/target"
    end

    test "does NOT create c_src/<name>.c (Rustler manages its own native side via Cargo)" do
      "audio_engine"
      |> add_nif(["--type", "rustler"])
      |> refute_creates("c_src/audio_engine.c")
    end

    test "creates native/<name>/.cargo/config.toml with -undefined dynamic_lookup for macOS" do
      # Rustler's default cdylib references enif_* symbols that aren't
      # resolved until BEAM dlopen. macOS ld64 errors on undefined
      # symbols without `-undefined dynamic_lookup`, so first
      # `mix compile` on a Mac fails with:
      #
      #   Undefined symbols: _enif_raise_exception, _enif_schedule_nif
      #
      # The config file deferring symbols at link time is what makes the
      # scaffold compile out-of-the-box on macOS. Linux linkers defer by
      # default and ignore this file (rustflags scope is Apple-only).
      igniter = add_nif("audio_engine", ["--type", "rustler"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/.cargo/config.toml")
      content = Rewrite.Source.get(file, :content)

      assert content =~ "[target.aarch64-apple-darwin]"
      assert content =~ "[target.x86_64-apple-darwin]"
      assert content =~ "link-arg=-undefined"
      assert content =~ "link-arg=dynamic_lookup"
    end
  end

  describe "--demo flag" do
    test "rejects --demo with --type elixir-only (no NIF to call)" do
      igniter = add_nif("audio_engine", ["--type", "elixir-only", "--demo"])
      issues = igniter.issues

      assert Enum.any?(issues, &String.contains?(&1, "--demo requires a native backend"))
    end

    test "creates a demo screen module alongside the stub" do
      igniter = add_nif("audio_engine", ["--type", "c", "--demo"])
      # The screen lives under the NIF stub's namespace: <Stub>.Screen.
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine/screen.ex")
      content = Rewrite.Source.get(file, :content)

      assert content =~ "defmodule Test.Nifs.AudioEngine.Screen"
      assert content =~ "use Mob.Screen"
      # The screen calls greet/0 on the stub module.
      assert content =~ "alias Test.Nifs.AudioEngine"
      assert content =~ "Nif.greet()"
      # Logs each call so IEx sees it.
      assert content =~ "require Logger"
      assert content =~ "Logger.info"
    end

    test "demo screen NOT generated without --demo" do
      "audio_engine"
      |> add_nif(["--type", "c"])
      |> refute_creates("lib/test/nifs/audio_engine/screen.ex")
    end

    test "C stub uses greet/0 when --demo (instead of hello/1)" do
      igniter = add_nif("audio_engine", ["--type", "c", "--demo"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)

      assert content =~ "def greet()"
      refute content =~ "def hello(_arg)"
    end

    test "C source returns \"Hello from C!\" when --demo" do
      igniter = add_nif("audio_engine", ["--type", "c", "--demo"])
      file = Rewrite.source!(igniter.rewrite, "c_src/audio_engine.c")
      content = Rewrite.Source.get(file, :content)

      assert content =~ ~s|"Hello from C!"|
      assert content =~ ~s|{"greet", 0,|
      # 0-arity, not the default hello/1 from the non-demo path.
      refute content =~ "hello_from_native"
    end

    test "Zigler stub returns \"Hello from Zig!\" via ~Z when --demo" do
      igniter = add_nif("audio_engine", ["--type", "zigler", "--demo"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)

      assert content =~ ~s|"Hello from Zig!"|
      assert content =~ "pub fn greet()"
    end

    test "Rust crate returns \"Hello from Rust!\" when --demo" do
      igniter = add_nif("audio_engine", ["--type", "rustler", "--demo"])
      file = Rewrite.source!(igniter.rewrite, "native/audio_engine/src/lib.rs")
      content = Rewrite.Source.get(file, :content)

      assert content =~ ~s|"Hello from Rust!"|
      assert content =~ "fn greet()"
      assert content =~ "rustler::init!"
      assert content =~ "[greet]"
    end

    test "Rust stub Elixir-side uses greet/0 (not add_one/1) when --demo" do
      igniter = add_nif("audio_engine", ["--type", "rustler", "--demo"])
      file = Rewrite.source!(igniter.rewrite, "lib/test/nifs/audio_engine.ex")
      content = Rewrite.Source.get(file, :content)

      assert content =~ "def greet()"
      refute content =~ "def add_one(_input)"
    end

    test "prints a notice with three wiring options after generation" do
      igniter = add_nif("audio_engine", ["--type", "c", "--demo"])

      notice = Enum.find(igniter.notices, &String.contains?(&1, "Demo screen created"))
      assert notice, "no demo-notice in igniter.notices"

      # The three options the user can pick from.
      assert notice =~ "Quick test from IEx"
      assert notice =~ "Wire into your existing home screen"
      assert notice =~ "root screen"

      # Mentions Logger so the user knows the IEx visibility path.
      assert notice =~ "Logger.info"
    end
  end

  describe "regen composition" do
    test "queues mob.regen_driver_tab to run after Igniter applies its changes" do
      "audio_engine"
      |> add_nif()
      |> assert_has_task("mob.regen_driver_tab", [])
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp add_nif(name, extra_args \\ []) do
    test_project()
    |> Igniter.compose_task("mob.add_nif", [name | extra_args])
  end

  defp refute_has_issue(igniter), do: assert(igniter.issues == [])
end
