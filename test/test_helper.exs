ExUnit.start(exclude: [:integration, :acceptance])

# Mox setup — every behaviour-based mock used in tests gets defined in
# test/support/ via Mox.defmock and just needs an `Application.put_env`
# in the relevant test's setup to take effect.
