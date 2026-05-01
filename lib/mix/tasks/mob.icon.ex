defmodule Mix.Tasks.Mob.Icon do
  use Mix.Task

  @shortdoc "Generate or regenerate app icons"

  @moduledoc """
  Generates platform icons for the current Mob project.

  Must be run from the project root (the directory containing `mix.exs`).

      mix mob.icon                              # random robot avatar
      mix mob.icon --source PATH                # resize an existing image
      mix mob.icon --source PATH --adaptive     # also emit adaptive Android icons
      mix mob.icon --source PATH --adaptive --adaptive-bg "#E8B53C"

  ## Output

  Writes icons into the current project directory:

    - `android/app/src/main/res/mipmap-*/ic_launcher.png` (legacy)
    - `ios/Assets.xcassets/AppIcon.appiconset/icon_*.png`
    - `ios/Assets.xcassets/AppIcon.appiconset/Contents.json`
    - `icon_source.png` (1024×1024 master, only when generating)

  With `--adaptive`, also writes:

    - `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
    - `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml`
    - `android/app/src/main/res/mipmap-*/ic_launcher_foreground.png`
    - `android/app/src/main/res/values/ic_launcher_background.xml`

  Adaptive icons are what modern Android launchers (Pixel, Samsung, Moto…)
  expect: a foreground layer + a background colour, masked by the launcher
  to whatever shape it prefers (circle, squircle, teardrop). Without them,
  legacy icons get shrunk inside a launcher-supplied white circle.

  ## Under the hood

  `mix mob.icon` uses the `image` Elixir library (backed by `libvips`) to
  resize a 1024×1024 source PNG into every required platform size.

  No external tools (ImageMagick, Xcode, etc.) are required — `libvips` is
  bundled as a precompiled NIF via the `image` dependency.
  """

  @switches [source: :string, adaptive: :boolean, adaptive_bg: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)

    project_dir = File.cwd!()

    unless File.exists?(Path.join(project_dir, "mix.exs")) do
      Mix.raise("No mix.exs found. Run mix mob.icon from your project root.")
    end

    source =
      case opts[:source] do
        nil ->
          Mix.shell().info("Generating random robot icon...")
          MobDev.IconGenerator.generate_random(project_dir)
          Path.join(project_dir, "icon_source.png")

        source ->
          unless File.exists?(source) do
            Mix.raise("Source file not found: #{source}")
          end

          Mix.shell().info("Resizing icon from #{source}...")
          MobDev.IconGenerator.generate_from_source(source, project_dir)
          source
      end

    if opts[:adaptive] do
      Mix.shell().info("Generating adaptive Android icons...")
      adaptive_opts = if opts[:adaptive_bg], do: [background_color: opts[:adaptive_bg]], else: []
      MobDev.IconGenerator.generate_adaptive(source, project_dir, adaptive_opts)
    end

    Mix.shell().info("Icons written to #{project_dir}")
    Mix.shell().info("  Android: android/app/src/main/res/mipmap-*/ic_launcher.png")

    if opts[:adaptive] do
      Mix.shell().info("  Android (adaptive): mipmap-anydpi-v26/, ic_launcher_foreground.png, values/ic_launcher_background.xml")
    end

    Mix.shell().info("  iOS:     ios/Assets.xcassets/AppIcon.appiconset/")
  end
end
