defmodule MobDev.SecurityScan.BundledRuntime.FingerprintCacheDirTest do
  # Sets MOB_CACHE_DIR, which is process-global.
  use ExUnit.Case, async: false

  alias MobDev.SecurityScan.BundledRuntime.{AdvisoryFeed, Fingerprint}

  @moduletag :tmp_dir

  setup do
    previous = System.get_env("MOB_CACHE_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("MOB_CACHE_DIR", previous),
        else: System.delete_env("MOB_CACHE_DIR")
    end)
  end

  # OtpDownloader extracts runtimes into $MOB_CACHE_DIR; a scan that read
  # ~/.mob/cache instead audited runtimes the app doesn't use.
  test "the scan reads the runtime cache from MOB_CACHE_DIR", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "otp-android-d199a49a"))
    System.put_env("MOB_CACHE_DIR", dir)

    assert [%{platform: :android, hash: "d199a49a"}] = Fingerprint.locate_cached_tarballs()
    assert AdvisoryFeed.default_cache_dir() == Path.join(dir, "advisories")
  end
end
