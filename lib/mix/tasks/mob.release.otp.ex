defmodule Mix.Tasks.Mob.Release.Otp do
  @shortdoc "Cross-compile the OTP runtime for one Mob release target"

  @moduledoc """
  Drives `MobDev.Release.OTP.build/2` from the CLI. Replaces the
  three `scripts/release/xcompile_*.sh` scripts plus the misplaced
  `scripts/release/openssl/_build_otp_android_arm64.sh`.

      mix mob.release.otp android_arm64    # one target
      mix mob.release.otp android_arm32
      mix mob.release.otp ios_sim
      mix mob.release.otp ios_device
      mix mob.release.otp all              # all four, sequentially

  ## What runs

  For each target:
    1. `make distclean` (tolerated — first-time builds have nothing)
    2. `./otp_build configure --xcomp-conf=<conf> <ssl-flags>`
    3. `./otp_build boot` (the long step — 5–10 minutes per target)
    4. `rm -rf <release_root>` then install:
       - Android: `./otp_build release -a <release_root>`
       - iOS: `make release RELEASE_ROOT=<release_root>`
    5. Verify per-target sanity (erts-<vsn> dir exists, Android also
       checks `lib/{crypto,public_key,ssl}-*` apps were produced).

  ## Options

    * `--otp-src PATH` — OTP source checkout. Default: `$OTP_SRC` env
      or `~/code/otp`.
    * `--openssl-prefix PATH` — pre-built OpenSSL install. Required
      for Android targets; ignored for iOS.
    * `--release-root PATH` — install destination. Default per-target.
    * `--ndk-root PATH` — Android NDK root override.

  ## Errors

  All failures format via `MobDev.Release.Errors.format/1` and raise
  through `Mix.raise/1`. Common cases:

    * `precondition failed — OTP_SRC missing` — clone erlang/otp
    * `precondition failed — openssl_prefix required` — run
      `mix mob.release.openssl <target>` first
    * `precondition failed — Android NDK not at …` — install NDK
    * `precondition failed — crypto / public_key / ssl apps missing` —
      this is the verify step catching a broken `--with-ssl` wiring;
      see the OTP source's `xcomp/erl-xcomp-<arch>-android.conf`
  """
  use Mix.Task

  alias MobDev.Release.{Errors, OTP}

  @valid_targets [
    "android_arm64",
    "android_arm32",
    "android_x86_64",
    "ios_sim",
    "ios_device",
    "all"
  ]

  @switches [
    otp_src: :string,
    openssl_prefix: :string,
    release_root: :string,
    ndk_root: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [target_str] when target_str in @valid_targets ->
        targets =
          if target_str == "all", do: OTP.targets(), else: [String.to_atom(target_str)]

        Enum.each(targets, &run_one(&1, opts))

      [bad] ->
        Mix.raise("unknown target: #{bad}\nvalid: #{Enum.join(@valid_targets, ", ")}")

      [] ->
        Mix.raise("missing target argument\nusage: mix mob.release.otp <target>")

      _ ->
        Mix.raise("too many arguments — pass exactly one target")
    end
  end

  defp run_one(target_id, opts) do
    Mix.shell().info("==> OTP cross-compile #{target_id}")
    Mix.shell().info("    (this takes 5–10 minutes — `./otp_build boot` dominates)")

    build_opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    case OTP.build(target_id, build_opts) do
      {:ok, info} ->
        Mix.shell().info("    ✓ release tree at #{info.release_root}")
        Mix.shell().info("    ✓ erts-#{info.erts_vsn}")

      {:error, _} = err ->
        Mix.raise(Errors.format(err))
    end
  end
end
