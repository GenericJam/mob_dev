defmodule MobDev.AppLifecycleHooksTest do
  use ExUnit.Case, async: true

  alias MobDev.AppLifecycleHooks

  @moduletag :tmp_dir

  @main_activity "android/app/src/main/java/com/example/my_app/MainActivity.kt"
  @beam_jni "android/app/src/main/jni/beam_jni.c"

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp mob(root, header) do
    mob_dir = Path.join(root, "mob")
    write(mob_dir, "android/jni/mob_beam.h", header)
    mob_dir
  end

  defp app(root, main_activity, beam_jni) do
    project = Path.join(root, "app")
    write(project, @main_activity, main_activity)
    write(project, @beam_jni, beam_jni)
    project
  end

  @new_mob "void mob_send_app_lifecycle(const char *event);\n"
  @old_mob "void mob_send_orientation(const char *o);\n"
  @old_activity "class MainActivity : ComponentActivity() {\n  external fun nativeNotifyOrientation(o: String)\n}\n"
  @new_activity "class MainActivity {\n  external fun nativeNotifyAppLifecycle(event: String)\n}\n"
  @old_jni "Java_com_example_my_1app_MainActivity_nativeNotifyOrientation(...) {}\n"
  @new_jni @old_jni <> "void f() { mob_send_app_lifecycle(utf8); }\n"

  test "an app generated before the hooks, on a mob that exports them, is missing both halves",
       %{tmp_dir: dir} do
    project = app(dir, @old_activity, @old_jni)

    assert AppLifecycleHooks.check(project, mob(dir, @new_mob)) ==
             {:missing, [@main_activity, @beam_jni]}
  end

  test "a half-ported app names only the file still missing its hook", %{tmp_dir: dir} do
    project = app(dir, @new_activity, @old_jni)
    assert AppLifecycleHooks.check(project, mob(dir, @new_mob)) == {:missing, [@beam_jni]}
  end

  test "a ported app passes", %{tmp_dir: dir} do
    assert AppLifecycleHooks.check(app(dir, @new_activity, @new_jni), mob(dir, @new_mob)) == :ok
  end

  test "an older mob without mob_send_app_lifecycle is never told to add a call that won't link",
       %{tmp_dir: dir} do
    project = app(dir, @old_activity, @old_jni)
    assert AppLifecycleHooks.check(project, mob(dir, @old_mob)) == :ok
    assert AppLifecycleHooks.check(project, nil) == :ok
  end

  test "an iOS-only project has nothing to check", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "ios_app/ios"))
    assert AppLifecycleHooks.check(Path.join(dir, "ios_app"), mob(dir, @new_mob)) == :ok
  end
end
