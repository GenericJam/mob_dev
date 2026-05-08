# mix_audit 2.1.5 trips OTP 28.0's `:re.import/1` undef bug deep inside its
# own beam files. Skip the affected layer test on OTP 28 hosts — passes
# automatically again the moment the host upgrades off 28.0.
# See test/mob_dev/security_scan/layers/hex_deps_test.exs for the full story.
extra_excludes =
  if System.otp_release() == "28", do: [:mix_audit_otp28_broken], else: []

ExUnit.start(exclude: [:integration] ++ extra_excludes)
