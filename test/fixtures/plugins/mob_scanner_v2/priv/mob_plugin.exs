%{
  name: :mob_scanner,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "QR / barcode scanner — extracted from mob core in Wave 3",
  nifs: [
    # iOS: Objective-C NIF — AVCaptureMetadataOutput in a full-screen view
    # controller (MobScannerVC, extracted from core ios/mob_nif.m:2939-3046).
    # lang: :objc -> compiled as ObjC (-fobjc-arc); platform: :ios so it
    # isn't pulled into the Android build.
    %{module: :mob_scanner_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the plugin-owned MobScannerActivity
    # (CameraX + ML Kit BarcodeScanning) via the Kotlin MobScannerBridge.
    %{module: :mob_scanner_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # NO :permissions capability entry on purpose: the :camera runtime
  # permission is OWNED by the mob_camera plugin (its iOS registry handler
  # mob_camera_request_permission + Android MobPermissionProvider mapping
  # live there). Scanner users must ALSO activate mob_camera and request
  # :camera via Mob.Permissions before scanning — declaring a second
  # :camera capability here would double-register the handler.
  android: %{
    bridge_kt: "priv/native/android/MobScannerBridge.kt",
    bridge_class: "io.mob.scanner.MobScannerBridge",
    # android.permission.CAMERA is also declared by mob_camera's manifest,
    # but scanner must declare it too: if mob_scanner is activated WITHOUT
    # mob_camera the CAMERA uses-permission would otherwise be missing and
    # CameraX throws at bind time. The manifest merge set-unions permission
    # strings, so the duplicate is harmless when both plugins are active.
    permissions: [
      "android.permission.CAMERA"
    ],
    # CameraX artifacts are ALSO declared by mob_camera's gradle_deps —
    # the native merge set-unions gradle_deps, so the duplicates de-dup.
    # appcompat is needed because MobScannerActivity extends
    # AppCompatActivity (CameraX PreviewView + ML Kit want an AppCompat
    # theme/context); versions match the mob_new template
    # (build.gradle.eex:122-133).
    gradle_deps: [
      "androidx.appcompat:appcompat:1.6.1",
      # 1.4.2 (not the newer 1.6.1): 16 KB page-aligned
      # libimage_processing_util_jni.so, fixed starting at CameraX 1.4.0 (see
      # mob/issues.md #6) — 1.3.4 predates the fix. Deliberately NOT bumped to
      # the current-stable 1.6.x line: 1.6.1 requires compileSdk 36 + AGP
      # 8.9.1+ (device-build-verified failure against this toolchain's
      # compileSdk 34 / AGP 8.2.0); 1.4.2 needs neither. Kept in lockstep with
      # mob_camera's gradle_deps.
      "androidx.camera:camera-camera2:1.4.2",
      "androidx.camera:camera-lifecycle:1.4.2",
      "androidx.camera:camera-view:1.4.2",
      # 17.3.0: 16 KB page-aligned libbarhopper_v3.so (the fix ships starting
      # at this version — see mob/issues.md #6). 17.2.0 predates it.
      "com.google.mlkit:barcode-scanning:17.3.0"
    ],
    # The scanner Activity (class ships in MobScannerBridge.kt). Spliced into
    # the host's <application> by the native build (mob_dev >= 0.6.19); a
    # hand-declared copy is detected by android:name and not doubled. The
    # AppCompat theme is required: MobScannerActivity extends
    # AppCompatActivity and throws IllegalStateException at setContentView
    # under a non-AppCompat theme.
    manifest_application_snippets: [
      """
      <activity android:name="io.mob.scanner.MobScannerActivity"
          android:exported="false"
          android:theme="@style/Theme.AppCompat.NoActionBar" />
      """
    ]
  },
  # AVCaptureSession / AVCaptureMetadataOutput / AVCaptureVideoPreviewLayer
  # all live in AVFoundation; UIKit/Foundation are implicit. No plist_keys —
  # NSCameraUsageDescription is owned by mob_camera (which scanner users
  # must activate anyway for the :camera permission); declaring it here too
  # would collide in the plist merge.
  ios: %{frameworks: ["AVFoundation"]},
  # Manual host-app steps the build can't automate; printed as a warning on
  # every `mix mob.deploy --native` of the host.
  host_requirements: [
    "The :camera runtime permission is owned by the mob_camera plugin — activate " <>
      "mob_camera alongside mob_scanner and request :camera via Mob.Permissions " <>
      "before scanning (mob_camera also carries the iOS NSCameraUsageDescription " <>
      "plist key; without it iOS kills the app at first camera access)."
  ]
}
