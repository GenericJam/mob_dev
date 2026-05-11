defmodule Mix.Tasks.Mob.Release.Openssl do
  @shortdoc "Build OpenSSL + crypto NIF static archives for one Mob release target"

  @moduledoc """
  Drives the OpenSSL cross-compile + the OTP crypto NIF static archive
  for one target — replaces running `scripts/release/openssl/<plat>.sh`
  and `scripts/release/openssl/build_crypto_static_<plat>.sh` in
  sequence.

      mix mob.release.openssl android_arm64    # one target
      mix mob.release.openssl android_arm32
      mix mob.release.openssl ios_sim
      mix mob.release.openssl ios_device
      mix mob.release.openssl all              # all four, sequentially

  ## What runs

  For each target:
    1. `MobDev.Release.OpenSSL.build/2` — cross-compile OpenSSL 3.x,
       produces `<prefix>/lib/libcrypto.a` + headers.
    2. `MobDev.Release.OpenSSL.CryptoNif.build/2` — compile OTP's
       crypto NIF C sources with `-DSTATIC_ERLANG_NIF`, archive as
       `<otp_src>/lib/crypto/priv/lib/<arch>/crypto.a`, verify the
       `crypto_nif_init` symbol is exported.

  Both steps are required for the release tarball (handled in iter 4
  by `mix mob.release.tarball`); this task just produces the two
  artefacts and stops.

  ## Options

    * `--openssl-src PATH` — OpenSSL source checkout. Default:
      `$OPENSSL_SRC` env or `~/code/openssl`.
    * `--otp-src PATH` — OTP source checkout. Default: `$OTP_SRC` env
      or `~/code/otp`.
    * `--prefix PATH` — OpenSSL install prefix. Default per-target:
      `/tmp/openssl-<target>`.
    * `--ndk-root PATH` — Android NDK root (Android targets only).
      Default: `~/Library/Android/sdk/ndk/<recommended-version>`.

  ## Errors

  Failure produces a tagged `MobDev.Release.Errors` tuple formatted
  via `Mix.raise/1`. Common failure modes:

    * `precondition failed — OPENSSL_SRC missing` — clone openssl/openssl
    * `precondition failed — Android NDK not at <path>` — check NDK install
    * `precondition failed — iOS iphonesimulator SDK not available` —
      run `xcode-select --install`
    * `command failed (exit N)` — actual tool error, output in the
      raised message
  """
  use Mix.Task

  alias MobDev.Release.{Errors, OpenSSL}
  alias OpenSSL.CryptoNif

  @valid_targets [
    "android_arm64",
    "android_arm32",
    "ios_sim",
    "ios_device",
    "all"
  ]

  @switches [
    openssl_src: :string,
    otp_src: :string,
    prefix: :string,
    ndk_root: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [target_str] when target_str in @valid_targets ->
        targets =
          if target_str == "all" do
            OpenSSL.targets()
          else
            [String.to_atom(target_str)]
          end

        Enum.each(targets, &run_one(&1, opts))

      [bad] ->
        Mix.raise("unknown target: #{bad}\nvalid: #{Enum.join(@valid_targets, ", ")}")

      [] ->
        Mix.raise("missing target argument\nusage: mix mob.release.openssl <target>")

      _ ->
        Mix.raise("too many arguments — pass exactly one target")
    end
  end

  defp run_one(target_id, opts) do
    Mix.shell().info("==> OpenSSL #{target_id}")

    case OpenSSL.build(target_id, build_opts(opts, target_id)) do
      {:ok, info} ->
        Mix.shell().info("    ✓ libcrypto.a → #{info.libcrypto}")
        run_crypto_nif(target_id, info, opts)

      {:error, _} = err ->
        Mix.raise(Errors.format(err))
    end
  end

  defp run_crypto_nif(target_id, openssl_info, opts) do
    Mix.shell().info("==> crypto NIF #{target_id}")

    crypto_opts =
      opts
      |> build_opts(target_id)
      |> Keyword.put(:openssl_prefix, openssl_info.prefix)
      |> Keyword.drop([:openssl_src, :prefix])

    case CryptoNif.build(target_id, crypto_opts) do
      {:ok, info} ->
        Mix.shell().info("    ✓ crypto.a → #{info.archive}")

      {:error, _} = err ->
        Mix.raise(Errors.format(err))
    end
  end

  defp build_opts(opts, _target_id) do
    opts
    |> Keyword.take([:openssl_src, :otp_src, :prefix, :ndk_root])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
