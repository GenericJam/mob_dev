# Source-of-truth manifest for what versions ship inside the OTP
# tarballs that `MobDev.OtpDownloader` fetches.
#
# `:active_hash` MUST match `@otp_hash` in
# `lib/mob_dev/otp_downloader.ex` — the security-scan layer
# fingerprints `~/.mob/cache/otp-*-{hash}/` against the bundle
# entry for this hash and raises if they disagree.
#
# When updating:
#
#   1. Bump `:active_hash` to the new hash
#   2. Add or replace the corresponding bundle entry
#   3. Run `mix mob.security_scan` — the bundled-runtime layer
#      will fingerprint the cached tarball and assert that the
#      binary matches the manifest. If it doesn't, fix the
#      manifest, the tarball, or both.
#
# Per-platform overrides let a single bundle entry describe
# platforms whose artifact set differs. `%{exqlite_beam: nil}`
# means "this platform deliberately does not ship the exqlite
# beam in the tarball" — the host's `_build/dev/lib/exqlite`
# is bundled at deploy time instead.

%{
  active_hash: "5c9c69fc",
  bundles: %{
    # Same OTP-29 / erts-17.0 / OpenSSL base as 7d46fdd4, Elixir bumped
    # rc.5 -> 1.20.1 (stdlib swap; published as otp-5c9c69fc).
    "5c9c69fc" => %{
      erts: "17.0",
      otp_release: "29",
      elixir: "1.20.1",
      openssl: "3.4.0",
      exqlite_beam: "0.36.0",
      openssl_release_date: "2024-10-22",
      platforms: [:android, :android_arm32, :ios_sim, :ios_device],
      per_platform: %{
        ios_sim: %{exqlite_beam: nil},
        ios_device: %{exqlite_beam: nil}
      }
    },
    "7d46fdd4" => %{
      erts: "17.0",
      otp_release: "29",
      elixir: "1.20.0-rc.5",
      openssl: "3.4.0",
      exqlite_beam: "0.36.0",
      openssl_release_date: "2024-10-22",
      platforms: [:android, :android_arm32, :ios_sim, :ios_device],
      per_platform: %{
        ios_sim: %{exqlite_beam: nil},
        ios_device: %{exqlite_beam: nil}
      }
    }
  }
}
