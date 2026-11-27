defmodule Mix.Tasks.Mob.Release.Publish do
  @shortdoc "Upload built OTP tarballs to the GitHub release"

  @moduledoc """
  Drives `MobDev.Release.Publish.publish/1` from the CLI. Replaces
  `scripts/release/publish.sh`.

      mix mob.release.publish                          # all 5 default tarballs
      mix mob.release.publish --repo myfork/mob
      mix mob.release.publish --assets otp-android,otp-ios-sim
      mix mob.release.publish --hash abc12345

  ## Options

    * `--repo OWNER/NAME` — GitHub repo. Default: `GenericJam/mob`.
    * `--hash STR` — release tag hash. Default: detected from OTP source
      git, or `$HASH` env.
    * `--otp-src PATH` — OTP source checkout used for hash detection.
    * `--out-dir PATH` — directory containing the built tarballs.
      Default: `$OUT_DIR` or `/tmp`.
    * `--assets BASES` — comma-separated tarball basenames to upload
      (e.g. `otp-android,otp-ios-sim`). Default: auto-discover any of
      the five canonical names that exist in `--out-dir`.

  An asset already on the release is never replaced (released mob_dev
  versions pin its SHA-256); the task fails instead. On success it prints
  the `MobDev.Download.Pins` entries for the uploaded assets, to paste
  into `lib/mob_dev/download/pins.ex` along with the `@otp_hash` bump.

  ## Errors

  Failures format via `MobDev.Release.Errors.format/1` and raise through
  `Mix.raise/1`. The categories of interest here are
  `:auth_required` and `:infra_unreachable` — the publish step is the
  one place in the release pipeline where the failure is most often
  not the user's fault, so the message tells them whether it's a `gh
  auth login` problem, a GitHub outage, or something else.
  """
  use Mix.Task

  alias MobDev.Release.{Errors, Publish}

  @switches [
    repo: :string,
    hash: :string,
    otp_src: :string,
    out_dir: :string,
    assets: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [] ->
        do_publish(opts)

      _ ->
        Mix.raise("unexpected positional arguments: #{Enum.join(positional, " ")}")
    end
  end

  defp do_publish(opts) do
    Mix.shell().info("==> publish to GitHub release")

    publish_opts =
      opts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> normalize_assets()

    case Publish.publish(publish_opts) do
      {:ok, info} ->
        Mix.shell().info("    ✓ release #{info.tag} on #{info.repo}")
        Enum.each(info.assets, &Mix.shell().info("       • #{&1}"))
        Mix.shell().info("    Pin in lib/mob_dev/download/pins.ex:")
        Enum.each(info.pins, fn {url, sha} -> Mix.shell().info(pin_line(url, sha)) end)

      {:error, _} = err ->
        Mix.raise(Errors.format(err))
    end
  end

  @doc false
  @spec pin_line(String.t(), String.t()) :: String.t()
  def pin_line(url, sha), do: ~s(    "#{url}" =>\n      "#{sha}",)

  defp normalize_assets(opts) do
    case Keyword.fetch(opts, :assets) do
      {:ok, csv} ->
        bases = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        Keyword.put(opts, :assets, bases)

      :error ->
        opts
    end
  end
end
