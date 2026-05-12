defmodule MobDev.OtpAudit.SlimTest do
  use ExUnit.Case, async: true

  alias MobDev.OtpAudit.Slim

  # The slim pass operates on an OTP bundle directory in place. Tests
  # build a tmp tree shaped like a real bundle (erts-<vsn>/, lib/<name>-<vsn>/,
  # priv/bin/, src/, include/, *.so, *.a) and assert that each phase
  # removes exactly what it claims to.

  setup do
    root =
      Path.join(System.tmp_dir!(), "mob_otp_slim_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp make_lib(root, name, version, opts) do
    dir = Path.join([root, "lib", "#{name}-#{version}"])
    File.mkdir_p!(Path.join(dir, "ebin"))
    File.write!(Path.join([dir, "ebin", "#{name}.app"]), "{application, #{name}, []}.")

    for mod <- opts[:modules] || ["#{name}_dummy"] do
      File.write!(Path.join([dir, "ebin", "#{mod}.beam"]), beam_or_stub(opts[:real_beam]))
    end

    if opts[:src], do: File.mkdir_p!(Path.join(dir, "src"))
    if opts[:include], do: File.mkdir_p!(Path.join(dir, "include"))
    dir
  end

  # A `.beam` file just bytes the strip_release walker can ignore.
  # We don't want :beam_lib.strip_release/1 to error out the tree
  # because of one stub; it tolerates per-file errors but the test
  # cares about behaviour at the directory level.
  defp beam_or_stub(true), do: real_beam_bytes()
  defp beam_or_stub(_), do: ""

  # Borrow a known-good real beam from the running host. Empty file
  # also works for most phases but :beam_lib.strip_release/1 logs
  # errors on truly empty files, so use a real one to keep test
  # output clean.
  defp real_beam_bytes do
    File.read!(:code.which(Enum))
  end

  defp make_erts(root, vsn) do
    erts = Path.join(root, "erts-#{vsn}")
    File.mkdir_p!(Path.join(erts, "bin"))
    File.write!(Path.join([erts, "bin", "erl"]), "fake")
    File.write!(Path.join([erts, "bin", "erlc"]), "fake")
    erts
  end

  # ── compute_strip_set/1 — pure ─────────────────────────────────────────

  describe "compute_strip_set/1" do
    test "returns the hardcoded baseline when no overrides given" do
      set = Slim.compute_strip_set([])
      assert "megaco" in set
      assert "snmp" in set
      assert "dialyzer" in set
      # Baseline sorted, no duplicates.
      assert set == Enum.sort(Enum.uniq(set))
    end

    test ":drop_libs adds to the baseline" do
      set = Slim.compute_strip_set(drop_libs: ["custom_extra"])
      assert "custom_extra" in set
      # Baseline preserved.
      assert "megaco" in set
    end

    test ":keep_libs subtracts from the baseline" do
      refute "megaco" in Slim.compute_strip_set(keep_libs: ["megaco"])
      # Untouched baseline members still there.
      assert "snmp" in Slim.compute_strip_set(keep_libs: ["megaco"])
    end

    test ":keep_libs wins over :drop_libs when both list the same lib" do
      # Force-keep beats force-drop. This is the safe default: if
      # the user has both, they probably forgot one of them and we'd
      # rather ship a too-fat build than a missing-lib crash.
      refute "myapp" in Slim.compute_strip_set(drop_libs: ["myapp"], keep_libs: ["myapp"])
    end

    test "deduplicates and sorts" do
      set =
        Slim.compute_strip_set(
          drop_libs: ["zzz", "aaa", "megaco", "zzz"],
          keep_libs: []
        )

      assert set == Enum.sort(set)
      assert Enum.count(set, &(&1 == "zzz")) == 1
      assert Enum.count(set, &(&1 == "megaco")) == 1
    end
  end

  # ── compute_strip_set/1 with :audit_input ──────────────────────────────

  describe "compute_strip_set/1 — :audit_input expansion" do
    test "foreign_app_names from the audit always join the strip set" do
      audit = %{
        foreign_app_names: ["pigeon", "push_notify"],
        strippable_libs: [],
        trace_strippable_libs: nil
      }

      set = Slim.compute_strip_set(audit_input: audit)

      assert "pigeon" in set
      assert "push_notify" in set
      # Baseline preserved.
      assert "megaco" in set
    end

    test "without trace, strippable_libs alone does NOT expand the set (NIF false-pos risk)" do
      # exqlite-shape: statically unreachable because static graph
      # can't see :erlang.load_nif, but actually needed at runtime.
      # Without trace, we must NOT strip it.
      audit = %{
        foreign_app_names: [],
        strippable_libs: ["exqlite"],
        trace_strippable_libs: nil
      }

      set = Slim.compute_strip_set(audit_input: audit)

      refute "exqlite" in set
    end

    test "with trace, strippable ∩ trace_strippable joins (high-confidence)" do
      audit = %{
        foreign_app_names: [],
        # exqlite statically unreachable, but trace confirms it IS called
        # — so the intersection excludes it. xmerl unreachable AND not
        # in trace → confirmed.
        strippable_libs: ["xmerl", "exqlite"],
        trace_strippable_libs: ["xmerl", "edoc"]
      }

      set = Slim.compute_strip_set(audit_input: audit)

      assert "xmerl" in set
      refute "exqlite" in set, "trace catches the NIF false-positive — exqlite not stripped"
    end

    test "with trace, trace-only strippable (not in static) joins too" do
      # megaco-shape: 1/65 statically reachable (in static_libs view it
      # is NOT in strippable_libs), trace says 0 modules called → trace
      # alone proves it strippable. This is the unblocking signal.
      audit = %{
        foreign_app_names: [],
        # megaco is NOT statically strippable (some modules reachable).
        strippable_libs: ["xmerl"],
        # But the trace says megaco is never actually called.
        trace_strippable_libs: ["megaco", "xmerl"]
      }

      set = Slim.compute_strip_set(audit_input: audit)

      assert "megaco" in set
      assert "xmerl" in set
    end

    test ":keep_libs still wins over audit-driven expansion" do
      audit = %{
        foreign_app_names: ["pigeon"],
        strippable_libs: ["megaco"],
        trace_strippable_libs: ["megaco", "pigeon"]
      }

      set = Slim.compute_strip_set(audit_input: audit, keep_libs: ["pigeon", "megaco"])

      refute "pigeon" in set
      refute "megaco" in set
    end

    test ":drop_libs combines with audit expansion" do
      audit = %{
        foreign_app_names: ["pigeon"],
        strippable_libs: [],
        trace_strippable_libs: nil
      }

      set = Slim.compute_strip_set(audit_input: audit, drop_libs: ["another_dep"])

      assert "pigeon" in set
      assert "another_dep" in set
    end

    test "nil audit_input is a no-op (default behaviour)" do
      set = Slim.compute_strip_set(audit_input: nil)
      assert set == Slim.compute_strip_set([])
    end

    test "audit_input with no trace-strippable, only foreign — exactly foreign added" do
      audit = %{
        foreign_app_names: ["one_off"],
        strippable_libs: ["unused_otp_lib"],
        trace_strippable_libs: nil
      }

      set = Slim.compute_strip_set(audit_input: audit)

      assert "one_off" in set
      refute "unused_otp_lib" in set
    end
  end

  describe "slim_bundle/2 — :audit_input threading" do
    test "audit-derived foreign apps are stripped on top of the baseline", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "megaco", "4.9", real_beam: true)
      pigeon = Path.join(root, "lib/pigeon-0.1.0")
      make_lib(root, "pigeon", "0.1.0", real_beam: true)

      audit = %{
        foreign_app_names: ["pigeon"],
        strippable_libs: [],
        trace_strippable_libs: nil
      }

      assert {:ok, result} = Slim.slim_bundle(root, audit_input: audit)

      refute File.dir?(pigeon)
      refute File.dir?(Path.join(root, "lib/megaco-4.9"))
      assert File.dir?(Path.join(root, "lib/kernel-11.0"))
      assert "pigeon" in result.strip_set
    end
  end

  describe "hardcoded_prefixes/0" do
    test "is stable across calls" do
      assert Slim.hardcoded_prefixes() == Slim.hardcoded_prefixes()
    end

    test "contains the well-known mobile-stripped libs" do
      # Pinned: changing these is a behaviour change, not a refactor.
      baseline = Slim.hardcoded_prefixes()

      for lib <- ~w(megaco snmp diameter mnesia inets compiler ssh dialyzer xmerl) do
        assert lib in baseline, "expected #{lib} in hardcoded baseline"
      end
    end
  end

  # ── slim_bundle/2 — integration against fixture trees ─────────────────

  describe "slim_bundle/2 — prefix_libs phase" do
    test "strips libs whose basename is in the computed strip set", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "megaco", "4.9", real_beam: true)
      make_lib(root, "snmp", "5.20.3", real_beam: true)

      assert {:ok, _} = Slim.slim_bundle(root)

      refute File.dir?(Path.join(root, "lib/megaco-4.9"))
      refute File.dir?(Path.join(root, "lib/snmp-5.20.3"))
      assert File.dir?(Path.join(root, "lib/kernel-11.0"))
    end

    test ":drop_libs adds libs to the strip set", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "custom_dep", "1.0", real_beam: true)

      assert {:ok, _} = Slim.slim_bundle(root, drop_libs: ["custom_dep"])

      refute File.dir?(Path.join(root, "lib/custom_dep-1.0"))
      assert File.dir?(Path.join(root, "lib/kernel-11.0"))
    end

    test ":keep_libs prevents baseline-listed lib from being stripped", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "megaco", "4.9", real_beam: true)

      assert {:ok, _} = Slim.slim_bundle(root, keep_libs: ["megaco"])

      assert File.dir?(Path.join(root, "lib/megaco-4.9"))
    end

    test "explicit :strip_set short-circuits keep_libs/drop_libs", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "megaco", "4.9", real_beam: true)

      # Empty explicit set means strip nothing in the prefix_libs phase,
      # even though megaco is in the hardcoded baseline.
      assert {:ok, _} =
               Slim.slim_bundle(root,
                 strip_set: [],
                 drop_libs: ["should_be_ignored"],
                 keep_libs: ["should_be_ignored"]
               )

      assert File.dir?(Path.join(root, "lib/megaco-4.9"))
      assert File.dir?(Path.join(root, "lib/kernel-11.0"))
    end
  end

  describe "slim_bundle/2 — apple_binaries phase" do
    test "removes *.so and *.a everywhere under the bundle", %{root: root} do
      lib = make_lib(root, "kernel", "11.0", real_beam: true)
      File.write!(Path.join([lib, "priv", "stuff.so"]) |> tap_mkdir_p(), "x")
      File.write!(Path.join([lib, "priv", "stuff.a"]) |> tap_mkdir_p(), "x")
      File.write!(Path.join([lib, "stuff.so"]), "x")

      Slim.slim_bundle(root)

      assert Path.wildcard("#{root}/**/*.so") == []
      assert Path.wildcard("#{root}/**/*.a") == []
    end

    test "removes priv/bin/* binaries", %{root: root} do
      lib = make_lib(root, "kernel", "11.0", real_beam: true)
      priv_bin = Path.join([lib, "priv", "bin"])
      File.mkdir_p!(priv_bin)
      File.write!(Path.join(priv_bin, "some_tool"), "executable")

      Slim.slim_bundle(root)

      refute File.exists?(Path.join(priv_bin, "some_tool"))
    end

    test "wipes erts-<vsn>/bin executables", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      erts = make_erts(root, "17.0")

      Slim.slim_bundle(root)

      refute File.exists?(Path.join([erts, "bin", "erl"]))
      refute File.exists?(Path.join([erts, "bin", "erlc"]))
      # The erts dir itself is preserved (other erts subdirs may stay).
      assert File.dir?(erts)
    end
  end

  describe "slim_bundle/2 — foreign_apps phase" do
    test "removes lib/{toy_,test_,mob_test,scratch_}*-* directories", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "toy_appp", "0.1.0", real_beam: true)
      make_lib(root, "test_nif", "0.1.0", real_beam: true)
      make_lib(root, "mob_test", "0.5.0", real_beam: true)
      make_lib(root, "scratch_lab", "1.0.0", real_beam: true)
      make_lib(root, "my_real_app", "1.0", real_beam: true)

      Slim.slim_bundle(root)

      refute File.dir?(Path.join(root, "lib/toy_appp-0.1.0"))
      refute File.dir?(Path.join(root, "lib/test_nif-0.1.0"))
      refute File.dir?(Path.join(root, "lib/mob_test-0.5.0"))
      refute File.dir?(Path.join(root, "lib/scratch_lab-1.0.0"))
      assert File.dir?(Path.join(root, "lib/my_real_app-1.0")), "non-prefixed app should remain"
    end
  end

  describe "slim_bundle/2 — dedup_versions phase" do
    test "keeps only the highest version of a lib that appears multiple times", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "asn1", "5.4", real_beam: true)
      make_lib(root, "asn1", "5.4.3", real_beam: true)

      Slim.slim_bundle(root)

      refute File.dir?(Path.join(root, "lib/asn1-5.4"))
      assert File.dir?(Path.join(root, "lib/asn1-5.4.3"))
    end

    test "leaves single-version libs alone", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)

      Slim.slim_bundle(root)

      assert File.dir?(Path.join(root, "lib/kernel-11.0"))
    end
  end

  describe "slim_bundle/2 — src_and_headers phase" do
    test "removes src/ and include/ directories anywhere in the tree", %{root: root} do
      lib = make_lib(root, "kernel", "11.0", real_beam: true, src: true, include: true)

      Slim.slim_bundle(root)

      refute File.dir?(Path.join(lib, "src"))
      refute File.dir?(Path.join(lib, "include"))
      # ebin survives — beam files live there.
      assert File.dir?(Path.join(lib, "ebin"))
    end
  end

  describe "slim_bundle/2 — result shape" do
    test "returns ordered step list with before/after sizes and the final size", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)
      make_lib(root, "megaco", "4.9", real_beam: true)
      make_erts(root, "17.0")

      {:ok, result} = Slim.slim_bundle(root)

      labels = Enum.map(result.steps, & &1.label)

      assert labels == [
               "apple_binaries",
               "prefix_libs",
               "foreign_apps",
               "dedup_versions",
               "src_and_headers",
               "beam_chunks"
             ]

      assert Enum.all?(result.steps, fn s ->
               is_integer(s.before_kb) and is_integer(s.after_kb) and
                 s.after_kb <= s.before_kb
             end)

      assert is_integer(result.final_kb)
      assert result.final_kb <= List.first(result.steps).before_kb
      assert "megaco" in result.strip_set
    end

    test "on_step callback fires once per phase, in order", %{root: root} do
      make_lib(root, "kernel", "11.0", real_beam: true)

      parent = self()

      Slim.slim_bundle(root,
        on_step: fn step -> send(parent, {:step, step.label}) end
      )

      for label <- [
            "apple_binaries",
            "prefix_libs",
            "foreign_apps",
            "dedup_versions",
            "src_and_headers",
            "beam_chunks"
          ] do
        assert_received {:step, ^label}
      end
    end
  end

  # ── detect_erts_vsn/1 ──────────────────────────────────────────────────

  describe "detect_erts_vsn/1" do
    test "returns the erts dir basename when present", %{root: root} do
      make_erts(root, "17.0")
      assert Slim.detect_erts_vsn(root) == "erts-17.0"
    end

    test "returns nil when no erts dir is present", %{root: root} do
      assert Slim.detect_erts_vsn(root) == nil
    end
  end

  # Helper: mkdir_p the parent dir of `path`, returning `path` itself.
  defp tap_mkdir_p(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    path
  end
end
