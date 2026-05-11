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
      |> add_nif(["--type", "rustler"])
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

    test "C file pre-wires ERL_NIF_INIT to the registered name" do
      igniter = add_nif("audio_engine", ["--type", "c"])
      file = Rewrite.source!(igniter.rewrite, "c_src/audio_engine.c")
      content = Rewrite.Source.get(file, :content)
      assert content =~ "ERL_NIF_INIT(audio_engine,"
    end

    test "elixir-only (default) does NOT create c_src/" do
      "audio_engine"
      |> add_nif()
      |> refute_creates("c_src/audio_engine.c")
    end
  end

  describe "post-run notice" do
    test "tells the user to run mix mob.regen_driver_tab" do
      "audio_engine"
      |> add_nif()
      |> assert_has_notice(&(&1 =~ "mix mob.regen_driver_tab"))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp add_nif(name, extra_args \\ []) do
    test_project()
    |> Igniter.compose_task("mob.add_nif", [name | extra_args])
  end

  defp refute_has_issue(igniter), do: assert(igniter.issues == [])
end
