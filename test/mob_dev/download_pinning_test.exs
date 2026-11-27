defmodule MobDev.DownloadPinningTest do
  # Every downloader must check what it fetched against the pin before using
  # it. A stub `curl` on PATH answers every request with bytes that match no
  # pin; each downloader's ensure must then fail with a sha256 mismatch and
  # leave nothing extracted, cached or marked. No network.
  #
  # async: false — PATH, MOB_CACHE_DIR and the local-override env vars are
  # process-global.
  use ExUnit.Case, async: false

  alias MobDev.{MLXDownloader, OtpDownloader, PythonAndroidSupport, PythonAppleSupport}
  alias MobDev.TfliteDownloader

  @moduletag :tmp_dir

  @fake_curl """
  #!/bin/sh
  echo "$@" >> "$FAKE_CURL_LOG"
  out=""
  while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; esac
    shift
  done
  printf 'not the pinned bytes' > "$out"
  exit 0
  """

  @overrides ~w(MOB_MLX_LOCAL_TARBALL_DIR MOB_TFLITE_LOCAL_TARBALL_DIR)

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    curl = Path.join(bin, "curl")
    File.write!(curl, @fake_curl)
    File.chmod!(curl, 0o755)

    cache = Path.join(tmp, "cache")
    log = Path.join(tmp, "curl.log")
    saved = for var <- ["PATH", "MOB_CACHE_DIR" | @overrides], do: {var, System.get_env(var)}

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("MOB_CACHE_DIR", cache)
    System.put_env("FAKE_CURL_LOG", log)
    Enum.each(@overrides, &System.delete_env/1)

    on_exit(fn ->
      System.delete_env("FAKE_CURL_LOG")

      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    {:ok, cache: cache, log: log}
  end

  test "OtpDownloader", ctx do
    assert_refused(ctx, OtpDownloader.download_url("otp-ios-sim-d199a49a"), fn ->
      OtpDownloader.ensure_ios_sim()
    end)
  end

  test "MLXDownloader", ctx do
    assert_refused(ctx, MLXDownloader.download_url(:ios_device), fn ->
      MLXDownloader.ensure(:ios_device)
    end)
  end

  test "PythonAppleSupport", ctx do
    assert_refused(ctx, PythonAppleSupport.download_url(), &PythonAppleSupport.ensure/0)
  end

  test "PythonAndroidSupport", ctx do
    assert_refused(ctx, PythonAndroidSupport.download_url("arm64-v8a"), fn ->
      PythonAndroidSupport.ensure()
    end)
  end

  test "TfliteDownloader: the Android AAR", ctx do
    [aar_url | _] = TfliteDownloader.download_urls()

    assert_refused(ctx, aar_url, fn -> TfliteDownloader.ensure(:android_arm64) end)
  end

  test "TfliteDownloader: the iOS tarball", ctx do
    [_, tarball_url | _] = TfliteDownloader.download_urls()

    assert_refused(ctx, tarball_url, fn -> TfliteDownloader.ensure(:ios_device) end)
  end

  test "TfliteDownloader: the headers patched into the Android tree", ctx do
    # A local AAR without the two headers, so ensure/1 has to fetch them.
    local = Path.join(ctx.tmp_dir, "local")
    File.mkdir_p!(local)
    aar = Path.join(local, "tensorflow-lite-#{TfliteDownloader.android_version()}.aar")

    {:ok, _} =
      :zip.create(String.to_charlist(aar), [
        {~c"jni/arm64-v8a/libtensorflowlite_jni.so", "so"},
        {~c"headers/tensorflow/lite/c/c_api.h", "h"}
      ])

    System.put_env("MOB_TFLITE_LOCAL_TARBALL_DIR", local)
    header_url = Enum.find(TfliteDownloader.download_urls(), &String.ends_with?(&1, ".h"))

    assert_refused(ctx, header_url, fn -> TfliteDownloader.ensure(:android_arm64) end)
  end

  defp assert_refused(%{cache: cache, log: log}, url, ensure) do
    {:ok, pin} = MobDev.Download.pin(url)

    {result, _output} = ExUnit.CaptureIO.with_io(:stderr, fn -> silent(ensure) end)

    assert {:error, msg} = result
    assert msg =~ "sha256 mismatch"
    assert msg =~ pin
    assert File.read!(log) =~ url, "the stub curl was never asked for #{url}"

    files =
      Path.join(cache, "**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    assert files == [], "left behind after a refused download: #{inspect(files)}"
  end

  defp silent(fun) do
    {result, _} = ExUnit.CaptureIO.with_io(fun)
    result
  end
end
