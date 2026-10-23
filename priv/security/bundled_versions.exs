# Source-of-truth manifest for what versions ship inside the OTP
# tarballs that `MobDev.OtpDownloader` fetches.
#
# `:active_hash` MUST match `@otp_hash` in
# `lib/mob_dev/otp_downloader.ex` — the security-scan layer
# fingerprints `otp-*-{hash}/` in the runtime cache (`$MOB_CACHE_DIR`,
# default `~/.mob/cache`) against the bundle entry for this hash and
# raises if they disagree. The active bundle must record `:otp_version`.
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
  active_hash: "d199a49a",
  bundles: %{
    # Rebuilt from the OTP-29.1.2 tag (commit d199a49a) with OpenSSL 3.5.9
    # (MOB-493/494): every OTP security fix through 2026-10-14 and the 3.5
    # LTS branch. erts 17.0 -> 17.1.1. Same Elixir and exqlite BEAMs as
    # 5c9c69fc (exqlite 0.37.0 on android_x86_64, as before).
    "d199a49a" => %{
      erts: "17.1.1",
      otp_release: "29",
      otp_version: "29.1.2",
      elixir: "1.20.1",
      openssl: "3.5.9",
      exqlite_beam: "0.36.0",
      openssl_release_date: "2026-09-29",
      platforms: [:android, :android_arm32, :android_x86_64, :ios_sim, :ios_device],
      per_platform: %{
        android_x86_64: %{exqlite_beam: "0.37.0"},
        ios_sim: %{exqlite_beam: nil},
        ios_device: %{exqlite_beam: nil}
      }
    },
    # Same OTP-29 / erts-17.0 / OpenSSL base as 7d46fdd4, Elixir bumped
    # rc.5 -> 1.20.1 (stdlib swap; published as otp-5c9c69fc).
    "5c9c69fc" => %{
      erts: "17.0",
      otp_release: "29",
      elixir: "1.20.1",
      openssl: "3.4.0",
      exqlite_beam: "0.36.0",
      openssl_release_date: "2024-10-22",
      platforms: [:android, :android_arm32, :android_x86_64, :ios_sim, :ios_device],
      # The published android_x86_64 tarball carries exqlite 0.37.0 (checked
      # 2026-10-22 against the release asset); fingerprinted since MOB-493.
      per_platform: %{
        android_x86_64: %{exqlite_beam: "0.37.0"},
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
