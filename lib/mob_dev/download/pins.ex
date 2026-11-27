defmodule MobDev.Download.Pins do
  @moduledoc false

  # SHA-256 of every artifact mob_dev downloads, keyed by the exact URL the
  # downloader requests. `MobDev.Download.pin/1` refuses any URL not listed
  # here, and test/mob_dev/download/pins_test.exs fails when a downloader can
  # request a URL without a pin (or a pin is left for a URL nothing requests).
  #
  # Published assets are immutable: a rebuilt runtime is published under a new
  # name, and its pin is added here (the release publish scripts print the
  # lines to paste). See decisions/2026-11-26-pinned-runtime-downloads.md.

  @otp "https://github.com/GenericJam/mob/releases/download/otp-d199a49a"
  @mlx "https://github.com/GenericJam/mob/releases/download/mlx-0.25.1"
  @beeware "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b13"
  @chaquopy "https://repo1.maven.org/maven2/com/chaquo/python/target/3.13.9-0"
  @tflite_aar "https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.16.1"
  @tflite_ios "https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/32/20240729-115310/TensorFlowLiteC/2.17.0/0c10b3543e01f547"
  @tf_src "https://raw.githubusercontent.com/tensorflow/tensorflow/v2.16.1"

  @pins %{
    # MobDev.OtpDownloader
    "#{@otp}/otp-android-d199a49a.tar.gz" =>
      "4c6a6be625c08a6d062ebe97ced61a28d7fdd935fac890e40c593aab81f4489b",
    "#{@otp}/otp-android-arm32-d199a49a.tar.gz" =>
      "1d0137f691956e2fbda9692e1fcdf53117846b1e9882ba53626999ebccaedebe",
    "#{@otp}/otp-android-x86_64-d199a49a.tar.gz" =>
      "e7edc7779601cecfcdfeb005e11ff6ded0c6d98d934d5f38c0ef0aa5c8cbd016",
    "#{@otp}/otp-ios-sim-d199a49a.tar.gz" =>
      "a6066a1cce2391f78e1cbf45f89f758f78e42cf8f8fda7363660940f4a7b6755",
    "#{@otp}/otp-ios-device-d199a49a.tar.gz" =>
      "437475e8abb721f3ffbbfe6f17ddb495e8bddd13503eaee87aea5e2c14e5dd1d",
    # MobDev.MLXDownloader
    "#{@mlx}/libmlx-0.25.1-ios-device.tar.gz" =>
      "1baf4b2283d0d51ce7287c7bc9b00c1b51368adb056a437d9ae09ea512bb2cc3",
    "#{@mlx}/libmlx-0.25.1-ios-sim.tar.gz" =>
      "38866857f3acd26fdbfda0e8baf1e522dfbb3c2cd4f8fa8fc5157f5a6ee9b3d8",
    # MobDev.PythonAppleSupport
    "#{@beeware}/Python-3.13-iOS-support.b13.tar.gz" =>
      "d1f95f95137a4b91dc0cbe9b99ddfc0a78918dde883c7fbe7147074a5e715274",
    # MobDev.PythonAndroidSupport
    "#{@chaquopy}/target-3.13.9-0-arm64-v8a.zip" =>
      "c19f39fecada0b3932ab7a61b0f214c1212068cbbae0dc22c2afa38a4f354b8e",
    "#{@chaquopy}/target-3.13.9-0-x86_64.zip" =>
      "f9f2e36b08e60e92bcdd201eea4aff5ba13681b7b425ce24e0a140eca626674d",
    "#{@chaquopy}/target-3.13.9-0-stdlib.zip" =>
      "6172dfdaa0e89dc051936790a511d81debbae66bf9f3a95ea255290e9b0b3aca",
    # MobDev.TfliteDownloader
    "#{@tflite_aar}/tensorflow-lite-2.16.1.aar" =>
      "34b065817e294e7dd3569504e8b9454938ceae453b6a459da54d5f6e45d3c94e",
    "#{@tflite_ios}/TensorFlowLiteC-2.17.0.tar.gz" =>
      "9667b476015f136e5b332ce040e12822c4ac6d5c58947882ddc809cdff0fb99e",
    "#{@tf_src}/tensorflow/lite/core/c/registration_external.h" =>
      "83f6821a146f524725541181bae11936e37513e5fb6c6b8750188095291b449b",
    "#{@tf_src}/tensorflow/lite/core/async/c/types.h" =>
      "09caaccd1a1ebb824d9748fc36a5e0c3d45f9c99f3f0f80ce2cca87218687d14"
  }

  @doc "The pinned SHA-256 for `url`, or nil."
  @spec sha256(String.t()) :: String.t() | nil
  def sha256(url), do: Map.get(@pins, url)

  @doc "Every pin, URL => SHA-256."
  @spec all() :: %{String.t() => String.t()}
  def all, do: @pins
end
