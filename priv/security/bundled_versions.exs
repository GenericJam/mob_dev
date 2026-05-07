# Source-of-truth manifest for what versions ship inside the OTP
# tarballs that `MobDev.OtpDownloader` fetches.
#
# This file MUST be updated every time those tarballs are rebuilt
# and re-uploaded to the GitHub release. The bundled-runtime scan
# layer fingerprints the cached tarballs at scan time and raises if
# the binaries disagree with what's declared here — drift between
# what we say we shipped and what we actually shipped is exactly
# the failure mode this manifest is designed to catch.
#
# When updating:
#
#   1. Bump the appropriate `:otp_hash` entry (or add a new one)
#   2. Update the version fields under `:bundles`
#   3. Run `mix mob.security_scan` — the bundled-runtime layer
#      will fingerprint the cached tarball and assert that the
#      binary matches the manifest. If it doesn't, fix the
#      manifest, the tarball, or both.
#
# The OTP hash matches `MobDev.OtpDownloader`'s `@otp_hash`. There
# is exactly one active hash per published Mob release.
#
# Format:
#
#   %{
#     active_hash: "73ba6e0f",
#     bundles: %{
#       "73ba6e0f" => %{
#         erts: "16.3",         # erts-* directory in tarball
#         otp_release: "28",    # major OTP release number
#         elixir: "1.19.5",     # bundled Elixir stdlib version
#         openssl: "3.4.0",     # statically linked into libcrypto.a
#         exqlite_beam: "0.36.0",
#         openssl_release_date: "2024-10-22",
#         platforms: [:android, :android_arm32, :ios_sim, :ios_device]
#       }
#     }
#   }

%{
  active_hash: "73ba6e0f",
  bundles: %{
    "73ba6e0f" => %{
      erts: "16.3",
      otp_release: "28",
      elixir: "1.19.5",
      openssl: "3.4.0",
      exqlite_beam: "0.36.0",
      openssl_release_date: "2024-10-22",
      platforms: [:android, :android_arm32, :ios_sim, :ios_device]
    }
  }
}
