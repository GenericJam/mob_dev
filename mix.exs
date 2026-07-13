defmodule MobDev.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_dev,
      version: "0.6.23",
      elixir: "~> 1.19",
      description: "Development tooling for the Mob mobile framework",
      source_url: "https://github.com/genericjam/mob_dev",
      compilers: compilers(Mix.env()) ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
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

  # Include test/support/ in test compile so Mox definitions etc. are
  # available without manually requiring them.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:eqrcode, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:mix_audit, "~> 2.1", runtime: false},
      {:avatarz, "~> 0.2", optional: true},
      # Pulls in sweet_xml ~> 0.7 transitively (via vix). sweet_xml
      # surfaces a 1.20-rc.4 type-checker warning at lib/sweet_xml.ex:246
      # (`%SweetXpath{xpath | ...}` without a preceding pattern match
      # against `%SweetXpath{}`). Cosmetic, in their code, doesn't
      # affect runtime. Remove this note when sweet_xml ships a fix
      # OR when image stops depending on it.
      {:image, "~> 0.54", optional: true},
      # Dev server
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.0"},
      {:plug_crypto, "~> 2.0"},
      # Igniter — AST-aware code generation. Used by `mix mob.add_nif` and
      # (planned) the LV generator to manipulate user mix.exs / mob.exs /
      # generated modules without regex-patching Elixir source. Phase 3 of
      # the build-system migration.
      {:igniter, "~> 0.8"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # ex_slop — Credo plugin that catches AI-generated Elixir
      # patterns (blanket rescue, narrator-style docs, redundant
      # Enum chains, etc). Plugged into the existing Credo run.
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      # ex_dna — semantic code duplication detector. Catches Type I/II/III
      # clones (exact, renamed-var, near-miss). Runs as a Credo check or
      # standalone Mix task. Useful for keeping parallel-agent work from
      # drifting into duplicate implementations of the same idea.
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      # reach — program dependence graph + architecture analysis. Mix
      # tasks `reach.map`, `reach.inspect`, `reach.trace`, `reach.check`,
      # `reach.otp` plus an HTML report. Useful for validating the
      # cross-package layering (mob_dev tasks shouldn't be reachable
      # from runtime code, etc).
      {:reach, "~> 2.3", only: [:dev, :test], runtime: false},
      # Mox — behaviour-based mocks for the MobDev.Release.* test suite.
      # Lets us test "given inputs, clang is invoked with these args"
      # without actually running clang.
      {:mox, "~> 1.2", only: :test},
      {:erlfmt, "~> 1.8", only: :dev, runtime: false},
      # Dev-only dead-code detector. Wires in via the `:unused` compiler
      # tracer; ignore list maintained inline below since this codebase has
      # legitimate dynamic dispatch (NIF on_load stubs, GenServer
      # callbacks, behaviour implementations).
      #
      # Known Elixir 1.20-rc.4 warnings from this dep (cosmetic, dev-only):
      #   - lib/mix_unused/filter.ex:61 — `_.._ inside match is deprecated`
      #     (range without explicit step, deprecated in 1.20).
      #   - 0.4.1 uses :re.import/1 which was removed in OTP 28 (see the
      #     compilers/1 gate below — we skip the :unused tracer on OTP
      #     ≥ 28 to dodge that runtime crash).
      # When mix_unused ships a release covering both, bump this version
      # and remove the compilers/1 OTP gate.
      {:mix_unused, "~> 0.4", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/genericjam/mob_dev",
      source_url_pattern: "https://github.com/genericjam/mob_dev/blob/master/%{path}#L%{line}",
      extras: [
        "README.md": [title: "mob_dev"],
        "CHANGELOG.md": [title: "Changelog"],
        "build_release.md": [title: "Building OTP Release Tarballs"],
        "guides/nifs.md": [title: "Static NIFs (C, Rust, Zig, Python)"],
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
