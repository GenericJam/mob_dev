defmodule MobDev.BatteryBenchTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.BatteryBenchIos, as: IOS
  alias Mix.Tasks.Mob.BatteryBenchAndroid, as: Android

  # Both tasks share identical describe_mode/1 and resolve_build_flags/1 logic.
  # Tests run against both modules to catch divergence.

  for mod <- [IOS, Android] do
    describe "#{mod}.describe_mode/1" do
      test "default (no opts)" do
        assert unquote(mod).describe_mode([]) == "default (Nerves tuning)"
      end

      test "--no-beam" do
        assert unquote(mod).describe_mode(no_beam: true) == "no-beam (baseline)"
      end

      test "--flags" do
        assert unquote(mod).describe_mode(flags: "-sbwt none") == "custom flags: -sbwt none"
      end

      test "--preset untuned" do
        assert unquote(mod).describe_mode(preset: "untuned") == "preset: untuned"
      end

      test "--preset nerves" do
        assert unquote(mod).describe_mode(preset: "nerves") == "preset: nerves"
      end

      test "--preset sbwt" do
        assert unquote(mod).describe_mode(preset: "sbwt") == "preset: sbwt"
      end
    end

    describe "#{mod}.resolve_build_flags/1" do
      test "default returns empty cflags, no temp dir" do
        assert {cflags, nil} = unquote(mod).resolve_build_flags([])
        assert cflags == ""
      end

      test "--no-beam returns -DNO_BEAM" do
        assert {"-DNO_BEAM", nil} = unquote(mod).resolve_build_flags(no_beam: true)
      end

      test "--preset untuned" do
        assert {"-DBEAM_UNTUNED", nil} = unquote(mod).resolve_build_flags(preset: "untuned")
      end

      test "--preset sbwt" do
        assert {"-DBEAM_SBWT_ONLY", nil} = unquote(mod).resolve_build_flags(preset: "sbwt")
      end

      test "--preset nerves" do
        assert {"-DBEAM_FULL_NERVES", nil} = unquote(mod).resolve_build_flags(preset: "nerves")
      end

      test "--preset unknown raises" do
        assert_raise Mix.Error, ~r/Unknown preset/, fn ->
          unquote(mod).resolve_build_flags(preset: "turbo")
        end
      end

      test "--flags writes a temp header and returns -DBEAM_USE_CUSTOM_FLAGS" do
        {cflags, header_dir} = unquote(mod).resolve_build_flags(flags: "-sbwt none -S 1:1")

        assert cflags =~ "-DBEAM_USE_CUSTOM_FLAGS"
        assert is_binary(header_dir)
        assert File.dir?(header_dir)

        header = File.read!(Path.join(header_dir, "mob_beam_flags.h"))
        assert header =~ ~s("-sbwt")
        assert header =~ ~s("none")
        assert header =~ ~s("-S")
        assert header =~ ~s("1:1")

        File.rm_rf!(header_dir)
      end

      test "--flags single token" do
        {cflags, header_dir} = unquote(mod).resolve_build_flags(flags: "-sbwt none")
        assert cflags =~ "-DBEAM_USE_CUSTOM_FLAGS"
        File.rm_rf!(header_dir)
      end
    end
  end

  describe "iOS option parsing" do
    test "parses all supported switches" do
      {opts, _, _} =
        OptionParser.parse(
          ~w[--duration 3600 --device ABC-123 --no-beam --preset nerves
           --flags -sbwt\ none --no-build --scheme MyApp --dry-run],
          switches: [
            duration: :integer,
            device: :string,
            no_beam: :boolean,
            preset: :string,
            flags: :string,
            no_build: :boolean,
            scheme: :string,
            dry_run: :boolean
          ]
        )

      assert opts[:duration] == 3600
      assert opts[:device] == "ABC-123"
      assert opts[:no_beam] == true
      assert opts[:preset] == "nerves"
      assert opts[:no_build] == true
      assert opts[:scheme] == "MyApp"
      assert opts[:dry_run] == true
    end
  end

  describe "Android option parsing" do
    test "parses all supported switches" do
      {opts, _, _} =
        OptionParser.parse(
          ~w[--duration 600 --device 192.168.1.5:5555 --no-beam --no-build --dry-run],
          switches: [
            duration: :integer,
            device: :string,
            no_beam: :boolean,
            preset: :string,
            flags: :string,
            no_build: :boolean,
            dry_run: :boolean
          ]
        )

      assert opts[:duration] == 600
      assert opts[:device] == "192.168.1.5:5555"
      assert opts[:no_beam] == true
      assert opts[:no_build] == true
      assert opts[:dry_run] == true
    end
  end
end
