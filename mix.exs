defmodule MobDev.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_dev,
      version: "0.4.0",
      elixir: "~> 1.19",
      description: "Development tooling for the Mob mobile framework",
      source_url: "https://github.com/genericjam/mob_dev",
      compilers: compilers(Mix.env()) ++ Mix.compilers(),
      deps: deps(),
      package: package(),
      docs: docs(),
      unused: [
        ignore: [
          # GenServer / behaviour callbacks (mix_unused can't see callbacks).
          {:_, :init, 1},
          {:_, :handle_call, 3},
          {:_, :handle_cast, 2},
          {:_, :handle_info, 2},
          {:_, :handle_continue, 2},
          {:_, :terminate, 2},
          {:_, :code_change, 3},
          {:_, :format_status, 1},
          # Mix task entry points are dispatched by name.
          {~r/^Mix\.Tasks\..+$/, :run, 1},
          # Public API surface intended for downstream apps + IEx exploration —
          # these are documented entry points, even when no internal caller
          # references them.
          {~r/^MobDev\.GooglePlay\..+$/, :_, :_},
          {~r/^MobDev\.Server\..+$/, :_, :_},
          # Test helpers exposed via @doc false for diagnosis.
          {~r/^MobDev\..+/, :__test_only__, :_}
        ]
      ]
    ]
  end

  # `:unused` only runs in dev. Adding it to test or prod compile would
  # spam the test output and slow CI for no benefit (test fixtures
  # legitimately have unused public functions).
  # mix_unused 0.4.1 uses :re.import/1 which was removed in OTP 28, so
  # skip it there until a compatible release is available.
  defp compilers(:dev) do
    if String.to_integer(System.otp_release()) >= 28, do: [], else: [:unused]
  end

  defp compilers(_), do: []

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:eqrcode, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:mix_audit, "~> 2.1", runtime: false},
      {:avatarz, "~> 0.2", optional: true},
      {:image, "~> 0.54", optional: true},
      # Dev server
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.0"},
      {:plug_crypto, "~> 2.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:erlfmt, "~> 1.8", only: :dev, runtime: false},
      # Dev-only dead-code detector. Wires in via the `:unused` compiler
      # tracer; ignore list maintained inline below since this codebase has
      # legitimate dynamic dispatch (NIF on_load stubs, GenServer
      # callbacks, behaviour implementations).
      {:mix_unused, "~> 0.4", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/genericjam/mob_dev",
      source_url_pattern: "https://github.com/genericjam/mob_dev/blob/main/%{path}#L%{line}",
      extras: [
        "README.md": [title: "mob_dev"],
        "build_release.md": [title: "Building OTP Release Tarballs"],
        "guides/security_scan.md": [title: "Security scanning"],
        "guides/slim_release.md": [title: "Slim Release (bundle size)"],
        "guides/publishing_to_testflight.md": [title: "Publishing to TestFlight (iOS)"],
        "guides/publishing_to_google_play.md": [title: "Publishing to Google Play (Android)"],
        "guides/python_embedding.md": [title: "Embedded CPython (iOS)"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Mix Tasks": ~r/Mix\.Tasks\./,
        Server: ~r/MobDev\.Server/,
        Internals: ~r/MobDev/
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/genericjam/mob_dev"}
    ]
  end
end
