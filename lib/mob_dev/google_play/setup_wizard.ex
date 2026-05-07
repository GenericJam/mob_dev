defmodule MobDev.GooglePlay.SetupWizard do
  @moduledoc """
  Interactive wizard for the Google Play one-time setup.

  Automates the Google Cloud steps in the publishing guide (section 1.4),
  leaving only the irreducible manual steps that have no API:

  **Automated by this wizard:**
  - Browser OAuth sign-in (no gcloud required)
  - Selecting or confirming the Google Cloud project
  - Enabling the Android Publisher API
  - Creating the `play-publisher` service account
  - Generating and saving the JSON key to `~/.google_play/`
  - Granting Release Manager access via the Play Developer API
  - Generating the upload keystore (if not already present)
  - Printing the `mob.exs` config block to add

  **Manual steps that cannot be automated (all one-time per developer account):**
  1. Create the Google Play Developer account (requires $25 payment)
  2. Complete identity verification (government ID upload)
  3. Create the app record in Play Console (no create-app API)
  4. Link the Google Cloud project to Play Console:
     Play Console → Setup → API access → Link to a Google Cloud project

  See `guides/publishing_to_google_play.md` for the full step-by-step guide.
  """

  alias MobDev.GooglePlay.{CloudSetup, OAuth, PlaySetup}

  @doc """
  Runs the full interactive setup wizard.

  Options:
  - `:package_name` — Android applicationId (e.g. "com.example.myapp"). If not
    provided, the wizard will prompt for it.
  - `:key_filename` — base filename for the service account JSON (without `.json`).
    Defaults to the last segment of the package name (e.g. `"myapp"`).
  - `:dry_run` — when `true`, prints every step but makes no HTTP calls, writes no
    files, opens no browser, and answers all prompts automatically. Use this to
    preview the wizard before running it for real.

  Returns `:ok` on success or `{:error, reason}` on any unrecoverable step.
  """
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts \\ []) do
    shell = Mix.shell()
    dry? = Keyword.get(opts, :dry_run, false)

    shell.info("")

    if dry? do
      shell.info(yellow() <> "=== Mob Google Play Setup (DRY RUN) ===" <> reset())
      shell.info("")
      shell.info("Showing every step the wizard would take — no changes will be made.")
      shell.info("No browser will open, no API calls will be made, no files will be written.")
    else
      shell.info(cyan() <> "=== Mob Google Play Setup ===" <> reset())
      shell.info("")
      shell.info("This wizard automates the Google Cloud steps in the publishing guide.")
      shell.info("You will need to complete 4 manual steps — the wizard will prompt you.")
    end

    shell.info("")

    package_name = opts[:package_name] || prompt_package_name(shell, dry?)
    key_filename = opts[:key_filename] || default_key_filename(package_name)

    with :ok <- step_keystore(shell, dry?),
         :ok <- step_manual_account_creation(shell, dry?),
         log_step(shell, "1/6", "Sign in to Google", dry?),
         {:ok, token} <- step_oauth(shell, dry?),
         log_step(shell, "2/6", "Select Google Cloud project", dry?),
         {:ok, project_id} <- step_select_project(shell, token, dry?),
         log_step(shell, "3/6", "Enable Android Publisher API", dry?),
         :ok <- step_enable_api(shell, token, project_id, dry?),
         log_step(shell, "4/6", "Create service account", dry?),
         {:ok, sa_email} <- step_create_service_account(shell, token, project_id, dry?),
         log_step(shell, "5/6", "Generate and save JSON key", dry?),
         {:ok, key_path} <-
           step_create_key(shell, token, project_id, sa_email, key_filename, dry?),
         log_step(shell, "6/6", "Grant Play Console access", dry?),
         :ok <- step_grant_access(shell, token, sa_email, package_name, dry?) do
      step_print_config(shell, package_name, key_path, dry?)
      :ok
    end
  end

  # ── Step helpers ─────────────────────────────────────────────────────────────

  defp step_keystore(shell, dry?) do
    keystore_path = Path.expand("android/upload_jks.keystore")

    cond do
      dry? ->
        shell.info(dry_tag() <> " Would check for #{keystore_path}")
        shell.info(dry_tag() <> " If missing: prompt to generate it with keytool (-keyalg RSA,")
        shell.info("           -keysize 2048, -validity 10000, -storetype JKS)")
        shell.info(dry_tag() <> " Would also write android/keystore.properties")
        :ok

      File.exists?(keystore_path) ->
        shell.info(green() <> "✓" <> reset() <> " Keystore already exists: #{keystore_path}")
        :ok

      true ->
        shell.info(yellow() <> "!" <> reset() <> " No upload keystore found.")

        if shell.yes?("  Generate android/upload_jks.keystore now?") do
          generate_keystore(shell, keystore_path)
        else
          shell.info("  Skipping keystore. Generate it later with:")
          shell.info("    keytool -genkey -v -keystore android/upload_jks.keystore \\")
          shell.info("      -alias upload -keyalg RSA -keysize 2048 -validity 10000 -storetype JKS")
          :ok
        end
    end
  end

  defp generate_keystore(shell, path) do
    shell.info("")
    passphrase = shell.prompt("  Keystore passphrase (remember this — back it up!): ")
    name = shell.prompt("  Your full name: ")
    org = shell.prompt("  Organisation (or your name): ")

    args = [
      "-genkey",
      "-v",
      "-keystore",
      path,
      "-alias",
      "upload",
      "-keyalg",
      "RSA",
      "-keysize",
      "2048",
      "-validity",
      "10000",
      "-storetype",
      "JKS",
      "-dname",
      "CN=#{name}, O=#{org}, L=Unknown, ST=Unknown, C=Unknown",
      "-storepass",
      passphrase,
      "-keypass",
      passphrase
    ]

    case System.cmd("keytool", args, stderr_to_stdout: true) do
      {_, 0} ->
        props_path = Path.expand("android/keystore.properties")
        write_keystore_properties(props_path, passphrase)

        shell.info(green() <> "✓" <> reset() <> " Keystore created at #{path}")

        shell.info(
          "  IMPORTANT: Back up #{path} and the passphrase — you cannot update your app without them."
        )

        :ok

      {out, rc} ->
        {:error, "keytool failed (exit #{rc}): #{out}"}
    end
  end

  defp write_keystore_properties(path, passphrase) do
    unless File.exists?(path) do
      File.write!(path, """
      storeFile=upload_jks.keystore
      storePassword=#{passphrase}
      keyAlias=upload
      keyPassword=#{passphrase}
      """)
    end
  end

  defp step_manual_account_creation(shell, dry?) do
    shell.info("")
    shell.info(yellow() <> "── Manual prerequisite steps ──" <> reset())
    shell.info("")
    shell.info("These four steps cannot be automated. If you haven't done them yet, do")
    shell.info("them now before continuing:")
    shell.info("")
    shell.info("  1. Create a Google Play Developer account ($25 one-time fee)")
    shell.info("     https://play.google.com/console")
    shell.info("")
    shell.info("  2. Complete identity verification (government ID upload)")
    shell.info("     This appears as a prompt in the Play Console.")
    shell.info("")
    shell.info("  3. Create the app record in Play Console")
    shell.info("     Play Console → Create app → fill in name, language, etc.")
    shell.info("")
    shell.info("  4. Link your Google Cloud project to Play Console")
    shell.info("     Play Console → Setup → API access → Link to a Google Cloud project")
    shell.info("     (Do this AFTER step 3 of this wizard creates the Cloud project)")
    shell.info("")

    if dry? do
      shell.info(dry_tag() <> " [auto-yes] Have you completed steps 1-3?")
      :ok
    else
      if shell.yes?(
           "Have you completed steps 1-3 above (step 4 comes after the wizard creates the project)?"
         ) do
        :ok
      else
        shell.info("")
        shell.info("Complete the steps above, then re-run: mix mob.setup.google_play")
        {:error, "setup paused — prerequisites not complete"}
      end
    end
  end

  defp step_oauth(shell, true = _dry?) do
    shell.info(dry_tag() <> " Would open browser to Google OAuth consent screen")
    shell.info(dry_tag() <> " Would listen on a random localhost port for the callback")
    shell.info(dry_tag() <> " Would exchange authorization code for access token")
    {:ok, "dry_run_token"}
  end

  defp step_oauth(_shell, false) do
    OAuth.authorize(scopes: OAuth.setup_scopes())
  end

  defp step_select_project(shell, _token, true = _dry?) do
    shell.info(dry_tag() <> " Would call Cloud Resource Manager API to list your projects")
    shell.info(dry_tag() <> " Would prompt you to pick one if multiple exist")
    shell.info(dry_tag() <> " Using placeholder: your-gcp-project-id")
    {:ok, "your-gcp-project-id"}
  end

  defp step_select_project(shell, token, false) do
    case CloudSetup.list_projects(token) do
      {:ok, []} ->
        shell.info("  No Google Cloud projects found.")
        shell.info("  Create one at https://console.cloud.google.com and re-run the wizard.")
        {:error, "no Cloud projects found"}

      {:ok, [%{"projectId" => id, "displayName" => name}]} ->
        shell.info("  Using project: #{name} (#{id})")
        {:ok, id}

      {:ok, projects} ->
        shell.info("  Found #{length(projects)} Cloud projects:")
        shell.info("")

        projects
        |> Enum.with_index(1)
        |> Enum.each(fn {%{"projectId" => id, "displayName" => name}, n} ->
          shell.info("    #{n}. #{name} (#{id})")
        end)

        shell.info("")
        answer = shell.prompt("  Enter project number or ID: ")
        pick_project(projects, String.trim(answer))

      {:error, _} = err ->
        err
    end
  end

  defp pick_project(projects, input) do
    case Integer.parse(input) do
      {n, ""} when n >= 1 and n <= length(projects) ->
        {:ok, Enum.at(projects, n - 1)["projectId"]}

      _ ->
        if Enum.any?(projects, &(&1["projectId"] == input)) do
          {:ok, input}
        else
          {:error, "Unknown project: #{input}"}
        end
    end
  end

  defp step_enable_api(shell, _token, project_id, true = _dry?) do
    shell.info(dry_tag() <> " Would POST to Service Usage API:")
    shell.info("           serviceusage.googleapis.com/v1/projects/#{project_id}/services/")
    shell.info("           androidpublisher.googleapis.com:enable")
    shell.info(dry_tag() <> " Would poll the returned operation until done (up to 60s)")
    :ok
  end

  defp step_enable_api(shell, token, project_id, false) do
    shell.info("  Enabling androidpublisher.googleapis.com in #{project_id}...")
    shell.info("  (This can take up to 60 seconds.)")

    case CloudSetup.enable_publisher_api(token, project_id) do
      :ok ->
        shell.info(green() <> "  ✓ Android Publisher API enabled" <> reset())
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp step_create_service_account(shell, _token, project_id, true = _dry?) do
    email = "play-publisher@#{project_id}.iam.gserviceaccount.com"
    shell.info(dry_tag() <> " Would POST to IAM API to create service account `play-publisher`")
    shell.info(dry_tag() <> " If it already exists (HTTP 409), would reuse it")
    shell.info(dry_tag() <> " Resulting email: #{email}")
    {:ok, email}
  end

  defp step_create_service_account(shell, token, project_id, false) do
    shell.info("  Creating play-publisher service account in #{project_id}...")

    case CloudSetup.create_service_account(token, project_id) do
      {:ok, email} ->
        shell.info(green() <> "  ✓ Service account: #{email}" <> reset())
        {:ok, email}

      {:error, _} = err ->
        err
    end
  end

  defp step_create_key(shell, _token, _project_id, sa_email, filename, true = _dry?) do
    path = Path.expand("~/.google_play/#{filename}.json")
    shell.info(dry_tag() <> " Would POST to IAM API to generate a JSON key for #{sa_email}")
    shell.info(dry_tag() <> " Would base64-decode the response and write to #{path} (mode 600)")
    shell.info(dry_tag() <> " Key file is a one-time download — cannot be recovered if lost")
    {:ok, path}
  end

  defp step_create_key(shell, token, project_id, sa_email, filename, false) do
    shell.info("  Generating JSON key for #{sa_email}...")

    case CloudSetup.create_and_save_key(token, project_id, sa_email, filename) do
      {:ok, path} ->
        shell.info(green() <> "  ✓ Key saved to #{path}" <> reset())
        shell.info("  IMPORTANT: Back up this file — it cannot be recovered if lost.")
        {:ok, path}

      {:error, _} = err ->
        err
    end
  end

  defp step_grant_access(shell, _token, sa_email, _package_name, true = _dry?) do
    shell.info("")
    shell.info(yellow() <> "── Manual step required ──" <> reset())
    shell.info("")
    shell.info("Before the service account can publish, you must link your Cloud project")
    shell.info("to Play Console (if you haven't done so already):")
    shell.info("")
    shell.info("  Play Console → Setup → API access → Link to a Google Cloud project")
    shell.info("")
    shell.info(dry_tag() <> " Would prompt for developer account ID (the number in the Play Console URL)")
    shell.info(dry_tag() <> " Would POST to Play Developer API accounts.grants.create:")
    shell.info("           androidpublisher.googleapis.com/androidpublisher/v3/accounts/{id}/grants")
    shell.info("           grantee: #{sa_email}")
    shell.info("           permissions: CAN_MANAGE_RELEASES, CAN_ACCESS_DRAFT_APPS")
    shell.info(dry_tag() <> " Falls back to printing manual instructions if API grant fails")
    :ok
  end

  defp step_grant_access(shell, token, sa_email, package_name, false) do
    shell.info("")
    shell.info(yellow() <> "── Manual step required ──" <> reset())
    shell.info("")
    shell.info("Before the service account can publish, you must link your Cloud project")
    shell.info("to Play Console (if you haven't done so already):")
    shell.info("")
    shell.info("  Play Console → Setup → API access → Link to a Google Cloud project")
    shell.info("")
    shell.info("This is a one-time step and has no API — it must be done in the browser.")
    shell.info("")

    if shell.yes?("Have you linked the Cloud project to Play Console?") do
      attempt_grant_via_api(shell, token, sa_email, package_name)
    else
      shell.info("")
      print_manual_grant_instructions(shell, sa_email)
      :ok
    end
  end

  defp attempt_grant_via_api(shell, token, sa_email, package_name) do
    shell.info("")
    shell.info("  To grant access automatically, I need your Play developer account ID.")
    shell.info("  Find it in the Play Console URL:")
    shell.info("    https://play.google.com/console/u/0/developers/XXXXXXXXXX/...")
    shell.info("  (it's the long number after /developers/)")
    shell.info("")

    account_id = shell.prompt("  Enter developer account ID (or press Enter to skip): ")
    account_id = String.trim(account_id)

    if account_id == "" do
      shell.info("")
      print_manual_grant_instructions(shell, sa_email)
      :ok
    else
      shell.info("  Granting Release Manager access via Play API...")

      case PlaySetup.grant_release_manager(token, account_id, sa_email, package_name) do
        :ok ->
          shell.info(green() <> "  ✓ Release Manager access granted" <> reset())
          :ok

        {:error, reason} ->
          shell.info(yellow() <> "  ! API grant failed: #{reason}" <> reset())
          shell.info("  Falling back to manual instructions:")
          print_manual_grant_instructions(shell, sa_email)
          :ok
      end
    end
  end

  defp print_manual_grant_instructions(shell, sa_email) do
    shell.info("  Complete these two steps in Play Console to grant publishing access:")
    shell.info("")
    shell.info("  Part A — API access page:")
    shell.info("    Play Console → Setup → API access → Grant access next to the service account")
    shell.info("    Role: Release manager → Apply → Invite user")
    shell.info("")
    shell.info("  Part B — Users and permissions:")
    shell.info("    Play Console → Users and permissions → Invite new users")
    shell.info("    Email: #{sa_email}")
    shell.info("    Role: Release manager → Apply → Invite user")
    shell.info("")
    shell.info("  Both parts are required. Service accounts auto-accept invitations.")
  end

  defp step_print_config(shell, package_name, key_path, dry?) do
    shell.info("")

    if dry? do
      shell.info(yellow() <> "=== Dry run complete ===" <> reset())
      shell.info("")
      shell.info("The above shows every step the real wizard would take.")
      shell.info("Run without --dry-run to execute for real:")
      shell.info("")
      shell.info("  mix mob.setup.google_play")
      shell.info("")
      shell.info("When the real run completes, it will print a mob.exs block like this:")
    else
      shell.info(green() <> "=== Setup complete! ===" <> reset())
      shell.info("")
      shell.info("Add this block to your mob.exs:")
    end

    shell.info("")
    shell.info("  config :mob_dev,")
    shell.info("    google_play: [")
    shell.info("      package_name:         \"#{package_name}\",")
    shell.info("      service_account_json: \"#{key_path}\",")
    shell.info("      track:                \"internal\"")
    shell.info("    ]")
    shell.info("")

    unless dry? do
      shell.info("Then run: mix mob.republish --android")
      shell.info("")
    end
  end

  # ── Prompts ──────────────────────────────────────────────────────────────────

  defp prompt_package_name(shell, true = _dry?) do
    shell.info("The Android package name is your applicationId (e.g. com.example.myapp).")
    shell.info("Find it in android/app/build.gradle under defaultConfig.applicationId.")
    shell.info("")
    shell.info(dry_tag() <> " [auto] Using placeholder: com.example.myapp")
    "com.example.myapp"
  end

  defp prompt_package_name(shell, false) do
    shell.info("The Android package name is your applicationId (e.g. com.example.myapp).")
    shell.info("Find it in android/app/build.gradle under defaultConfig.applicationId.")
    shell.info("")
    String.trim(shell.prompt("Package name (applicationId): "))
  end

  defp default_key_filename(package_name) do
    package_name
    |> String.split(".")
    |> List.last()
    |> Kernel.<>("-service-account")
  end

  # ── Logging helpers ──────────────────────────────────────────────────────────

  defp log_step(shell, n, label, dry?) do
    shell.info("")
    prefix = if dry?, do: yellow() <> "[dry run] " <> reset(), else: cyan()
    shell.info(prefix <> "── Step #{n}: #{label} ──" <> reset())
    :ok
  end

  defp dry_tag, do: yellow() <> "[dry run]" <> reset()

  defp green, do: IO.ANSI.green()
  defp cyan, do: IO.ANSI.cyan()
  defp yellow, do: IO.ANSI.yellow()
  defp reset, do: IO.ANSI.reset()
end
