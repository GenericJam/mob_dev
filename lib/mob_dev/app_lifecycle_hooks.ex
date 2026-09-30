defmodule MobDev.AppLifecycleHooks do
  @moduledoc """
  Detects an Android app that predates the `Mob.Device` `:app` lifecycle hooks.

  mob 0.9.6 exports `mob_send_app_lifecycle/1` and delivers `:did_become_active`,
  `:did_enter_background` etc. on Android, but only if the app's own
  `MainActivity.kt` calls `nativeNotifyAppLifecycle` and its `beam_jni.c`
  forwards that to `mob_send_app_lifecycle`. Both files are app-owned and never
  re-rendered, so an existing app that upgrades mob gets no events and
  `Mob.Device.foreground?/0` stays `true`, with no error anywhere. mob_dev
  detects rather than patches app-owned native source (see
  `decisions/2026-08-25-detect-dont-autopatch-native-source.md`).
  """

  @main_activity_glob "android/app/src/main/java/**/MainActivity.kt"
  @beam_jni "android/app/src/main/jni/beam_jni.c"

  @doc """
  What the app in `project_root` is missing, given the `mob` checkout it
  builds against: `:ok`, or `{:missing, files}` with the relative paths that
  lack their half of the hook. Always `:ok` for a project without `android/`
  or a mob that doesn't export `mob_send_app_lifecycle` (adding the hook there
  would fail to link).
  """
  @spec check(Path.t(), Path.t() | nil) :: :ok | {:missing, [String.t()]}
  def check(project_root, mob_dir) do
    main_activities = Path.wildcard(Path.join(project_root, @main_activity_glob))

    if main_activities != [] and mob_supports?(mob_dir) do
      files =
        Enum.map(
          main_activities,
          &{Path.relative_to(&1, project_root), "nativeNotifyAppLifecycle"}
        ) ++
          [{@beam_jni, "mob_send_app_lifecycle"}]

      case for {rel, marker} <- files, missing?(project_root, rel, marker), do: rel do
        [] -> :ok
        missing -> {:missing, missing}
      end
    else
      :ok
    end
  end

  @doc "Whether the mob checkout at `mob_dir` exports `mob_send_app_lifecycle` (mob 0.9.6+)."
  @spec mob_supports?(Path.t() | nil) :: boolean()
  def mob_supports?(nil), do: false

  def mob_supports?(mob_dir) do
    case File.read(Path.join([mob_dir, "android", "jni", "mob_beam.h"])) do
      {:ok, header} -> String.contains?(header, "mob_send_app_lifecycle")
      {:error, _} -> false
    end
  end

  @doc "The one-line problem statement."
  @spec problem() :: String.t()
  def problem do
    "app-owned MainActivity.kt / beam_jni.c predate the Android lifecycle hooks, so " <>
      "Mob.Device :app events (did_become_active, did_enter_background, ...) never " <>
      "arrive and Mob.Device.foreground?/0 is always true"
  end

  @doc "The upgrade steps, with the code to add."
  @spec fix() :: String.t()
  def fix do
    """
    Port the hooks from a freshly generated app (mix mob.new, mob_new 0.6.2+):
      1. android/app/src/main/jni/beam_jni.c — add, next to nativeNotifyOrientation:
           JNIEXPORT void JNICALL
           Java_<pkg>_MainActivity_nativeNotifyAppLifecycle(JNIEnv* env, jobject thiz, jstring event) {
               if (!event) return;
               const char* utf8 = (*env)->GetStringUTFChars(env, event, NULL);
               if (utf8) {
                   mob_send_app_lifecycle(utf8);
                   (*env)->ReleaseStringUTFChars(env, event, utf8);
               }
           }
      2. MainActivity.kt — add `external fun nativeNotifyAppLifecycle(event: String)`,
         companion flags `private var backgrounded = false` and
         `private var recreating = false`, a `notifyAppLifecycle(event)` wrapper that
         catches Throwable, and:
           onStart:   if (backgrounded) { backgrounded = false; notifyAppLifecycle("will_enter_foreground") }
           onResume:  if (recreating) recreating = false else notifyAppLifecycle("did_become_active")
           onPause:   if (isChangingConfigurations) recreating = true else notifyAppLifecycle("will_resign_active")
           onStop:    if (!isChangingConfigurations) { backgrounded = true; notifyAppLifecycle("did_enter_background") }
           onDestroy: if (isFinishing) notifyAppLifecycle("will_terminate")
      3. mix mob.deploy --native
    See mob's CHANGELOG (0.9.6, "Mob.Device :app lifecycle events on Android").\
    """
  end

  defp missing?(project_root, rel, marker) do
    case File.read(Path.join(project_root, rel)) do
      {:ok, content} -> not String.contains?(content, marker)
      {:error, _} -> true
    end
  end
end
