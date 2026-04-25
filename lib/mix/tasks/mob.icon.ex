defmodule Mix.Tasks.Mob.Icon do
  use Mix.Task

  @shortdoc "Generate or regenerate app icons"

  @moduledoc """
  Generates platform icons for the current Mob project.

  Must be run from the project root (the directory containing `mix.exs`).

      mix mob.icon                   # random robot avatar
      mix mob.icon --source PATH     # resize an existing image

  ## Output

  Writes icons into the current project directory:

    - `android/app/src/main/res/mipmap-*/ic_launcher.png`
    - `ios/Assets.xcassets/AppIcon.appiconset/icon_*.png`
    - `ios/Assets.xcassets/AppIcon.appiconset/Contents.json`
    - `icon_source.png` (1024×1024 master, only when generating)

  ## Under the hood

  `mix mob.icon` uses the `image` Elixir library (backed by `libvips`) to resize a
  1024×1024 source PNG into every required platform size:

      # Android (mipmap-mdpi through mipmap-xxxhdpi: 48px → 192px)
      Image.thumbnail(source, size) |> Image.write(dest)

      # iOS (20px → 1024px, all required AppIcon sizes)
      Image.thumbnail(source, size) |> Image.write(dest)
      # also writes Contents.json for Xcode

  No external tools (ImageMagick, Xcode, etc.) are required — `libvips` is
  bundled as a precompiled NIF via the `image` dependency.
  """

  @switches [source: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _} = OptionParser.parse(argv, strict: @switches)

    project_dir = File.cwd!()

    unless File.exists?(Path.join(project_dir, "mix.exs")) do
      Mix.raise("No mix.exs found. Run mix mob.icon from your project root.")
    end

    case opts[:source] do
      nil ->
        Mix.shell().info("Generating random robot icon...")
        MobDev.IconGenerator.generate_random(project_dir)

      source ->
        unless File.exists?(source) do
          Mix.raise("Source file not found: #{source}")
        end

        Mix.shell().info("Resizing icon from #{source}...")
        MobDev.IconGenerator.generate_from_source(source, project_dir)
    end

    Mix.shell().info("Icons written to #{project_dir}")
    Mix.shell().info("  Android: android/app/src/main/res/mipmap-*/ic_launcher.png")
    Mix.shell().info("  iOS:     ios/Assets.xcassets/AppIcon.appiconset/")
  end
end
