defmodule MobDev.Bench.Probe do
  @moduledoc """
  Multi-source state probe for the battery bench.

  When a battery read fails, we want to know *why*: is the BEAM dead, just
  unreachable, suspended in the background? The probe walks a short pipeline
  of network checks and returns a typed state. The bench uses this to
  produce informative trace lines and decide whether to attempt reconnection.

  ## State derivation

      epmd_reachable?  Node.connect  rpc_ping        →  state
      ──────────────  ─────────────  ──────────────     ─────
      false           —              —                  :unreachable
      true            false          —                  :alive_epmd_only
      true            true           timeout            :alive_dist_only
      true            true           ok                 :alive_rpc

  When a `hw_udid` is provided and `ideviceinfo` is available, we additionally
  probe USB battery readiness:

      ideviceinfo battery → :usb_ok | :usb_failed | :no_usb

  And app-process liveness via `xcrun devicectl device info processes`:

      app_pid_alive?  →  :app_running | :app_dead | :app_unknown

  All probes are independent and failure-tolerant — any single probe failing
  doesn't crash the whole snapshot.
  """

  defstruct [
    :ts_ms,
    :reachability,
    :app_process,
    :usb,
    :screen,
    :battery_pct,
    :reason
  ]

  @typedoc """
  - `:alive_rpc` — RPC just succeeded; BEAM is fully responsive
  - `:alive_dist_only` — Node.connect works, RPC times out (suspended?)
  - `:alive_epmd_only` — TCP to EPMD works, dist refused (BEAM up but no dist)
  - `:unreachable` — Phone offline or BEAM dead
  """
  @type reachability :: :alive_rpc | :alive_dist_only | :alive_epmd_only | :unreachable

  @typedoc "Foreground/background/dead, or unknown if we can't tell."
  @type app_process :: :app_running | :app_suspended | :app_dead | :app_unknown

  @typedoc "USB battery readiness via ideviceinfo."
  @type usb :: :usb_ok | :usb_failed | :no_usb

  @typedoc "Screen state, where derivable. `:unknown` is the honest default."
  @type screen :: :on | :off | :unknown

  @type t :: %__MODULE__{
          ts_ms: integer(),
          reachability: reachability(),
          app_process: app_process(),
          usb: usb(),
          screen: screen(),
          battery_pct: integer() | nil,
          reason: String.t() | nil
        }

  @doc """
  Run the full probe and return a populated state struct.

  Options:
  - `:node` — node atom to probe (required for dist/RPC checks)
  - `:host` — IP/host for EPMD probe (defaults to host portion of `:node`)
  - `:hw_udid` — hardware UDID for USB probe (optional)
  - `:device_id` — CoreDevice UUID for `devicectl` process check (optional)
  - `:app_pid` — process ID launched at bench start; checked against `device_id`
  - `:rpc_timeout_ms` — defaults to 2000
  - `:tcp_timeout_ms` — defaults to 1000
  - `:expected_screen` — `:on | :off | :unknown` — what we *believe* the
    screen state to be (e.g. after `lock_screen`). Recorded with the snapshot.
  """
  @spec snapshot(keyword()) :: t()
  def snapshot(opts \\ []) do
    ts = System.monotonic_time(:millisecond)
    node = Keyword.get(opts, :node)
    host = Keyword.get(opts, :host) || derive_host(node)

    rpc_timeout = Keyword.get(opts, :rpc_timeout_ms, 2_000)
    tcp_timeout = Keyword.get(opts, :tcp_timeout_ms, 1_000)

    reachability = probe_reachability(node, host, rpc_timeout, tcp_timeout)
    {battery_pct, rpc_reason} = probe_rpc_battery(reachability, node, rpc_timeout)
    {usb, usb_pct, usb_reason} = probe_usb(opts[:hw_udid])

    app_process =
      probe_app_process(opts[:device_id], opts[:app_pid], reachability)

    screen = derive_screen(opts[:expected_screen], reachability, usb)

    # Battery: prefer USB (more reliable), fall back to RPC, else nil.
    battery = usb_pct || battery_pct
    reason = rpc_reason || usb_reason

    %__MODULE__{
      ts_ms: ts,
      reachability: reachability,
      app_process: app_process,
      usb: usb,
      screen: screen,
      battery_pct: battery,
      reason: reason
    }
  end

  # ── Reachability pipeline ────────────────────────────────────────────────

  @doc false
  def probe_reachability(nil, _host, _rpc_timeout, _tcp_timeout), do: :unreachable

  def probe_reachability(_node, nil, _rpc_timeout, _tcp_timeout), do: :unreachable

  def probe_reachability(node, host, rpc_timeout, tcp_timeout) do
    cond do
      not tcp_open?(host, 4369, tcp_timeout) ->
        :unreachable

      not dist_connected?(node) ->
        :alive_epmd_only

      not rpc_responsive?(node, rpc_timeout) ->
        :alive_dist_only

      true ->
        :alive_rpc
    end
  end

  @doc false
  def tcp_open?(host, port, timeout_ms) when is_binary(host) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false],
           timeout_ms
         ) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  def tcp_open?(_, _, _), do: false

  @doc false
  def dist_connected?(node) when is_atom(node) do
    case Node.list() do
      list when is_list(list) -> node in list or node == Node.self()
      _ -> false
    end
  end

  @doc false
  def rpc_responsive?(node, timeout_ms) when is_atom(node) do
    case :rpc.call(node, :erlang, :node, [], timeout_ms) do
      n when is_atom(n) and n != :nonode@nohost -> true
      _ -> false
    end
  end

  # ── Battery via RPC ──────────────────────────────────────────────────────

  defp probe_rpc_battery(:alive_rpc, node, timeout_ms) do
    case :rpc.call(node, :mob_nif, :battery_level, [], timeout_ms) do
      n when is_integer(n) and n >= 0 and n <= 100 ->
        {n, nil}

      n when is_integer(n) ->
        {nil, "rpc battery: out-of-range #{n}"}

      {:badrpc, reason} ->
        {nil, "rpc battery: badrpc #{inspect(reason)}"}

      other ->
        {nil, "rpc battery: unexpected #{inspect(other)}"}
    end
  end

  defp probe_rpc_battery(_, _, _), do: {nil, nil}

  # ── USB probe ────────────────────────────────────────────────────────────

  defp probe_usb(nil), do: {:no_usb, nil, nil}

  defp probe_usb(hw_udid) when is_binary(hw_udid) do
    case System.find_executable("ideviceinfo") do
      nil ->
        {:no_usb, nil, nil}

      _path ->
        run_ideviceinfo(hw_udid)
    end
  end

  defp run_ideviceinfo(hw_udid) do
    case System.cmd(
           "ideviceinfo",
           ["-u", hw_udid, "-q", "com.apple.mobile.battery", "-k", "BatteryCurrentCapacity"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, _} when n in 0..100 -> {:usb_ok, n, nil}
          _ -> {:usb_failed, nil, "ideviceinfo: empty/unparsed output"}
        end

      {out, _} ->
        {:usb_failed, nil, "ideviceinfo: " <> String.trim(out)}
    end
  rescue
    e -> {:usb_failed, nil, "ideviceinfo raised: #{Exception.message(e)}"}
  end

  # ── App process probe ────────────────────────────────────────────────────

  # If RPC just succeeded, the app is definitely running (foreground or
  # background — RPC works in both). If RPC failed but EPMD is open, the
  # BEAM is alive but might be suspended. If both fail, the app might be
  # dead OR the phone is offline; need devicectl to disambiguate.

  defp probe_app_process(_device_id, _pid, :alive_rpc), do: :app_running

  defp probe_app_process(_device_id, _pid, :alive_dist_only), do: :app_suspended

  defp probe_app_process(nil, _pid, _), do: :app_unknown
  defp probe_app_process(_device_id, nil, _), do: :app_unknown

  defp probe_app_process(device_id, pid, _reachability) when is_integer(pid) do
    case System.find_executable("xcrun") do
      nil ->
        :app_unknown

      _ ->
        case System.cmd(
               "xcrun",
               [
                 "devicectl",
                 "device",
                 "info",
                 "processes",
                 "--device",
                 device_id,
                 "--pid",
                 to_string(pid)
               ],
               stderr_to_stdout: true
             ) do
          {out, 0} ->
            if String.contains?(out, to_string(pid)), do: :app_running, else: :app_dead

          _ ->
            :app_dead
        end
    end
  rescue
    _ -> :app_unknown
  end

  # ── Screen state ─────────────────────────────────────────────────────────

  # We don't have a clean USB-side iOS API for "is the screen on?". Best
  # signals available:
  #   - `:expected_screen` — what we believe based on our own lock action
  #   - If RPC works during a screen-off bench, the BEAM is awake even though
  #     the screen is locked — so screen state is independent of RPC state
  #
  # We honor the caller's expectation. Future: subscribe to Mob.Device's
  # protected_data_will_become_unavailable / available events via RPC for
  # ground-truth screen state.

  defp derive_screen(:on, _reachability, _usb), do: :on
  defp derive_screen(:off, _reachability, _usb), do: :off
  defp derive_screen(_, _, _), do: :unknown

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp derive_host(nil), do: nil

  defp derive_host(node) when is_atom(node) do
    case Atom.to_string(node) |> String.split("@", parts: 2) do
      [_, host] -> host
      _ -> nil
    end
  end

  @doc """
  Format the probe result as a one-line trace fragment.

      iex> probe = %MobDev.Bench.Probe{
      ...>   ts_ms: 0, reachability: :alive_rpc, app_process: :app_running,
      ...>   usb: :no_usb, screen: :off, battery_pct: 87, reason: nil
      ...> }
      iex> MobDev.Bench.Probe.format(probe)
      "screen:off app:running rpc:ok battery:87%"
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = p) do
    parts = [
      "screen:#{abbreviate_screen(p.screen)}",
      "app:#{abbreviate_app(p.app_process)}",
      reachability_short(p.reachability),
      battery_short(p.battery_pct)
    ]

    Enum.reject(parts, &(&1 == "")) |> Enum.join(" ")
  end

  defp abbreviate_screen(:on), do: "on"
  defp abbreviate_screen(:off), do: "off"
  defp abbreviate_screen(_), do: "?"

  defp abbreviate_app(:app_running), do: "running"
  defp abbreviate_app(:app_suspended), do: "suspended"
  defp abbreviate_app(:app_dead), do: "dead"
  defp abbreviate_app(_), do: "?"

  defp reachability_short(:alive_rpc), do: "rpc:ok"
  defp reachability_short(:alive_dist_only), do: "rpc:timeout"
  defp reachability_short(:alive_epmd_only), do: "rpc:no-dist"
  defp reachability_short(:unreachable), do: "rpc:unreachable"

  defp battery_short(nil), do: ""
  defp battery_short(pct), do: "battery:#{pct}%"
end
