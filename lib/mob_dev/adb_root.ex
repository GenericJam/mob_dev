defmodule MobDev.AdbRoot do
  @moduledoc """
  `adb root` that waits for the adbd restart it causes.

  On a non-root adbd, `adb root` answers `restarting adbd as root` and drops
  the device's transport while adbd restarts. Under CPU load that restart takes
  seconds, so a fixed sleep races it and the next adb command fails with
  "device not found" / "Selected Android device(s) disconnected" (MOB-459).
  `root/2` instead waits with `adb -s <serial> wait-for-device` plus a
  `getprop sys.boot_completed` round trip, bounded by a timeout.

  The timeout defaults to 30 s; override it with the `MOB_ADB_RESTART_TIMEOUT_MS`
  environment variable, `config :mob_dev, adb_restart_timeout_ms: ms`, or the
  `:timeout_ms` option.
  """

  @default_timeout_ms 30_000
  @poll_ms 250

  @typedoc "Runs `adb` with the given args, returning `{output, exit_status}`."
  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @doc """
  Runs `adb -s <serial> root`.

  Returns `:rooted` once adbd runs as root and answers again, `:not_rooted` if
  the device refuses root (production builds) or adb fails, and
  `{:error, message}` if adbd restarted but the device didn't come back as
  root within the timeout. Waits unless adbd already runs as root or refuses
  it; adb sometimes prints nothing while it restarts adbd, so an empty reply
  waits too.

  Options: `:runner` (see `t:runner/0`), `:timeout_ms`.
  """
  @spec root(String.t(), keyword()) :: :rooted | :not_rooted | {:error, String.t()}
  def root(serial, opts \\ []) do
    runner = Keyword.get(opts, :runner, &system_adb/1)

    case runner.(["-s", serial, "root"]) do
      {out, 0} ->
        cond do
          out =~ "already running as root" ->
            :rooted

          # "restarting adbd as root", or nothing at all: adb can lose the
          # connection to the restarting adbd before it prints the reply.
          out =~ "restarting" or String.trim(out) == "" ->
            with :ok <- wait_for_device(serial, [{:uid, 0} | opts]), do: :rooted

          # "cannot run as root in production builds", LineageOS's "ADB Root
          # access is disabled by system setting", ...
          true ->
            :not_rooted
        end

      _ ->
        :not_rooted
    end
  end

  @doc """
  Waits until `serial` is listed again and answers a shell round trip with
  `sys.boot_completed` = 1, after anything that restarts adbd (`adb root`,
  `adb unroot`, `adb remount`). Same options as `root/2`, plus `:uid`: the
  shell uid the restarted adbd must report. The old adbd can still answer for
  a moment after `adb root` returns, so `root/2` passes `uid: 0` to tell the
  new adbd from the old one.
  """
  @spec wait_for_device(String.t(), keyword()) :: :ok | {:error, String.t()}
  def wait_for_device(serial, opts \\ []) do
    runner = Keyword.get(opts, :runner, &system_adb/1)
    timeout = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)
    deadline = System.monotonic_time(:millisecond) + timeout
    parent = self()

    # `adb wait-for-device` blocks until the serial is back, possibly forever
    # (an unplugged phone), and killing the task doesn't kill the OS process,
    # so the default runner reports its pid for the timeout to kill.
    wait =
      if Keyword.has_key?(opts, :runner),
        do: runner,
        else: &port_adb(&1, parent)

    task =
      Task.async(fn ->
        wait.(["-s", serial, "wait-for-device"])
        poll_ready(runner, serial, Keyword.get(opts, :uid), deadline)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        flush_os_pid()
        :ok

      _ ->
        kill_wait_process()
        {:error, timeout_message(serial, timeout)}
    end
  end

  defp kill_wait_process do
    receive do
      {:adb_wait_os_pid, os_pid} ->
        System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    after
      0 -> :ok
    end
  end

  defp flush_os_pid do
    receive do
      {:adb_wait_os_pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp port_adb(args, parent) do
    case System.find_executable("adb") do
      nil ->
        system_adb(args)

      adb ->
        port =
          Port.open({:spawn_executable, adb}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        with {:os_pid, os_pid} <- Port.info(port, :os_pid),
             do: send(parent, {:adb_wait_os_pid, os_pid})

        collect_port(port, "")
    end
  end

  defp collect_port(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_port(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    end
  end

  defp poll_ready(runner, serial, uid, deadline) do
    with {out, 0} <-
           runner.(["-s", serial, "shell", "getprop sys.boot_completed; id -u; echo ok"]),
         ["1", got_uid, "ok"] <- String.split(out),
         true <- uid == nil or got_uid == to_string(uid) do
      :ok
    else
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@poll_ms)
          poll_ready(runner, serial, uid, deadline)
        end
    end
  end

  defp timeout_message(serial, timeout) do
    "Android device #{serial} did not come back within #{timeout} ms after adbd restarted " <>
      "(adb root). Raise MOB_ADB_RESTART_TIMEOUT_MS if the host is heavily loaded."
  end

  @doc false
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    case System.get_env("MOB_ADB_RESTART_TIMEOUT_MS") do
      nil ->
        Application.get_env(:mob_dev, :adb_restart_timeout_ms, @default_timeout_ms)

      raw ->
        case Integer.parse(String.trim(raw)) do
          {ms, ""} when ms > 0 -> ms
          _ -> @default_timeout_ms
        end
    end
  end

  defp system_adb(args), do: System.cmd("adb", args, stderr_to_stdout: true)
end
