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
end
