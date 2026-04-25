defmodule Mix.Tasks.Mob.WatchStop do
  use Mix.Task

  @shortdoc "Stop a running mix mob.watch process"

  @moduledoc """
  Stops a running `mix mob.watch` process.

      mix mob.watch_stop

  Reads the PID written by `mix mob.watch` and sends SIGTERM.

  ## Under the hood

      pid = File.read!("_build/mob_watch.pid") |> String.trim()
      System.cmd("kill", [pid])   # SIGTERM
      File.rm("_build/mob_watch.pid")

  Equivalent to running `kill $(cat _build/mob_watch.pid)` in a terminal.
  """

  @impl Mix.Task
  def run(_args) do
    pid_file = Mix.Tasks.Mob.Watch.pid_file()

    case File.read(pid_file) do
      {:ok, contents} ->
        pid = String.trim(contents)

        case System.cmd("kill", [pid], stderr_to_stdout: true) do
          {_, 0} ->
            File.rm(pid_file)
            IO.puts("#{IO.ANSI.green()}mob.watch stopped (pid #{pid})#{IO.ANSI.reset()}")

          {out, _} ->
            File.rm(pid_file)

            IO.puts(
              "#{IO.ANSI.yellow()}kill failed (process may have already exited): #{String.trim(out)}#{IO.ANSI.reset()}"
            )
        end

      {:error, _} ->
        IO.puts(
          "#{IO.ANSI.yellow()}mob.watch is not running (no PID file found)#{IO.ANSI.reset()}"
        )
    end
  end
end
