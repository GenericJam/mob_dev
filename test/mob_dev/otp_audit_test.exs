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
end
