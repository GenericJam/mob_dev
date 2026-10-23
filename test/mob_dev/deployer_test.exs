defmodule MobDev.DeployerTest do
  use ExUnit.Case, async: true

  alias MobDev.{Deployer, Device}

  describe "frozen targets" do
    test "an explicit device snapshot bypasses discovery and excludes unrelated devices" do
      selected = %Device{platform: :android, serial: "emulator-5554", type: :emulator}

      fail_if_called = fn -> flunk("device discovery must not run after targets are frozen") end

      assert Deployer.target_devices(
               [devices: [selected], android_lister: fail_if_called, ios_lister: fail_if_called],
               [:android, :ios]
             ) == [selected]
    end
  end

  describe "physical iOS override" do
    test "app-not-installed skips carry no partial-upload note" do
      Process.put(:mob_ios_code_upload, {:legacy, "Documents/otp/sample_app"})
      on_exit(fn -> Process.delete(:mob_ios_code_upload) end)

      assert {:skipped, "App is not installed"} =
               Deployer.finalize_ios_override_result(
                 {:skipped, "App is not installed"},
                 "sample_app"
               )
    end

    test "an error before the upload began is reported as is" do
      Process.delete(:mob_ios_code_upload)

      assert {:error, "listing failed"} =
               Deployer.finalize_ios_override_result({:error, "listing failed"}, "sample_app")
    end

    test "an error after the upload began says which directory it left behind" do
      dir = "Documents/otp/sample_app.versions/0000000007"
      Process.put(:mob_ios_code_upload, {{:versioned, "0000000007"}, dir})
      on_exit(fn -> Process.delete(:mob_ios_code_upload) end)

      assert {:error, message} =
               Deployer.finalize_ios_override_result({:error, "copy failed"}, "sample_app")

      assert String.starts_with?(message, "copy failed")
      assert message =~ dir

      Process.put(:mob_ios_code_upload, {:legacy, "Documents/otp/sample_app"})

      assert {:error, message} =
               Deployer.finalize_ios_override_result({:error, "copy failed"}, "sample_app")

      assert String.starts_with?(message, "copy failed")
      assert message =~ "Documents/otp/sample_app"
    end

    test "requires staged bootstrap bytes to match the active compile output" do
      root = Path.join(System.tmp_dir!(), "mob_ios_override_#{System.unique_integer()}")
      compile_path = Path.join(root, "compile")
      staging_dir = Path.join(root, "staging")
      File.mkdir_p!(compile_path)
      File.mkdir_p!(staging_dir)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "active Mix compile output"
      assert message =~ Path.join(compile_path, "sample_app.beam")

      File.write!(Path.join(compile_path, "sample_app.beam"), "current bootstrap")

      # Staged file ABSENT is a different fault from staged file DIFFERENT, and
      # must say so — wrapping the enoent in "does not match active compile
      # output" sent the reader to the wrong file.
      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "missing the application bootstrap"
      assert message =~ "sample_app.beam"
      refute message =~ "does not match active compile output"

      File.write!(Path.join(staging_dir, "sample_app.beam"), "stale dependency bootstrap")

      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "does not match active compile output"
      assert message =~ "verification mismatch"

      File.write!(Path.join(staging_dir, "sample_app.beam"), "current bootstrap")

      assert :ok =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")
    end

    # MOB-408: --remove-existing-content empties the app's whole data
    # container (Documents, Library, tmp), whatever --destination names.
    test "the copy merges into its destination and never removes existing content" do
      args = Deployer.ios_code_copy_args("device-id", "com.example.app", "/tmp/app", "dest/dir")

      assert args == [
               "devicectl",
               "device",
               "copy",
               "to",
               "--device",
               "device-id",
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               "com.example.app",
               "--source",
               "/tmp/app",
               "--destination",
               "dest/dir"
             ]
    end

    # What every mob runtime since 0.6.2 writes to Documents/mob_diag_beams_dir.txt
    # at boot: the absolute path of the directory it loads.
    test "the deploy is confirmed only when the app booted from the directory it wrote" do
      container = "/var/mobile/Containers/Data/Application/9F50A0EA"
      versioned = "Documents/otp/app.versions/0000000008"

      assert Deployer.ios_loaded?("#{container}/#{versioned}\n", versioned)
      assert Deployer.ios_loaded?("#{container}/Documents/otp/app\n", "Documents/otp/app")

      # An older committed version, the legacy override, or the bundle.
      refute Deployer.ios_loaded?("#{container}/Documents/otp/app.versions/0000000007", versioned)
      refute Deployer.ios_loaded?("#{container}/Documents/otp/app\n", versioned)
      refute Deployer.ios_loaded?("#{container}/#{versioned}\n", "Documents/otp/app")
      refute Deployer.ios_loaded?("/private/var/containers/Bundle/D.app/otp/app", versioned)
      # Another app whose name ends in this one's.
      refute Deployer.ios_loaded?("#{container}/Documents/otp/myapp\n", "Documents/otp/app")
      # No diagnostic yet.
      refute Deployer.ios_loaded?(nil, versioned)
      refute Deployer.ios_loaded?("", versioned)
    end

    test "a versioned deploy goes above every existing entry, committed or not" do
      # An interrupted upload (no marker) still takes its number: reusing it
      # would merge into its leftovers.
      assert {:versioned, "0000000004"} =
               Deployer.ios_code_plan(
                 true,
                 {:ok, ["0000000001", "0000000003", "notes", "0000000002", "12x"]}
               )

      assert {:versioned, "0000000001"} = Deployer.ios_code_plan(true, {:ok, []})
      assert {:versioned, "0000000010"} = Deployer.ios_code_plan(true, {:ok, ["9"]})
    end

    test "versioned only when both the project's mob and the phone's runtime read it" do
      # The phone never created <app>.versions/: its runtime predates the
      # layout (mob updated without --native), or hasn't booted yet.
      assert :legacy = Deployer.ios_code_plan(true, :absent)
      # The project's mob predates it: the runtime about to run is old even if
      # the phone kept <app>.versions/ from a newer one.
      assert :legacy = Deployer.ios_code_plan(false, {:ok, ["0000000001"]})
      assert :legacy = Deployer.ios_code_plan(false, :absent)
    end

    test "each plan uploads into its own directory" do
      assert Deployer.ios_code_dir("app", {:versioned, "0000000002"}) ==
               "Documents/otp/app.versions/0000000002"

      assert Deployer.ios_code_dir("app", :legacy) == "Documents/otp/app"
    end

    test "the project's mob reads <app>.versions/ when it ships the runtime header" do
      dir = Path.join(System.tmp_dir!(), "mob_dep_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "ios"))
      on_exit(fn -> File.rm_rf!(dir) end)

      refute Deployer.mob_reads_ios_versions?(dir)
      File.write!(Path.join(dir, "ios/mob_code_versions.h"), "")
      assert Deployer.mob_reads_ios_versions?(dir)
      refute Deployer.mob_reads_ios_versions?(nil)
    end

    test "the listing lists <app>.versions/ itself, one level, as JSON to a file" do
      args = Deployer.ios_versions_list_args("device-id", "com.example.app", "app", "/tmp/l.json")

      assert ["devicectl", "device", "info", "files" | _] = args

      assert ["--subdirectory", "Documents/otp/app.versions" | _] =
               drop_until(args, "--subdirectory")

      assert "--no-recurse" in args
      assert ["--json-output", "/tmp/l.json" | _] = drop_until(args, "--json-output")

      assert ["--domain-identifier", "com.example.app" | _] =
               drop_until(args, "--domain-identifier")
    end

    # Shapes captured from devicectl 642.16 against an iPhone (MOB-408).
    test "a listing yields the directory's entry names" do
      json = ~s({"info": {"outcome": "success"}, "result": {"files": [
        {"name": "0000000001", "relativePath": "0000000001",
         "resources": {"isDirectory": true}},
        {"name": ".mob_complete", "relativePath": "0000000001/.mob_complete",
         "resources": {"isDirectory": false}},
        {"name": "0000000002", "relativePath": "0000000002",
         "resources": {"isDirectory": true}}]}})

      assert {:ok, ["0000000001", "0000000002"]} = Deployer.parse_ios_versions_listing(json)
      assert {:ok, []} = Deployer.parse_ios_versions_listing(~s({"result": {"files": []}}))
    end

    test "a directory devicectl can't list is absent; other failures are errors" do
      # What a missing <app>.versions/ (and an app that isn't installed) gives.
      missing = ~s({"error": {"code": 3, "domain": "CoreDevice.ActionError", "userInfo": {
        "NSDebugDescription": {"string": "The system failed to get a list of files"}}},
        "info": {"outcome": "failed"}})

      assert :absent = Deployer.parse_ios_versions_listing(missing)

      no_device = ~s({"error": {"code": 1000, "domain": "com.apple.dt.CoreDeviceError",
        "userInfo": {"NSLocalizedDescription": {"string": "The specified device was not found."}}},
        "info": {"outcome": "failed"}})

      assert {:error, message} = Deployer.parse_ios_versions_listing(no_device)
      assert message =~ "The specified device was not found."

      assert {:error, _} = Deployer.parse_ios_versions_listing("ERROR: not json")
    end

    test "verification reads back the bootstrap from the directory just written" do
      assert Deployer.ios_code_verify_args(
               "device-id",
               "com.example.app",
               "Documents/otp/app.versions/0000000002",
               "app",
               "/tmp/received.beam"
             ) == [
               "devicectl",
               "device",
               "copy",
               "from",
               "--device",
               "device-id",
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               "com.example.app",
               "--source",
               "Documents/otp/app.versions/0000000002/app.beam",
               "--destination",
               "/tmp/received.beam"
             ]
    end

    test "remote bootstrap must match staged bytes" do
      dir = Path.join(System.tmp_dir!(), "mob_ios_verify_#{System.unique_integer()}")
      staged = Path.join(dir, "staged.beam")
      received = Path.join(dir, "received.beam")
      File.mkdir_p!(dir)
      File.write!(staged, "same beam")
      File.write!(received, "same beam")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Deployer.verify_ios_bootstrap(staged, received)

      File.write!(received, "different beam")

      assert {:error, "physical iOS bootstrap verification mismatch"} =
               Deployer.verify_ios_bootstrap(staged, received)

      File.rm!(received)

      assert {:error, "physical iOS bootstrap verification failed: enoent"} =
               Deployer.verify_ios_bootstrap(staged, received)
    end
  end

  # ── categorize_results/1 ────────────────────────────────────────────────

  describe "categorize_results/1" do
    # Use minimal Device structs (just the fields the function reads, plus
    # the ones the production code threads through for display).
    defp device(name), do: %MobDev.Device{name: name, serial: name, platform: :android}

    test "buckets :ok results as deployed" do
      a = device("a")
      b = device("b")

      assert {[^a, ^b], [], []} = Deployer.categorize_results([{:ok, a}, {:ok, b}])
    end

    test "buckets :error results as failed" do
      a = device("a")

      assert {[], [^a], []} = Deployer.categorize_results([{:error, a}])
    end

    test "buckets :skipped results as skipped" do
      a = device("a")

      assert {[], [], [^a]} = Deployer.categorize_results([{:skipped, a}])
    end

    test "skipped does NOT leak into failed (regression pin)" do
      # The original behaviour returned `:error` for app-not-installed,
      # so the count of "failed" devices included multi-platform sweep
      # skips. categorize_results pins the three-way split.
      deployed = device("deployed")
      stale = device("stale_lock_skipped")
      busted = device("real_failure")

      assert {[^deployed], [^busted], [^stale]} =
               Deployer.categorize_results([
                 {:ok, deployed},
                 {:skipped, stale},
                 {:error, busted}
               ])
    end

    test "empty input returns three empty lists" do
      assert {[], [], []} = Deployer.categorize_results([])
    end

    test "mixed real-world shape — iOS deploy + 5 Android skips" do
      iphone = device("iPhone")
      androids = for i <- 1..5, do: device("emulator-#{i}")

      results = [{:ok, iphone} | Enum.map(androids, &{:skipped, &1})]

      {deployed, failed, skipped} = Deployer.categorize_results(results)
      assert deployed == [iphone]
      assert failed == []
      assert [_, _, _, _, _] = skipped
    end
  end

  # ── android_package_installed?/2 ────────────────────────────────────────

  describe "android_package_installed?/2" do
    test "true when pm output contains the package line" do
      pm_out = "package:com.example.test_migration\n"
      assert Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "false when pm output is empty (no matching package)" do
      # Adb's `pm list packages <pkg>` returns empty output when there's
      # no match — NOT a 'package:' line with empty body.
      refute Deployer.android_package_installed?("", "com.example.test_migration")
    end

    test "false when pm output lists a DIFFERENT package" do
      pm_out = "package:com.example.different_app\n"
      refute Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "true when pm output has the target package among others" do
      pm_out = """
      package:com.example.test_migration
      package:com.example.different_app
      """

      assert Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "false on partial match without 'package:' prefix" do
      # Defensive: substring match must require the 'package:' prefix so
      # output like "com.example.test_migration is your app" doesn't
      # falsely register as installed.
      pm_out = "com.example.test_migration unrelated text\n"
      refute Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end
  end

  describe "__sqlite_nif_target__/1 (exqlite NIF symlink target, ABI-aware)" do
    test "picks the 64-bit lib on an arm64 device" do
      lines = ["/data/app/com.example.app-hash==/lib/arm64/libsqlite3_nif.so"]
      assert Deployer.__sqlite_nif_target__(lines) =~ "/lib/arm64/libsqlite3_nif.so"
    end

    test "picks the 32-bit lib on an armeabi-v7a device (the bug: was hardcoded arm64)" do
      # Android extracts only the active ABI, so a 32-bit phone has lib/arm —
      # hardcoding lib/arm64 produced a dangling symlink and crashed boot.
      lines = ["/data/app/com.example.app-hash==/lib/arm/libsqlite3_nif.so"]
      assert Deployer.__sqlite_nif_target__(lines) == hd(lines)
    end

    test "nil when the glob matched nothing (ls returned no real path)" do
      assert Deployer.__sqlite_nif_target__([]) == nil
    end

    test "ignores trailing whitespace and unrelated lines" do
      lines = ["  /data/app/x/lib/arm/libsqlite3_nif.so  ", "ls: bad: No such file"]
      assert Deployer.__sqlite_nif_target__(lines) == "/data/app/x/lib/arm/libsqlite3_nif.so"
    end
  end

  # MOB-183: non-native mob.deploy used to report success on a device
  # whose per-app OTP release directory was missing; the app then
  # boot-crashed with "cannot get bootfile". The old check only verified
  # ERTS binaries — this classifier verifies both ERTS and the release
  # bootfile, and distinguishes the failure modes.
  describe "classify_android_runtime_ls/3" do
    @erts_glob "/data/data/com.example.demo/files/otp/erts-*/bin/erl_child_setup"
    @boot_glob "/data/data/com.example.demo/files/otp/releases/*/start_clean.boot"

    test "ok when both erts and bootfile exist" do
      out = """
      /data/data/com.example.demo/files/otp/erts-14.2.5/bin/erl_child_setup
      /data/data/com.example.demo/files/otp/releases/29/start_clean.boot
      """

      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) == :ok
    end

    test "run_as failure surfaces before glob checks" do
      out = "run-as: unknown package: com.example.demo"

      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :run_as_unavailable}
    end

    test "erts missing when erts glob has no match" do
      out = """
      ls: #{@erts_glob}: No such file or directory
      ls: #{@boot_glob}: No such file or directory
      """

      # Both missing prefers the ERTS tag — provisioning ERTS is the
      # first thing --native does; there is no way to have the bootfile
      # without ERTS in a real deploy, so reporting bootfile first would
      # send the reader chasing the wrong file.
      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :erts_missing}
    end

    test "bootfile missing when only the boot glob has no match — MOB-183" do
      out = """
      /data/data/com.example.demo/files/otp/erts-14.2.5/bin/erl_child_setup
      ls: #{@boot_glob}: No such file or directory
      """

      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :bootfile_missing}
    end

    test "recognises the Toybox 'not found' variant of the missing-file message" do
      # Some Android userland (Toybox `ls`) says "<path>: not found" rather
      # than "ls: <path>: No such file or directory". The classifier must
      # match either shape or the check silently passes on that userland.
      out = "#{@erts_glob}: not found"

      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :erts_missing}
    end

    test "recognises the GNU coreutils 'cannot access' variant" do
      out = "ls: cannot access '#{@boot_glob}': No such file or directory"

      # This message doesn't contain the "ls: <glob>: No such file" prefix
      # the primary branch looks for, so a naive substring on "No such file"
      # would misfire between erts and bootfile in the both-missing case.
      # Anchoring on the specific glob is the point of the classifier.
      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :bootfile_missing}
    end

    # The pre-review revision of the fix fell through to `:ok` whenever
    # `run_adb` returned `{:error, out}` — which is exactly the arm that
    # fires on the MOB-183 failure mode, because modern adb-shell (v2,
    # default since Android 7) forwards the inner shell's non-zero exit as
    # the session's own exit. `ensure_erts_on_device` now feeds `out` into
    # the classifier regardless of the adb-shell status, so a real
    # partial-runtime device reaches this classifier — the pathway must
    # produce a verdict, not a silent pass. These fixtures are the exact
    # `ls: ... No such file` strings adb-shell hands back on that arm.
    test "MOB-183 regression: classifier fires on adb-shell error output" do
      out = """
      /data/data/com.example.demo/files/otp/erts-14.2.5/bin/erl_child_setup
      ls: #{@boot_glob}: No such file or directory
      """

      assert Deployer.classify_android_runtime_ls(out, @erts_glob, @boot_glob) ==
               {:error, :bootfile_missing}
    end

    test "empty output passes through as ok (adb transport failure fallback)" do
      # A true adb transport failure (device disappeared, offline race) has
      # no output to classify. Best-effort: let the deploy proceed and let
      # the actual push failure surface the real problem.
      assert Deployer.classify_android_runtime_ls("", @erts_glob, @boot_glob) == :ok
      assert Deployer.classify_android_runtime_ls(nil, @erts_glob, @boot_glob) == :ok
    end
  end

  describe "prune_other_versions_cmd/2" do
    # Runs the generated command with the host's sh against a fake OTP lib/,
    # which is what the device's shell does with it.
    @tag :tmp_dir
    test "removes every other version of the app and nothing else", %{tmp_dir: dir} do
      lib = Path.join(dir, "otp/lib")

      for d <-
            ~w(exqlite-0.36.0 exqlite-0.41.0 exqlite-0.42.0-rc.1 ecto_sqlite3-0.25.0 exqlitex-1.0),
          do: File.mkdir_p!(Path.join([lib, d, "priv"]))

      keep = Path.join(lib, "exqlite-0.41.0")
      {_, 0} = System.cmd("sh", ["-c", Deployer.prune_other_versions_cmd(keep, "exqlite")])

      assert lib |> File.ls!() |> Enum.sort() ==
               ~w(ecto_sqlite3-0.25.0 exqlite-0.41.0 exqlitex-1.0)
    end

    @tag :tmp_dir
    test "is a no-op when only the installed version is present", %{tmp_dir: dir} do
      keep = Path.join(dir, "otp/lib/exqlite-0.41.0")
      File.mkdir_p!(keep)
      {_, 0} = System.cmd("sh", ["-c", Deployer.prune_other_versions_cmd(keep, "exqlite")])
      assert File.dir?(keep)
    end
  end

  describe "stale_host_ssl_rm_cmd/2" do
    # Runs the generated command with the host's sh against a beams dir that
    # holds what a pre-MOB-493 deploy left: the app's BEAMs plus host ssl.
    @tag :tmp_dir
    test "removes the host ssl and crypto shim files and keeps the app files", %{tmp_dir: dir} do
      ssl = Deployer.stale_host_ssl_files()
      assert "ssl.app" in ssl
      assert "ssl.beam" in ssl
      assert "crypto.beam" in ssl

      app_files = ~w(my_app.app my_app.beam Elixir.MyApp.beam mob_beam_flags)
      for f <- ssl ++ app_files, do: File.write!(Path.join(dir, f), "")

      {_, 0} = System.cmd("sh", ["-c", Deployer.stale_host_ssl_rm_cmd(dir)])

      assert Enum.sort(File.ls!(dir)) == Enum.sort(app_files)
    end

    test "is nil when there is nothing to remove" do
      assert Deployer.stale_host_ssl_rm_cmd("/x", []) == nil
    end
  end

  # MOB-49: hot loading the new mob into an app whose Mob.Dist started on the
  # public cookie leaves that cookie and its all-interface listener in place.
  describe "hot_load_nodes/1" do
    test "an app on the legacy cookie is restarted, not hot-loaded" do
      android = %Device{platform: :android, type: :emulator, serial: "emulator-5554"}
      sim = %Device{platform: :ios, type: :simulator, serial: "SIM"}

      connected = [
        {android, :"a_android@127.0.0.1", :private},
        {android, :"b_android@127.0.0.1", :mob_secret},
        {sim, :"c_ios@127.0.0.1", :mob_secret}
      ]

      assert Deployer.hot_load_nodes(connected) == [:"a_android@127.0.0.1"]
    end

    # Its filesystem write is unsafe from the dist path, and only --native
    # moves its launcher to the private cookie.
    test "a physical iPhone on the legacy cookie still hot-loads" do
      phone = %Device{platform: :ios, type: :physical, serial: "UDID"}

      assert Deployer.hot_load_nodes([{phone, :"a_ios@10.0.0.2", :mob_secret}]) == [
               :"a_ios@10.0.0.2"
             ]
    end
  end

  defp drop_until(list, item), do: Enum.drop_while(list, &(&1 != item))
end
