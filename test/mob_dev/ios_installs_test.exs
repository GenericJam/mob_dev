defmodule MobDev.IOSInstallsTest do
  @moduledoc """
  The registry behind MOB-70. Its only job is to answer "did we put this here",
  and the answer when it does not know must be "no".
  """
  use ExUnit.Case, async: false

  alias MobDev.IOSInstalls

  setup do
    file = Path.join(System.tmp_dir!(), "ios_installs_#{System.unique_integer([:positive])}.json")
    System.put_env("MOB_IOS_INSTALLS", file)

    on_exit(fn ->
      File.rm(file)
      System.delete_env("MOB_IOS_INSTALLS")
    end)

    {:ok, registry: file}
  end

  test "records and reads back an install" do
    :ok = IOSInstalls.record("UDID-1", "com.example.demo", "Demo")

    assert [%{bundle_id: "com.example.demo", app_name: "Demo"}] = IOSInstalls.installed("UDID-1")
  end

  test "an unknown device returns [] — callers read that as 'kill nothing'" do
    assert IOSInstalls.installed("NEVER-SEEN") == []
  end

  test "re-installing the same app does not duplicate it" do
    :ok = IOSInstalls.record("UDID-1", "com.example.demo", "Demo")
    :ok = IOSInstalls.record("UDID-1", "com.example.demo", "Demo")

    assert length(IOSInstalls.installed("UDID-1")) == 1
  end

  test "a renamed bundle replaces its entry rather than accumulating" do
    :ok = IOSInstalls.record("UDID-1", "com.example.demo", "OldName")
    :ok = IOSInstalls.record("UDID-1", "com.example.demo", "NewName")

    assert [%{app_name: "NewName"}] = IOSInstalls.installed("UDID-1")
  end

  test "devices are kept apart" do
    :ok = IOSInstalls.record("UDID-1", "com.example.one", "One")
    :ok = IOSInstalls.record("UDID-2", "com.example.two", "Two")

    assert [%{app_name: "One"}] = IOSInstalls.installed("UDID-1")
    assert [%{app_name: "Two"}] = IOSInstalls.installed("UDID-2")
  end

  test "a corrupt registry reads as empty, not as a crash", %{registry: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{ this is not json")

    assert IOSInstalls.installed("UDID-1") == []
  end

  test "an unwritable location does not take down the install that is happening" do
    # Losing the record costs a stale app surviving a later launch. It must
    # never cost the deploy in progress.
    System.put_env("MOB_IOS_INSTALLS", "/proc/nonexistent/nope.json")

    assert IOSInstalls.record("UDID-1", "com.example.demo", "Demo") == :ok
  end

  describe "forgetting" do
    test "an uninstalled app stops being killable" do
      # Matching is by app NAME, so a stale entry is not inert: it stays
      # killable for ever and a third-party app that later takes that name
      # inherits it.
      :ok = IOSInstalls.record("UDID-1", "com.example.demo", "Demo")
      :ok = IOSInstalls.forget("UDID-1", "com.example.demo")

      assert IOSInstalls.installed("UDID-1") == []
    end

    test "forgetting one app leaves the others" do
      :ok = IOSInstalls.record("UDID-1", "com.example.one", "One")
      :ok = IOSInstalls.record("UDID-1", "com.example.two", "Two")
      :ok = IOSInstalls.forget("UDID-1", "com.example.one")

      assert [%{app_name: "Two"}] = IOSInstalls.installed("UDID-1")
    end

    test "forgetting something unknown is not an error" do
      assert IOSInstalls.forget("NEVER-SEEN", "com.example.demo") == :ok
    end
  end

  describe "malformed registries" do
    test "shape-wrong but valid JSON reads as empty rather than raising", %{registry: file} do
      # Map.get/3 will happily hand back a binary, which Enum.flat_map/2 then
      # raises on. Syntactic validity is not the same as usable shape.
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, ~s({"UDID-1":"oops"}))

      assert IOSInstalls.installed("UDID-1") == []
    end

    test "a JSON array instead of an object reads as empty", %{registry: file} do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, ~s(["not a map"]))

      assert IOSInstalls.installed("UDID-1") == []
    end
  end
end
