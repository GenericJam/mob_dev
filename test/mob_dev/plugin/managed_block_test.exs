defmodule MobDev.Plugin.ManagedBlockTest do
  use ExUnit.Case, async: true
  alias MobDev.Plugin.ManagedBlock

  @markers {"<!-- BEGIN -->", "<!-- END -->"}
  @doc_anchor "</application>"

  # A place fn that drops the region on its own lines just before `anchor`.
  defp place(anchor),
    do: fn stripped, region ->
      ManagedBlock.insert_before(stripped, anchor, region)
    end

  describe "upsert/4 — insert" do
    test "drops a fenced region before the anchor line" do
      content = "  <thing/>\n  </application>\n"
      out = ManagedBlock.upsert(content, @markers, "  <svc/>", place(@doc_anchor))

      assert out ==
               "  <thing/>\n<!-- BEGIN -->\n  <svc/>\n<!-- END -->\n  </application>\n"
    end

    test "an empty body inserts nothing" do
      content = "  </application>\n"
      assert ManagedBlock.upsert(content, @markers, "", place(@doc_anchor)) == content
      assert ManagedBlock.upsert(content, @markers, "   \n  ", place(@doc_anchor)) == content
    end
  end

  describe "upsert/4 — idempotence & replacement" do
    @content "<a/>\n</application>\n"

    test "running twice with the same body is a fixed point" do
      once = ManagedBlock.upsert(@content, @markers, "  <svc/>", place(@doc_anchor))
      twice = ManagedBlock.upsert(once, @markers, "  <svc/>", place(@doc_anchor))
      assert once == twice
      # exactly one region
      assert length(String.split(once, "<!-- BEGIN -->")) == 2
    end

    test "a changed body replaces the region (old contents gone)" do
      v1 = ManagedBlock.upsert(@content, @markers, "  <old/>", place(@doc_anchor))
      v2 = ManagedBlock.upsert(v1, @markers, "  <new/>", place(@doc_anchor))
      assert v2 =~ "<new/>"
      refute v2 =~ "<old/>"
      assert length(String.split(v2, "<!-- BEGIN -->")) == 2
    end

    test "an empty body REMOVES an existing region (the reversibility property)" do
      with_region = ManagedBlock.upsert(@content, @markers, "  <svc/>", place(@doc_anchor))
      removed = ManagedBlock.upsert(with_region, @markers, "", place(@doc_anchor))
      assert removed == @content
      refute removed =~ "BEGIN"
    end
  end

  describe "strip/2" do
    test "removes exactly the region's whole lines, leaving surrounding content" do
      content = "keep-before\n  <!-- BEGIN -->\n  junk\n  <!-- END -->\nkeep-after\n"
      assert ManagedBlock.strip(content, @markers) == "keep-before\nkeep-after\n"
    end

    test "is a no-op when the region is absent" do
      assert ManagedBlock.strip("nothing here\n", @markers) == "nothing here\n"
    end

    test "is a no-op when the end marker precedes the begin marker (malformed)" do
      content = "<!-- END -->\nx\n<!-- BEGIN -->\n"
      assert ManagedBlock.strip(content, @markers) == content
    end

    test "an orphan BEGIN before a real region does NOT eat the host lines between them (F1)" do
      # The data-loss case: naive first-BEGIN→first-END would delete
      # "host-line" too. We must remove only the real region.
      content =
        "<!-- BEGIN -->\nhost-line-that-must-survive\n" <>
          "<!-- BEGIN -->\nplugin-body\n<!-- END -->\nafter\n"

      out = ManagedBlock.strip(content, @markers)
      assert out =~ "host-line-that-must-survive"
      refute out =~ "plugin-body"
      # the real region (2nd BEGIN + END) is gone; the orphan BEGIN marker lingers
      # harmlessly but no host content was lost
      assert out == "<!-- BEGIN -->\nhost-line-that-must-survive\nafter\n"
    end

    test "clears duplicate well-formed regions (loops until none remain)" do
      content =
        "<!-- BEGIN -->\na\n<!-- END -->\nkeep\n<!-- BEGIN -->\nb\n<!-- END -->\n"

      assert ManagedBlock.strip(content, @markers) == "keep\n"
    end

    test "a trailing orphan BEGIN after a region is left alone (no host loss)" do
      content = "<!-- BEGIN -->\nbody\n<!-- END -->\nhost\n<!-- BEGIN -->\n"
      assert ManagedBlock.strip(content, @markers) == "host\n<!-- BEGIN -->\n"
    end

    test "strip is the left inverse of place (round-trip)" do
      base = "line1\nline2\n</application>\ntail\n"
      placed = ManagedBlock.upsert(base, @markers, "  body1\n  body2", place(@doc_anchor))
      assert ManagedBlock.strip(placed, @markers) == base
    end
  end

  describe "insert_before/3 + insert_before_index/3" do
    test "insert_before puts the region on its own lines before the anchor's line" do
      assert ManagedBlock.insert_before("a\n  }\n", "}", "R") == "a\nR\n  }\n"
    end

    test "insert_before is a no-op when the anchor is absent" do
      assert ManagedBlock.insert_before("a\nb\n", "zzz", "R") == "a\nb\n"
    end

    test "insert_before_index inserts before the line containing the index" do
      content = "abc\ndefXghi\n"
      idx = :binary.match(content, "X") |> elem(0)
      assert ManagedBlock.insert_before_index(content, idx, "R") == "abc\nR\ndefXghi\n"
    end
  end
end
