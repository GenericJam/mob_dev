defmodule MobDev.HotPushTest do
  use ExUnit.Case, async: true

  alias MobDev.HotPush

  describe "select_runtime_beam_paths/4" do
    test "uses only active app beams when the build path has stale app output" do
      root = Path.join(System.tmp_dir!(), "mob_[edge]_paths_#{System.unique_integer()}")
      build_path = Path.join(root, "active-build")
      app_ebin = Path.join(root, "application-ebin")
      File.mkdir_p!(app_ebin)

      erlang_bootstrap = Path.join(app_ebin, "sample_app.beam")
      elixir_module = Path.join(app_ebin, "Elixir.SampleApp.beam")
      File.write!(erlang_bootstrap, "erlang")
      File.write!(elixir_module, "elixir")
      File.write!(Path.join(app_ebin, "sample_app.app"), "app metadata")

      stale_app_ebin = Path.join([build_path, "lib", "sample_app", "ebin"])
      File.mkdir_p!(stale_app_ebin)
      stale_bootstrap = Path.join(stale_app_ebin, "sample_app.beam")
      removed_module = Path.join(stale_app_ebin, "Elixir.RemovedModule.beam")
      File.write!(stale_bootstrap, "stale erlang")
      File.write!(removed_module, "removed")

      runtime_ebin = Path.join([build_path, "lib", "runtime_dep", "ebin"])
      File.mkdir_p!(runtime_ebin)
      runtime_module = Path.join(runtime_ebin, "Elixir.RuntimeDep.beam")
      File.write!(runtime_module, "runtime")

      dev_ebin = Path.join([build_path, "lib", "dev_tool", "ebin"])
      File.mkdir_p!(dev_ebin)
      File.write!(Path.join(dev_ebin, "Elixir.DevTool.beam"), "dev")

      on_exit(fn -> File.rm_rf!(root) end)

      runtime = MapSet.new(["sample_app", "runtime_dep"])

      selected =
        HotPush.select_runtime_beam_paths(build_path, app_ebin, runtime, "sample_app")

      assert selected == [
               runtime_module,
               elixir_module,
               erlang_bootstrap
             ]

      refute stale_bootstrap in selected
      refute removed_module in selected
    end
  end

  describe "select_runtime_beam_dirs/4" do
    test "selects the active application ebin and excludes stale build output" do
      root = Path.join(System.tmp_dir!(), "mob_[edge]_dirs_#{System.unique_integer()}")
      build_path = Path.join(root, "active-build")
      app_ebin = Path.join(root, "application-ebin")
      File.mkdir_p!(app_ebin)
      File.write!(Path.join(app_ebin, "sample_app.beam"), "erlang")
      File.write!(Path.join(app_ebin, "Elixir.SampleApp.beam"), "elixir")

      stale_app_ebin = Path.join([build_path, "lib", "sample_app", "ebin"])
      File.mkdir_p!(stale_app_ebin)
      File.write!(Path.join(stale_app_ebin, "sample_app.beam"), "stale erlang")
      File.write!(Path.join(stale_app_ebin, "Elixir.RemovedModule.beam"), "removed")

      dep_ebin = Path.join([build_path, "lib", "runtime_dep", "ebin"])
      File.mkdir_p!(dep_ebin)
      File.write!(Path.join(dep_ebin, "Elixir.RuntimeDep.beam"), "dep")

      dev_ebin = Path.join([build_path, "lib", "dev_tool", "ebin"])
      File.mkdir_p!(dev_ebin)
      File.write!(Path.join(dev_ebin, "Elixir.DevTool.beam"), "dev")

      on_exit(fn -> File.rm_rf!(root) end)

      dirs =
        HotPush.select_runtime_beam_dirs(
          build_path,
          app_ebin,
          MapSet.new(["sample_app", "runtime_dep"]),
          "sample_app"
        )

      assert dirs == [dep_ebin, app_ebin]
      refute dev_ebin in dirs
      refute stale_app_ebin in dirs

      staged_names =
        dirs
        |> Enum.flat_map(&File.ls!/1)
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 "sample_app.beam",
                 "Elixir.SampleApp.beam",
                 "Elixir.RuntimeDep.beam"
               ]),
               staged_names
             )
    end
  end

  # ── snapshot_beams/0 ─────────────────────────────────────────────────────────

  describe "snapshot_beams/0" do
    test "returns a non-empty map" do
      assert map_size(HotPush.snapshot_beams()) > 0
    end

    test "all keys are .beam paths" do
      HotPush.snapshot_beams()
      |> Map.keys()
      |> Enum.each(fn path -> assert String.ends_with?(path, ".beam") end)
    end

    test "all values are integer mtimes" do
      HotPush.snapshot_beams()
      |> Map.values()
      |> Enum.each(fn mtime -> assert is_integer(mtime) end)
    end
  end

  # ── push_changed/2 ───────────────────────────────────────────────────────────

  describe "push_changed/2" do
    test "returns {0, []} when nothing changed since snapshot" do
      snapshot = HotPush.snapshot_beams()
      # Snapshot taken, no compile ran — nothing should differ.
      assert {0, []} = HotPush.push_changed([], snapshot)
    end

    test "detects beam files not in snapshot (empty snapshot)" do
      # Empty snapshot means every runtime beam is "new".
      # push_changed only counts runtime deps — not dev-only deps like mob_dev itself.
      {pushed, failed} = HotPush.push_changed([], %{})
      assert failed == []
      assert pushed > 0
    end

    test "does not push files that haven't changed" do
      snapshot = HotPush.snapshot_beams()
      # Immediately re-check — mtimes are identical, so nothing should be pushed.
      {pushed, _} = HotPush.push_changed([], snapshot)
      assert pushed == 0
    end

    test "returns ok with no nodes (no RPC attempted)" do
      snapshot = HotPush.snapshot_beams()
      # Even with an empty node list, must not raise.
      assert {_pushed, _failed} = HotPush.push_changed([], snapshot)
    end
  end

  # ── push_all/1 ───────────────────────────────────────────────────────────────

  describe "push_all/1" do
    test "returns {count, []} with no nodes" do
      {pushed, failed} = HotPush.push_all([])
      assert is_integer(pushed)
      assert failed == []
    end

    test "push count is less than total beam files in _build" do
      # push_all only pushes runtime deps — dev-only deps (mob_dev itself, Bandit,
      # Phoenix, etc.) must be excluded even though their BEAMs are in the build path.
      total_beams =
        Mix.Project.build_path()
        |> Path.join("lib")
        |> File.ls!()
        |> Enum.map(&Path.join([Mix.Project.build_path(), "lib", &1, "ebin"]))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&File.ls!/1)
        |> Enum.count(&String.ends_with?(&1, ".beam"))

      {pushed, _} = HotPush.push_all([])
      assert pushed > 0
      assert pushed < total_beams
    end
  end

  describe "runtime_lib_names/0 (drives what actually gets pushed)" do
    # This is the function that decides the push set, and until now it had no
    # coverage: every other test hand-builds the MapSet it produces, so a
    # regression inside it stayed green. Driven here against mob_dev's own
    # project, which has both real runtime deps and only: :dev ones.
    test "keeps runtime deps and excludes dev-only ones" do
      libs = MobDev.HotPush.__runtime_lib_names__()

      assert MapSet.member?(libs, "mob_dev")

      for dev_only <- ["credo", "ex_slop", "mix_audit", "ex_doc"] do
        refute MapSet.member?(libs, dev_only),
               "#{dev_only} is only: :dev and must not be pushed to a device"
      end
    end

    test "traverses the project's own .app so extra_applications survive" do
      # The regression this guards: dropping project_app from the expansion
      # seed stops the project's .app being read at all, so a dependency
      # reachable only via `runtime: false` + `extra_applications:` — the
      # documented idiom for opting a build-time dep back into the runtime
      # application list — is silently never pushed. The app then boots and
      # dies with undef on first use.
      libs = MobDev.HotPush.__runtime_lib_names__()

      extra =
        Mix.Project.get().application()
        |> Keyword.get(:extra_applications, [])
        |> Enum.map(&to_string/1)

      for app <- extra do
        assert MapSet.member?(libs, app),
               "#{app} is in extra_applications and must survive the runtime filter"
      end
    end
  end
end
