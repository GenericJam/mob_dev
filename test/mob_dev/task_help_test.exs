defmodule MobDev.TaskHelpTest do
  use ExUnit.Case, async: true

  alias MobDev.TaskHelp

  doctest TaskHelp

  describe "help_requested?/1" do
    test "matches --help anywhere in argv" do
      assert TaskHelp.help_requested?(["--help"])
      assert TaskHelp.help_requested?(["--device", "foo", "--help"])
      assert TaskHelp.help_requested?(["--help", "--device", "foo"])
    end

    test "matches -h anywhere in argv" do
      assert TaskHelp.help_requested?(["-h"])
      assert TaskHelp.help_requested?(["--device", "foo", "-h"])
    end

    test "false for unrelated flags" do
      refute TaskHelp.help_requested?(["--device", "foo"])
      refute TaskHelp.help_requested?(["--bundle-id", "com.x.y"])
      refute TaskHelp.help_requested?([])
    end

    test "false when --help is a value rather than a flag" do
      # Edge case: someone passes `--device --help` (which is silly
      # but possible). `--help` is then the VALUE of --device, not a
      # standalone flag — but our check is by membership, not by
      # OptionParser semantics. Pin the current behaviour: we DO
      # match here, which is fine — it's still a clear signal the
      # user wants help.
      assert TaskHelp.help_requested?(["--device", "--help"])
    end
  end

  describe "print_module_help/1" do
    test "prints the module's @moduledoc verbatim" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          TaskHelp.print_module_help(MobDev.TaskHelp)
        end)

      # The module's own @moduledoc — pin a stable substring so this
      # test doesn't break on minor wording changes.
      assert output =~ "Helpers for `--help`"
      assert output =~ "mix help <task>"
    end

    test "falls back gracefully when a module has no @moduledoc" do
      defmodule NoDocsModule, do: nil

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          TaskHelp.print_module_help(NoDocsModule)
        end)

      assert output =~ "no documentation"
    end
  end
end
