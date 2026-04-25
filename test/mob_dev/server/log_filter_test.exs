defmodule MobDev.Server.LogFilterTest do
  use ExUnit.Case, async: true

  alias MobDev.Server.LogFilter

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  defp line(attrs) do
    %{
      id: System.unique_integer([:positive]),
      serial: "ABC123",
      level: "I",
      tag: nil,
      message: "hello",
      raw: "I/Tag(1): hello",
      mob: false,
      ts: "12:00:00"
    }
    |> Map.merge(attrs)
  end

  # ── by_device/2 ───────────────────────────────────────────────────────────────

  describe "by_device/2" do
    test ":all returns all lines unchanged" do
      lines = [line(%{mob: false}), line(%{mob: true})]
      assert LogFilter.by_device(lines, :all) == lines
    end

    test ":app returns only mob-tagged lines" do
      mob_line = line(%{mob: true})
      sys_line = line(%{mob: false})
      assert LogFilter.by_device([mob_line, sys_line], :app) == [mob_line]
    end

    test "serial filter returns only lines for that device" do
      a = line(%{serial: "AAA"})
      b = line(%{serial: "BBB"})
      assert LogFilter.by_device([a, b], "AAA") == [a]
      assert LogFilter.by_device([a, b], "BBB") == [b]
      assert LogFilter.by_device([a, b], "CCC") == []
    end

    test "returns empty list when input is empty" do
      assert LogFilter.by_device([], :all) == []
      assert LogFilter.by_device([], :app) == []
    end
  end

  # ── by_text/2 ─────────────────────────────────────────────────────────────────

  describe "by_text/2" do
    test "empty string returns all lines" do
      lines = [line(%{message: "foo"}), line(%{message: "bar"})]
      assert LogFilter.by_text(lines, "") == lines
    end

    test "matches message substring (case-insensitive)" do
      match = line(%{message: "Tap me pressed — count is now 1", raw: ""})
      no_match = line(%{message: "set_root: pushed node", raw: ""})
      result = LogFilter.by_text([match, no_match], "tap")
      assert result == [match]
    end

    test "match is case-insensitive" do
      l = line(%{message: "[INFO] something happened", raw: ""})
      assert LogFilter.by_text([l], "info") == [l]
      assert LogFilter.by_text([l], "INFO") == [l]
      assert LogFilter.by_text([l], "Info") == [l]
    end

    test "matches raw field when message doesn't match" do
      l = line(%{message: "plain text", raw: "I/Elixir(123): plain text"})
      assert LogFilter.by_text([l], "Elixir") == [l]
    end

    test "comma-separated terms are OR'd" do
      info_line = line(%{message: "[info] tap pressed", raw: ""})
      error_line = line(%{message: "[error] crash", raw: ""})
      debug_line = line(%{message: "[debug] verbose", raw: ""})
      result = LogFilter.by_text([info_line, error_line, debug_line], "info, error")
      assert result == [info_line, error_line]
    end

    test "extra whitespace around comma-separated terms is trimmed" do
      l = line(%{message: "hello world", raw: ""})
      assert LogFilter.by_text([l], "  hello  ,  world  ") == [l]
    end

    test "blank terms between commas are ignored" do
      l = line(%{message: "hello", raw: ""})
      assert LogFilter.by_text([l], ",, hello ,,") == [l]
    end

    test "no match returns empty list" do
      l = line(%{message: "hello", raw: ""})
      assert LogFilter.by_text([l], "xyz_not_present") == []
    end

    test "filter by log level tag like [info]" do
      info = line(%{message: "[info] counter incremented", raw: ""})
      error = line(%{message: "[error] nif failed", raw: ""})
      other = line(%{message: "set_root pushed", raw: ""})
      assert LogFilter.by_text([info, error, other], "[info]") == [info]
    end
  end

  # ── apply/3 (combined) ────────────────────────────────────────────────────────

  describe "apply/3" do
    test "combines device filter and text filter with AND logic" do
      a = line(%{serial: "DEV1", mob: true, message: "tap pressed", raw: ""})
      b = line(%{serial: "DEV1", mob: true, message: "set_root", raw: ""})
      c = line(%{serial: "DEV2", mob: true, message: "tap pressed", raw: ""})

      # Device DEV1 AND text "tap"
      assert LogFilter.apply([a, b, c], "DEV1", "tap") == [a]
    end

    test ":all device + empty text returns everything" do
      lines = [line(%{}), line(%{mob: true})]
      assert LogFilter.apply(lines, :all, "") == lines
    end

    test ":app device + text filter" do
      mob_tap = line(%{mob: true, message: "tap", raw: ""})
      mob_other = line(%{mob: true, message: "set_root", raw: ""})
      sys_tap = line(%{mob: false, message: "tap", raw: ""})
      result = LogFilter.apply([mob_tap, mob_other, sys_tap], :app, "tap")
      assert result == [mob_tap]
    end
  end

  # ── matches?/3 ────────────────────────────────────────────────────────────────

  describe "matches?/3" do
    test "returns true when both filters pass" do
      l = line(%{mob: true, message: "tap", raw: ""})
      assert LogFilter.matches?(l, :app, "tap")
    end

    test "returns false when device filter fails" do
      l = line(%{mob: false, message: "tap", raw: ""})
      refute LogFilter.matches?(l, :app, "tap")
    end

    test "returns false when text filter fails" do
      l = line(%{mob: true, message: "unrelated", raw: ""})
      refute LogFilter.matches?(l, :app, "tap")
    end

    test "returns true with :all and empty text" do
      l = line(%{mob: false, message: "anything", raw: ""})
      assert LogFilter.matches?(l, :all, "")
    end
  end
end
