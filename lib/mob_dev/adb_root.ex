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
  `{:error, message}` if adbd restarted but the device didn't come back within
  the timeout. Waits only when adb reports it is restarting adbd.

  Options: `:runner` (see `t:runner/0`), `:timeout_ms`.
  """
  @spec root(String.t(), keyword()) :: :rooted | :not_rooted | {:error, String.t()}
  def root(serial, opts \\ []) do
    runner = Keyword.get(opts, :runner, &system_adb/1)

    case runner.(["-s", serial, "root"]) do
      {out, 0} ->
        cond do
          out =~ "already running as root" -> :rooted
          out =~ "restarting" -> with :ok <- wait_for_device(serial, opts), do: :rooted
          true -> :not_rooted
        end

      _ ->
        :not_rooted
    end
  end

  @doc """
  Waits until `serial` is listed again and answers a shell round trip with
  `sys.boot_completed` = 1, after anything that restarts adbd (`adb root`,
  `adb unroot`, `adb remount`). Same options as `root/2`.
  """
  @spec wait_for_device(String.t(), keyword()) :: :ok | {:error, String.t()}
  def wait_for_device(serial, opts \\ []) do
    runner = Keyword.get(opts, :runner, &system_adb/1)
    timeout = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.async(fn ->
        runner.(["-s", serial, "wait-for-device"])
        poll_ready(runner, serial, deadline)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      _ -> {:error, timeout_message(serial, timeout)}
    end
  end

  defp poll_ready(runner, serial, deadline) do
    case runner.(["-s", serial, "shell", "getprop sys.boot_completed; echo ok"]) do
      {out, 0} ->
        if String.trim(out) =~ ~r/\A1\s+ok\z/, do: :ok, else: retry(runner, serial, deadline)

      _ ->
        retry(runner, serial, deadline)
    end
  end

  defp retry(runner, serial, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      Process.sleep(@poll_ms)
      poll_ready(runner, serial, deadline)
    end
  end

  defp timeout_message(serial, timeout) do
    "Android device #{serial} did not come back within #{timeout} ms after adbd restarted " <>
      "(adb root). Raise MOB_ADB_RESTART_TIMEOUT_MS if the host is heavily loaded."
  end

  @doc false
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
