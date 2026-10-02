# `:xcode_live` asserts the selected Xcode's real version against MOB_EXPECT_*
# env vars; only the macOS `xcode` CI lane sets them (MOB-201).
ExUnit.start(exclude: [:integration, :acceptance, :xcode_live])

# Mox setup — every behaviour-based mock used in tests gets defined in
# test/support/ via Mox.defmock and just needs an `Application.put_env`
# in the relevant test's setup to take effect.
