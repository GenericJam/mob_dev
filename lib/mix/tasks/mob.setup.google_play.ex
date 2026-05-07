defmodule Mix.Tasks.Mob.Setup.GooglePlay do
  use Mix.Task

  @shortdoc "Automate the Google Cloud setup steps for Play Store publishing"

  @moduledoc """
  Interactive wizard that automates the Google Cloud steps required before
  `mix mob.publish --android` can work.

  ## Usage

      mix mob.setup.google_play
      mix mob.setup.google_play --package com.example.myapp

  ## What it does

  Opens your browser for a one-time Google sign-in, then automatically:

    1. Lists your Google Cloud projects (prompts you to pick one)
    2. Enables the Android Publisher API in that project
    3. Creates a `play-publisher` service account
    4. Generates a JSON key and saves it to `~/.google_play/`
    5. Attempts to grant Release Manager access via the Play Developer API
    6. Generates `android/upload_jks.keystore` if not present
    7. Prints the `mob.exs` config block to add

  The wizard also walks you through the four steps that genuinely cannot be
  automated (account creation, identity verification, app record creation,
  and linking the Cloud project to Play Console).

  ## Manual fallback

  If you prefer to complete any step manually, the wizard degrades gracefully
  and prints exact instructions. See `guides/publishing_to_google_play.md`
  for the full browser-based walkthrough.

  ## Options

    * `--package` — Android applicationId (e.g. `com.example.myapp`). If omitted,
      the wizard will prompt for it.
    * `--key-name` — Base filename for the saved JSON key (without `.json`).
      Defaults to the last segment of the package name + `-service-account`.
    * `--dry-run` — Print every step the wizard would take without making any
      API calls, writing any files, or opening a browser. Use this to preview
      the wizard before running it for real.

  ## OAuth client

  The wizard signs in using an OAuth2 Desktop App client bundled with mob_dev.
  No external CLI tools (gcloud, etc.) are required. The sign-in is a standard
  Google OAuth browser flow — you will see Google's consent screen.

  To use your own OAuth client instead, set:

      export GOOGLE_OAUTH_CLIENT_ID=your_client_id.apps.googleusercontent.com
      export GOOGLE_OAUTH_CLIENT_SECRET=your_client_secret
  """

  @switches [package: :string, key_name: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    wizard_opts =
      []
      |> maybe_put(:package_name, opts[:package])
      |> maybe_put(:key_filename, opts[:key_name])
      |> maybe_put(:dry_run, opts[:dry_run])

    case MobDev.GooglePlay.SetupWizard.run(wizard_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error(reason)
        exit({:shutdown, 1})
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
