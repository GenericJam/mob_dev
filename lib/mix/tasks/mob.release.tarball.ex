defmodule Mix.Tasks.Mob.Release.Tarball do
  @shortdoc "Stage and tar the per-target OTP runtime tarball"

  @moduledoc """
  Drives `MobDev.Release.Tarball.build/2` from the CLI. Replaces the
  four `scripts/release/tarball_*.sh` scripts.

      mix mob.release.tarball android_arm64 --exqlite-build /path/to/_build/dev/lib/exqlite
      mix mob.release.tarball ios_sim
      mix mob.release.tarball ios_device
      mix mob.release.tarball all --exqlite-build /path/to/exqlite

  Android targets require `--exqlite-build` (no default — projects vary).
  iOS targets don't ship exqlite BEAMs so the flag is ignored.

  ## Options

    * `--otp-src PATH` — OTP source checkout. Default: `$OTP_SRC` env or
      `~/code/otp`.
    * `--otp-release PATH` — install tree from `mix mob.release.otp`.
      Default per-target.
    * `--openssl-prefix PATH` — OpenSSL install. Default per-target.
    * `--exqlite-build PATH` — `_build/dev/lib/exqlite` in any project
      that has run `mix deps.get && mix compile`. Required for Android.
    * `--android-otp-release PATH` — used by iOS targets to borrow
      `crypto`/`public_key`/`ssl` apps. Default: `/tmp/otp-android`.
    * `--asn1rt-nif-arm32 PATH` — pre-built arm32 asn1rt_nif.a.
      Default: `/tmp/asn1rt_nif_arm32.a`.
    * `--out-dir PATH` — tarball destination. Default: `/tmp`.
    * `--hash STR` — release tag hash. Default: detected from OTP git.
  """
  use Mix.Task

  alias MobDev.Release.{Errors, Tarball}

  @valid_targets ["android_arm64", "android_arm32", "ios_sim", "ios_device", "all"]

  @switches [
    otp_src: :string,
    otp_release: :string,
    openssl_prefix: :string,
    exqlite_build: :string,
    android_otp_release: :string,
    asn1rt_nif_arm32: :string,
    out_dir: :string,
    hash: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [target_str] when target_str in @valid_targets ->
        targets =
          if target_str == "all", do: Tarball.targets(), else: [String.to_atom(target_str)]

        Enum.each(targets, &run_one(&1, opts))

      [bad] ->
        Mix.raise("unknown target: #{bad}\nvalid: #{Enum.join(@valid_targets, ", ")}")

      [] ->
        Mix.raise("missing target argument\nusage: mix mob.release.tarball <target>")

      _ ->
        Mix.raise("too many arguments — pass exactly one target")
    end
  end

  defp run_one(target_id, opts) do
    Mix.shell().info("==> tarball #{target_id}")

    build_opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    case Tarball.build(target_id, build_opts) do
      {:ok, info} ->
        Mix.shell().info("    ✓ #{info.tarball}")

      {:error, _} = err ->
        Mix.raise(Errors.format(err))
    end
  end
end
