defmodule Mix.Tasks.Mob.Emulators do
  use Mix.Task

  @shortdoc "List, start, and stop Android emulators / iOS simulators"

  @moduledoc """
  Manage virtual devices: Android emulators (AVDs) and iOS simulators.

  ## Examples

      mix mob.emulators                        # list all (default)
      mix mob.emulators --list                 # same as above
      mix mob.emulators --list --android       # Android only
      mix mob.emulators --list --ios           # iOS only

      mix mob.emulators --start --id Pixel_8_API_34
      mix mob.emulators --start --id 78354490

      mix mob.emulators --stop --id emulator-5554
      mix mob.emulators --stop --id 78354490
      mix mob.emulators --stop --all           # everything booted

  `--id` accepts the same display IDs `mix mob.devices` shows, plus AVD
  names. For Android the running serial (`emulator-5554`) also works.

  Out of scope: creating new AVDs or installing simulator runtimes — those
  involve license acceptance and multi-GB downloads. Use Android Studio /
  Xcode for that.
  """

  alias MobDev.{Device, Emulators}

  @switches [
    list: :boolean,
    start: :boolean,
    stop: :boolean,
    android: :boolean,
    ios: :boolean,
    id: :string,
    all: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    cond do
      opts[:start] -> do_start(opts)
      opts[:stop] -> do_stop(opts)
      true -> do_list(opts)
    end
  end

  # ── List ──────────────────────────────────────────────────────────────────

  defp do_list(opts) do
    # Both shown if neither flag specified, otherwise only the requested one(s).
    android? = Keyword.get(opts, :android, false)
    ios? = Keyword.get(opts, :ios, false)
    show_android = android? or (not android? and not ios?)
    show_ios = ios? or (not android? and not ios?)

    IO.puts("")

    if show_android do
      print_android_section()
      IO.puts("")
    end

    if show_ios do
      print_ios_section()
      IO.puts("")
    end
  end

  defp print_android_section do
    IO.puts("#{cyan()}Android emulators (AVDs)#{reset()}")

    case Emulators.list_android() do
      {:ok, []} ->
        IO.puts("  (no AVDs configured — create one in Android Studio)")

      {:ok, avds} ->
        Enum.each(avds, &print_avd/1)

      {:error, reason} ->
        IO.puts("  #{yellow()}#{reason}#{reset()}")
    end
  end

  defp print_ios_section do
    IO.puts("#{cyan()}iOS simulators#{reset()}")

    case Emulators.list_ios() do
      {:ok, sims} ->
        # Group by runtime and sort booted-first within each group.
        sims
        |> Enum.sort_by(&{&1.runtime, not &1.running, &1.name})
        |> Enum.each(&print_sim/1)

      {:error, reason} ->
        IO.puts("  #{yellow()}#{reason}#{reset()}")
    end
  end

  defp print_avd(%Emulators{platform: :android} = a) do
    dot = if a.running, do: "#{green()}●#{reset()}", else: "○"
    suffix = if a.running, do: " #{dim()}(running, #{a.serial})#{reset()}", else: ""
    IO.puts("  #{dot}  #{bold()}#{a.name}#{reset()}#{suffix}")
  end

  defp print_sim(%Emulators{platform: :ios} = s) do
    dot = if s.running, do: "#{green()}●#{reset()}", else: "○"
    state = if s.running, do: "booted, ", else: ""
    short_id = String.replace(s.id, "-", "") |> String.slice(0, 8) |> String.downcase()

    IO.puts(
      "  #{dot}  #{bold()}#{pad(s.name, 28)}#{reset()} #{s.runtime}  #{dim()}(#{state}#{short_id})#{reset()}"
    )
  end

  # ── Start ─────────────────────────────────────────────────────────────────

  defp do_start(opts) do
    id = opts[:id]

    if is_nil(id) do
      Mix.raise("--start requires --id <id>. See `mix mob.emulators --list` for IDs.")
    end

    case resolve(id) do
      {:android, %Emulators{name: avd_name, running: false}} ->
        IO.puts("Starting Android emulator: #{avd_name}")

        case Emulators.start_android(avd_name) do
          :ok ->
            IO.puts(
              "#{green()}Started.#{reset()} (boots in background — `adb wait-for-device` to block)"
            )

          {:error, reason} ->
            Mix.raise(reason)
        end

      {:android, %Emulators{name: avd_name, running: true, serial: serial}} ->
        IO.puts("Already running: #{avd_name} (#{serial})")

      {:ios, %Emulators{name: name, id: udid, running: false}} ->
        IO.puts("Booting iOS simulator: #{name}")

        case Emulators.start_ios(udid) do
          :ok -> IO.puts("#{green()}Booted.#{reset()}")
          {:error, reason} -> Mix.raise(reason)
        end

      {:ios, %Emulators{name: name, running: true}} ->
        IO.puts("Already booted: #{name}")

      :not_found ->
        Mix.raise("No emulator/simulator matched #{inspect(id)}. Run `mix mob.emulators --list`.")
    end
  end

  # ── Stop ──────────────────────────────────────────────────────────────────

  defp do_stop(opts) do
    cond do
      opts[:all] ->
        do_stop_all(opts)

      opts[:id] ->
        do_stop_one(opts[:id])

      true ->
        Mix.raise(
          "--stop needs either --id <id> or --all. " <>
            "Use --all to stop every running emulator/simulator."
        )
    end
  end

  defp do_stop_one(id) do
    case resolve(id) do
      {:android, %Emulators{running: true, serial: serial, name: name}} ->
        IO.puts("Stopping Android emulator: #{name} (#{serial})")

        case Emulators.stop_android(serial) do
          :ok -> IO.puts("#{green()}Stopped.#{reset()}")
          {:error, reason} -> Mix.raise(reason)
        end

      {:android, %Emulators{running: false, name: name}} ->
        IO.puts("Not running: #{name}")

      {:ios, %Emulators{running: true, id: udid, name: name}} ->
        IO.puts("Shutting down iOS simulator: #{name}")

        case Emulators.stop_ios(udid) do
          :ok -> IO.puts("#{green()}Stopped.#{reset()}")
          {:error, reason} -> Mix.raise(reason)
        end

      {:ios, %Emulators{running: false, name: name}} ->
        IO.puts("Not booted: #{name}")

      :not_found ->
        Mix.raise("No emulator/simulator matched #{inspect(id)}. Run `mix mob.emulators --list`.")
    end
  end

  defp do_stop_all(opts) do
    # Both shown if neither flag specified, otherwise only the requested one(s).
    android? = Keyword.get(opts, :android, false)
    ios? = Keyword.get(opts, :ios, false)
    show_android = android? or (not android? and not ios?)
    show_ios = ios? or (not android? and not ios?)

    running =
      []
      |> then(fn acc ->
        if show_android do
          case Emulators.list_android() do
            {:ok, avds} -> acc ++ Enum.filter(avds, & &1.running)
            _ -> acc
          end
        else
          acc
        end
      end)
      |> then(fn acc ->
        if show_ios do
          case Emulators.list_ios() do
            {:ok, sims} -> acc ++ Enum.filter(sims, & &1.running)
            _ -> acc
          end
        else
          acc
        end
      end)

    if running == [] do
      IO.puts("No running emulators or simulators.")
    else
      names = Enum.map_join(running, ", ", & &1.name)
      IO.puts("Stopping #{length(running)} running: #{names}")

      Enum.each(running, fn
        %Emulators{platform: :android, serial: serial, name: name} ->
          case Emulators.stop_android(serial) do
            :ok -> IO.puts("  #{green()}✓#{reset()} #{name}")
            {:error, reason} -> IO.puts("  #{red()}✗#{reset()} #{name}: #{reason}")
          end

        %Emulators{platform: :ios, id: udid, name: name} ->
          case Emulators.stop_ios(udid) do
            :ok -> IO.puts("  #{green()}✓#{reset()} #{name}")
            {:error, reason} -> IO.puts("  #{red()}✗#{reset()} #{name}: #{reason}")
          end
      end)
    end
  end

  # ── Resolution ────────────────────────────────────────────────────────────

  # Try Android first then iOS — they don't share id formats so collisions
  # are vanishingly rare. Match against the AVD name (Android), the running
  # adb serial (Android), the UDID (iOS), or the 8-char display id (iOS).
  defp resolve(id) do
    android_match =
      case Emulators.list_android() do
        {:ok, avds} -> Enum.find(avds, &android_id_match?(&1, id))
        _ -> nil
      end

    if android_match do
      {:android, android_match}
    else
      case Emulators.list_ios() do
        {:ok, sims} ->
          case Enum.find(sims, &ios_id_match?(&1, id)) do
            nil -> :not_found
            sim -> {:ios, sim}
          end

        _ ->
          :not_found
      end
    end
  end

  defp android_id_match?(%Emulators{name: name, serial: serial}, id) do
    String.downcase(name) == String.downcase(id) or
      (serial != nil and String.downcase(serial) == String.downcase(id))
  end

  defp ios_id_match?(%Emulators{id: udid}, id) do
    # Build a fake Device just to reuse Device.match_id?/2's "display_id or serial"
    # logic. Simulator display_id = first 8 hex chars of UDID with dashes removed.
    fake = %Device{platform: :ios, type: :simulator, serial: udid}
    Device.match_id?(fake, id)
  end

  # ── ANSI helpers ──────────────────────────────────────────────────────────

  defp cyan, do: IO.ANSI.cyan()
  defp green, do: IO.ANSI.green()
  defp yellow, do: IO.ANSI.yellow()
  defp red, do: IO.ANSI.red()
  defp bold, do: IO.ANSI.bright()
  defp dim, do: IO.ANSI.faint()
  defp reset, do: IO.ANSI.reset()

  defp pad(s, n) do
    pad_len = max(n - String.length(s), 0)
    s <> String.duplicate(" ", pad_len)
  end
end
