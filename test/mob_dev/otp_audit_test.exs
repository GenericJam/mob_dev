defmodule MobDev.OtpAuditTest do
  use ExUnit.Case, async: true

  # Tests OtpAudit against a synthetic OTP tree built in tmp. Real OTP
  # trees take seconds to walk and are tied to the host's installed OTP,
  # so we fake the parts we need: lib/<name>-<vsn>/ebin/<name>.app.
  #
  # The .beam files are intentionally bogus — `read_imports/1` swallows
  # parse errors and returns []. That's enough to exercise discovery,
  # dedup, and foreign-app detection without compiling Erlang at test time.
  # The reachability BFS itself has no shape to assert without real beams,
  # which is why it's covered by the empirical OtpTrace harness instead.

  alias MobDev.OtpAudit

  setup do
    root =
      Path.join(System.tmp_dir!(), "mob_otp_audit_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp make_lib(root, name, version, opts \\ []) do
    dir = Path.join([root, "lib", "#{name}-#{version}"])
    File.mkdir_p!(Path.join(dir, "ebin"))

    mod_clause =
      case opts[:mod] do
        nil -> ""
        mod when is_atom(mod) -> ", {mod, {#{mod}, []}}"
      end

    app_contents =
      "{application, #{name}, [{description, \"test\"}, {vsn, \"#{version}\"}, " <>
        "{modules, []}, {applications, []}#{mod_clause}]}.\n"

    File.write!(Path.join([dir, "ebin", "#{name}.app"]), app_contents)

    for module <- opts[:modules] || [] do
      # An empty file is enough — beam_lib:chunks/2 errors out and
      # read_imports/1 returns []. We only need the module to be
      # discoverable for modules_total / modules_reachable counts.
      File.write!(Path.join([dir, "ebin", "#{module}.beam"]), "")
    end

    dir
  end

  describe "audit/2 — lib discovery" do
    test "finds every <name>-<vsn>/ebin tree under the OTP root", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists", "maps"])
      make_lib(root, "elixir", "1.18.0", modules: ["Elixir.Kernel"])

      report = OtpAudit.audit(root)

      names = Enum.map(report.libs, & &1.name) |> Enum.sort()
      assert names == ["elixir", "kernel", "stdlib"]
    end

    test "records modules_total per lib", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists", "maps", "sets"])

      report = OtpAudit.audit(root)
      stdlib = Enum.find(report.libs, &(&1.name == "stdlib"))
      assert stdlib.modules_total == 3
    end
  end

  describe "audit/2 — duplicate version collapse" do
    test "keeps only the highest version when a lib appears twice", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "asn1", "5.4")
      make_lib(root, "asn1", "5.4.3")

      report = OtpAudit.audit(root)
      asn1 = Enum.find(report.libs, &(&1.name == "asn1"))
      assert asn1.version == "5.4.3"
    end

    test "reports the dropped versions under :duplicates", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      older = make_lib(root, "asn1", "5.4")
      _newer = make_lib(root, "asn1", "5.4.3")

      report = OtpAudit.audit(root)
      assert Map.has_key?(report.duplicates, "asn1")
      assert older in report.duplicates["asn1"]
    end

    test "handles three+ versions of the same lib", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "public_key", "1.18")
      make_lib(root, "public_key", "1.20.2")
      make_lib(root, "public_key", "1.20.3")

      report = OtpAudit.audit(root)
      pk = Enum.find(report.libs, &(&1.name == "public_key"))
      assert pk.version == "1.20.3"
      assert length(report.duplicates["public_key"]) == 2
    end
  end

  describe "audit/2 — foreign app detection" do
    test "flags libs that look like other projects' apps", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      foreign = make_lib(root, "toy_appp", "0.1.0", modules: ["Elixir.ToyAppp"])
      _stranger = make_lib(root, "test_nif", "0.1.0", modules: ["Elixir.TestNif"])

      report = OtpAudit.audit(root, app_name: :my_app)
      assert foreign in report.foreign_apps
      assert length(report.foreign_apps) == 2
    end

    test "does not flag the app under test as foreign", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "toy_appp", "0.1.0", modules: ["Elixir.ToyAppp"])
      make_lib(root, "test_nif", "0.1.0", modules: ["Elixir.TestNif"])

      # Even though `test_nif` matches looks_like_user_app?, naming it
      # the app under test should keep it out of foreign_apps.
      report = OtpAudit.audit(root, app_name: :test_nif)
      paths = report.foreign_apps
      refute Enum.any?(paths, &String.contains?(&1, "test_nif-"))
    end

    test "leaves OTP libs out of foreign_apps regardless of app_name", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "asn1", "5.4.3")

      report = OtpAudit.audit(root, app_name: :something_else)
      assert report.foreign_apps == []
    end
  end

  describe "audit/2 — size accounting" do
    test "totals are non-negative integers", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])

      report = OtpAudit.audit(root)
      assert is_integer(report.total_kb) and report.total_kb >= 0
      assert is_integer(report.reachable_kb) and report.reachable_kb >= 0
      assert is_integer(report.strippable_kb) and report.strippable_kb >= 0
    end

    test "strippable_libs lists libs with zero reachable modules", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      # No app callback, no module reachable from kernel/stdlib seed —
      # an empty fake lib should fall straight into strippable_libs.
      make_lib(root, "wx", "2.5", modules: ["wx_object"])

      report = OtpAudit.audit(root)
      assert "wx" in report.strippable_libs
    end
  end

  # The `:project_deps` allow-list classifier replaces the narrow
  # name-pattern heuristic when the caller can supply the project's
  # actual dep closure. Catches arbitrary leftover apps (pigeon,
  # push_notify, phase2q_lv, etc.) that don't match `test_/toy_`
  # but still aren't supposed to be in this bundle.
  describe "audit/2 — :project_deps allow-list" do
    test "an arbitrary lib NOT in project_deps is foreign", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      stranger = make_lib(root, "pigeon", "0.1.0", modules: ["Elixir.Pigeon"])

      report =
        OtpAudit.audit(root,
          app_name: :my_app,
          project_deps: [:my_app, :phoenix, :ecto]
        )

      assert stranger in report.foreign_apps
      refute "pigeon" in Enum.map(report.libs, & &1.name)
    end

    test "OTP-shipped libs are never foreign even if not in project_deps", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "xmerl", "2.2", modules: ["xmerl"])
      make_lib(root, "asn1", "5.4.3")
      make_lib(root, "compiler", "10.0")

      report =
        OtpAudit.audit(root,
          app_name: :my_app,
          project_deps: [:my_app]
        )

      assert report.foreign_apps == []
      # All four should be in libs (and so candidates for strippable_libs).
      lib_names = Enum.map(report.libs, & &1.name)
      assert "xmerl" in lib_names
      assert "asn1" in lib_names
      assert "compiler" in lib_names
    end

    test "Elixir-shipped libs are never foreign even if not in project_deps", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "elixir", "1.18.0", modules: ["Elixir.Kernel"])
      make_lib(root, "eex", "1.0", modules: ["Elixir.EEx"])
      make_lib(root, "logger", "1.18.0")

      report =
        OtpAudit.audit(root,
          app_name: :my_app,
          project_deps: [:my_app]
        )

      assert report.foreign_apps == []
    end

    test "the app under test is never foreign even if not in project_deps", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "my_app", "0.1.0", modules: ["Elixir.MyApp"])

      report =
        OtpAudit.audit(root,
          app_name: :my_app,
          # Deliberately empty — verify app_name still wins.
          project_deps: []
        )

      assert report.foreign_apps == []
    end

    test "deps listed in project_deps are kept regardless of mod-callback shape", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      # exqlite-shaped: hex dep, has app callback, runtime-only NIF.
      make_lib(root, "exqlite", "0.39.0", modules: ["Elixir.Exqlite"], mod: :exqlite_app)
      # rns-shaped: pure-Python wheel-ish, no app callback.
      make_lib(root, "rns", "0.5.0", modules: [])

      report =
        OtpAudit.audit(root,
          app_name: :my_app,
          project_deps: [:my_app, :exqlite, :rns]
        )

      assert report.foreign_apps == []
      lib_names = Enum.map(report.libs, & &1.name)
      assert "exqlite" in lib_names
      assert "rns" in lib_names
    end

    test "empty project_deps still allows OTP/Elixir shipped libs through", %{root: root} do
      # Boundary case: caller passes [] explicitly. Should NOT make
      # OTP/Elixir libs foreign (the allow-list still includes them).
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "compiler", "10.0")

      report = OtpAudit.audit(root, project_deps: [])

      assert report.foreign_apps == []
    end

    test "real-world pigeon-shaped audit: foreign cluster correctly classified", %{root: root} do
      # Recreates the shape from the ~/code/pigeon baseline audit:
      # a bundle whose cache holds leftover apps from other projects.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "elixir", "1.18.0", modules: ["Elixir.Kernel"])

      # Real deps: pigeon + exqlite.
      pigeon = make_lib(root, "pigeon", "0.1.0", modules: ["Elixir.Pigeon"])
      make_lib(root, "exqlite", "0.39.0", modules: ["Elixir.Exqlite"])

      # Leftover cache cruft from previous builds of other projects.
      stale1 = make_lib(root, "push_notify", "0.1.0", modules: ["Elixir.PushNotify"])
      stale2 = make_lib(root, "phase2q_lv", "0.1.0", modules: ["Elixir.Phase2qLv"])
      stale3 = make_lib(root, "phase2q_smoke", "0.1.0", modules: ["Elixir.Phase2qSmoke"])
      stale4 = make_lib(root, "pythonx_ios_spike", "0.1.0", modules: [])

      report =
        OtpAudit.audit(root,
          app_name: :pigeon,
          project_deps: [:pigeon, :exqlite]
        )

      # All four leftover apps land in foreign_apps.
      assert stale1 in report.foreign_apps
      assert stale2 in report.foreign_apps
      assert stale3 in report.foreign_apps
      assert stale4 in report.foreign_apps
      assert length(report.foreign_apps) == 4

      # Pigeon (the app) and exqlite (a real dep) are NOT foreign.
      lib_names = Enum.map(report.libs, & &1.name)
      assert "pigeon" in lib_names
      assert "exqlite" in lib_names
      refute pigeon in report.foreign_apps
    end

    test "without :project_deps, falls back to the name-pattern heuristic", %{root: root} do
      # Backwards-compat check: existing callers that don't pass
      # `:project_deps` get the old behaviour, which catches `toy_/test_`
      # but misses arbitrarily-named foreigners like `pigeon`.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      toy = make_lib(root, "toy_appp", "0.1.0", modules: ["Elixir.ToyAppp"])
      make_lib(root, "pigeon", "0.1.0", modules: ["Elixir.Pigeon"])

      report = OtpAudit.audit(root, app_name: :my_app)

      assert toy in report.foreign_apps
      # `pigeon` doesn't match the legacy heuristic so it slips through —
      # this is exactly the case `:project_deps` was added to fix.
      refute Enum.any?(report.foreign_apps, &String.contains?(&1, "pigeon-"))
    end

    test "erts-<vsn> is NEVER foreign — it's the BEAM runtime", %{root: root} do
      # Regression: mob's iOS bundle puts erts under lib/ alongside the
      # apps. Without explicit allow-listing the classifier sees it as
      # "not OTP-shipped, not Elixir-shipped, not the app, not in deps"
      # and quarantines the runtime as cache cruft. Reproduced from a
      # test_migration audit run that surfaced erts in foreign_apps.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      erts = make_lib(root, "erts", "17.0", modules: ["erlang"])

      report = OtpAudit.audit(root, app_name: :my_app, project_deps: [:my_app])

      assert report.foreign_apps == []
      refute erts in report.foreign_apps
      assert Enum.any?(report.libs, &(&1.name == "erts"))
    end

    test "scratch_ prefix is added to the legacy heuristic", %{root: root} do
      # `scratch_` prefix appears in the Slim foreign_apps strip pass,
      # so the audit heuristic should match it too for consistency.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      scratch = make_lib(root, "scratch_lab", "0.1.0", modules: ["Elixir.ScratchLab"])

      report = OtpAudit.audit(root, app_name: :my_app)

      assert scratch in report.foreign_apps
    end
  end

  # `:trace_input` adds empirical reachability — modules actually called
  # at runtime during a trace window. Crucially, the trace can prove a
  # statically-reachable lib is never called (the megaco/snmp case from
  # the pigeon baseline) — that's the trace-only signal that unlocks
  # stripping libs the static graph alone can't strip.
  describe "audit/2 — :trace_input" do
    test "without :trace_input, trace_strippable_libs is nil and lib reports have nil trace fields",
         %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])

      report = OtpAudit.audit(root)

      assert report.trace_strippable_libs == nil

      Enum.each(report.libs, fn lib ->
        assert lib.modules_traced == nil
        assert lib.untraced_modules == nil
      end)
    end

    test "with empty trace, every lib's modules become untraced", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "megaco", "4.9", modules: ["megaco", "megaco_app"])

      report = OtpAudit.audit(root, trace_input: MapSet.new([]))

      assert "kernel" in report.trace_strippable_libs
      assert "stdlib" in report.trace_strippable_libs
      assert "megaco" in report.trace_strippable_libs
    end

    test "trace catches a lib that's statically reachable but never called", %{root: root} do
      # Simulates the megaco case from the pigeon baseline: 1/65
      # statically reachable but 0 actually called.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      # megaco is "statically reachable" because we'll mark it called
      # — except we won't include it in the trace.
      make_lib(root, "megaco", "4.9", modules: ["megaco", "megaco_app"])

      # Trace records kernel + stdlib + Elixir runtime, NO megaco.
      trace = MapSet.new([:kernel, :lists, :erlang])

      report = OtpAudit.audit(root, trace_input: trace)

      assert "megaco" in report.trace_strippable_libs
    end

    test "trace excludes libs whose modules ARE called", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "compiler", "10.0", modules: ["compile", "beam_z"])

      # compiler.compile is in the trace → compiler not trace-strippable.
      trace = MapSet.new([:kernel, :lists, :compile])

      report = OtpAudit.audit(root, trace_input: trace)

      refute "compiler" in report.trace_strippable_libs
    end

    test "per-lib modules_traced + untraced_modules reflect trace membership", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "compiler", "10.0", modules: ["compile", "beam_z", "v3_core"])

      trace = MapSet.new([:kernel, :lists, :compile])

      report = OtpAudit.audit(root, trace_input: trace)

      compiler = Enum.find(report.libs, &(&1.name == "compiler"))
      assert compiler.modules_traced == 1
      assert compiler.untraced_modules == [:beam_z, :v3_core]
    end

    test "accepts a list as :trace_input (auto-converts to MapSet)", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "megaco", "4.9", modules: ["megaco"])

      report = OtpAudit.audit(root, trace_input: [:kernel, :lists])

      assert "megaco" in report.trace_strippable_libs
    end

    test "accepts an OtpTrace.result-shaped map (uses :modules field)", %{root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "megaco", "4.9", modules: ["megaco"])

      # Shape matches MobDev.OtpTrace.capture/1's return.
      trace_result = %{
        mfas: MapSet.new([{:kernel, :is_alive, 0}]),
        modules: MapSet.new([:kernel, :lists]),
        elapsed_us: 1234
      }

      report = OtpAudit.audit(root, trace_input: trace_result)

      assert "megaco" in report.trace_strippable_libs
    end

    test "accepts a remote-trace-shaped map (modules is a list, not MapSet)", %{root: root} do
      # `mix mob.trace_otp --remote` returns `modules` as a list. JSON
      # round-trip also flattens MapSets to lists. The normalizer
      # should handle both.
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "megaco", "4.9", modules: ["megaco"])

      remote_shape = %{
        modules: [:kernel, :lists],
        module_count: 2,
        mfa_count: 0,
        mfas: []
      }

      report = OtpAudit.audit(root, trace_input: remote_shape)

      assert "megaco" in report.trace_strippable_libs
    end

    test "an empty lib (modules_total == 0) is NOT trace-strippable", %{root: root} do
      # Defensive: a placeholder lib with no .beams should not appear
      # in trace_strippable_libs (otherwise the user gets noise from
      # cache-cruft empty dirs).
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "empty_placeholder", "0.1.0", modules: [])

      report = OtpAudit.audit(root, trace_input: [:kernel, :lists])

      refute "empty_placeholder" in report.trace_strippable_libs
    end
  end

  describe "union_trace_jsons/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mob_trace_union_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "empty list of paths returns nil" do
      assert OtpAudit.union_trace_jsons([]) == nil
    end

    test "single trace returns its modules", %{tmp: tmp} do
      path = write_trace(tmp, "one.json", ["kernel", "lists"])

      result = OtpAudit.union_trace_jsons([path])

      assert MapSet.equal?(result, MapSet.new([:kernel, :lists]))
    end

    test "multiple traces are UNIONED — modules from either count", %{tmp: tmp} do
      # Real-shaped scenario: boot capture catches kernel/sasl;
      # UI capture catches Elixir.Enum/Elixir.Map; auth capture
      # catches crypto. None of them caught megaco. The union
      # answers "what was EVER called" across all sessions.
      boot = write_trace(tmp, "boot.json", ["kernel", "sasl"])
      ui = write_trace(tmp, "ui.json", ["Elixir.Enum", "Elixir.Map"])
      auth = write_trace(tmp, "auth.json", ["crypto"])

      result = OtpAudit.union_trace_jsons([boot, ui, auth])

      assert MapSet.equal?(
               result,
               MapSet.new([:kernel, :sasl, :"Elixir.Enum", :"Elixir.Map", :crypto])
             )

      refute :megaco in result
    end

    test "duplicates across traces collapse — set semantics", %{tmp: tmp} do
      a = write_trace(tmp, "a.json", ["kernel", "lists", "Elixir.Enum"])
      b = write_trace(tmp, "b.json", ["lists", "Elixir.Enum", "Elixir.Map"])

      result = OtpAudit.union_trace_jsons([a, b])

      assert MapSet.size(result) == 4
    end

    test "missing file invokes on_read_error callback", %{tmp: tmp} do
      good = write_trace(tmp, "good.json", ["kernel"])
      missing = Path.join(tmp, "does_not_exist.json")

      parent = self()

      result =
        OtpAudit.union_trace_jsons([good, missing], fn path, _reason ->
          send(parent, {:read_error, path})
        end)

      assert_received {:read_error, ^missing}
      # The successful trace still contributes.
      assert MapSet.equal?(result, MapSet.new([:kernel]))
    end

    test "all reads failing returns nil (don't strip the world)", %{tmp: tmp} do
      missing_a = Path.join(tmp, "a.json")
      missing_b = Path.join(tmp, "b.json")

      # Custom no-op error handler keeps test output clean.
      result = OtpAudit.union_trace_jsons([missing_a, missing_b], fn _path, _reason -> nil end)

      assert result == nil, "all-failed → nil, NOT empty MapSet (would over-strip)"
    end

    test "malformed JSON triggers on_read_error, no crash", %{tmp: tmp} do
      bad = Path.join(tmp, "bad.json")
      File.write!(bad, "not actually json {{")

      result = OtpAudit.union_trace_jsons([bad], fn _path, _reason -> nil end)

      assert result == nil
    end

    test "missing :modules field treated as empty (defensive)", %{tmp: tmp} do
      noisy = Path.join(tmp, "noisy.json")
      File.write!(noisy, Jason.encode!(%{some_other_field: 1}))
      good = write_trace(tmp, "good.json", ["kernel"])

      result = OtpAudit.union_trace_jsons([noisy, good], fn _, _ -> nil end)

      assert MapSet.equal?(result, MapSet.new([:kernel]))
    end

    test "end-to-end: feeding the union into audit/2 picks trace-strippable libs",
         %{tmp: tmp, root: root} do
      make_lib(root, "kernel", "9.2", modules: ["kernel"])
      make_lib(root, "stdlib", "5.2", modules: ["lists"])
      make_lib(root, "megaco", "4.9", modules: ["megaco"])

      # No trace caught megaco → it's trace-strippable in the union.
      boot = write_trace(tmp, "boot.json", ["kernel"])
      ui = write_trace(tmp, "ui.json", ["lists"])

      union = OtpAudit.union_trace_jsons([boot, ui])
      report = OtpAudit.audit(root, trace_input: union)

      assert "megaco" in report.trace_strippable_libs
    end
  end

  defp write_trace(tmp, name, modules) do
    path = Path.join(tmp, name)

    File.write!(
      path,
      Jason.encode!(%{
        modules: modules,
        mfas: [],
        module_count: length(modules),
        mfa_count: 0
      })
    )

    path
  end
end
