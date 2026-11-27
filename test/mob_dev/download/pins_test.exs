defmodule MobDev.Download.PinsTest do
  use ExUnit.Case, async: true

  alias MobDev.Download.Pins

  # Every URL a downloader can request, enumerated through the same functions
  # the downloaders build their URLs with. No network.
  defp requested_urls do
    Enum.concat([
      MobDev.OtpDownloader.download_urls(),
      MobDev.MLXDownloader.download_urls(),
      MobDev.TfliteDownloader.download_urls(),
      MobDev.PythonAppleSupport.download_urls(),
      MobDev.PythonAndroidSupport.download_urls()
    ])
  end

  test "every asset a downloader can request has a pinned sha256" do
    urls = requested_urls()
    assert Enum.count_until(urls, 15) == 15

    unpinned = Enum.reject(urls, &Pins.sha256/1)
    assert unpinned == [], "no sha256 pin for: #{Enum.join(unpinned, ", ")}"
  end

  test "every pin is a lowercase hex sha256" do
    for {url, sha} <- Pins.all() do
      assert sha =~ ~r/\A[0-9a-f]{64}\z/, "malformed pin for #{url}: #{inspect(sha)}"
    end
  end

  test "no pin is left over for an asset nothing requests" do
    stale = Map.keys(Pins.all()) -- requested_urls()
    assert stale == [], "pins nothing downloads: #{Enum.join(stale, ", ")}"
  end

  test "every pinned URL is https" do
    for url <- Map.keys(Pins.all()), do: assert(String.starts_with?(url, "https://"))
  end
end
