defmodule MobDev.Bench.Preflight do
  @moduledoc """
  Pre-run checklist for the iOS battery bench.

  Walks through the things that have to be right before locking the screen
  and running for 30 minutes. Each check returns `:ok | {:error, message}`.

  Goals:

  - Catch the misconfigurations that would invalidate a run *before* the run
    starts (saves ~30 min of wasted bench time).
  - Tell the user exactly what's wrong and how to fix it.
  - Be testable — each check is a pure function returning a tagged result.

  ## Checks performed

  1. **USB / hardware UDID** — at least one of: USB-connected device
     reachable via `idevice_id -l`, or a configured `:hw_udid`.
  2. **App installed** — bundle id appears in `xcrun devicectl device info apps`.
  3. **BEAM reachable** — Node.connect succeeds.
  4. **RPC responsive** — `rpc.call(node, :erlang, :node, [])` returns within
     2 seconds. Distinguishes "BEAM up but suspended" from "fully alive".
  5. **NIF version** — `mob_nif:battery_level/0` is exported. (Indicates the
     installed app build is recent enough.)
  6. **Background NIF** — `mob_nif:background_keep_alive/0` is exported.
     Required for screen-off bench mode.

  Each check is independent — failure in (3) doesn't skip (5); we run them
  all and report a complete picture.
  """

  alias MobDev.Bench.Probe

  @typedoc "Result for a single check."
  @type check_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Run all preflight checks and return a list of `{name, result}` tuples in
  the order they were run.

  Options:
  - `:node` — node atom (required for BEAM checks)
  - `:cookie` — cookie atom
  - `:bundle_id` — app bundle id
  - `:device_id` — devicectl identifier (CoreDevice UUID)
  - `:hw_udid` — hardware UDID for USB checks
  - `:host` — IP/host for EPMD (default: derive from node)
  - `:require_keep_alive` — boolean, default true (set false for screen-on bench)
  """
  @spec run(keyword()) :: [{atom(), check_result()}]
  def run(opts) do
    [
      {:hardware, check_hardware(opts)},
      {:app_installed, check_app_installed(opts)},
      {:beam_reachable, check_beam_reachable(opts)},
      {:rpc_responsive, check_rpc_responsive(opts)},
      {:nif_version, check_nif_version(opts)},
      {:keep_alive_nif,
       if(opts[:require_keep_alive] != false,
         do: check_keep_alive_nif(opts),
         else: {:ok, "skipped"}
       )}
    ]
  end

  @doc """
  Returns true if every result is `{:ok, _}`. Stricter overall check than
  examining individual results — useful for deciding whether to abort.
  """
  @spec all_ok?([{atom(), check_result()}]) :: boolean()
  def all_ok?(results) do
    Enum.all?(results, fn
      {_name, {:ok, _}} -> true
      _ -> false
    end)
  end

  @doc """
  Format the results as a multi-line string with ✓/✗ markers.
  """
  @spec pretty([{atom(), check_result()}]) :: String.t()
  def pretty(results) do
    Enum.map_join(results, "\n", fn
      {name, {:ok, msg}} -> "  ✓ #{format_name(name)} — #{msg}"
      {name, {:error, msg}} -> "  ✗ #{format_name(name)} — #{msg}"
    end)
  end

  defp format_name(name) do
    name |> Atom.to_string() |> String.replace("_", " ")
  end

  # ── Individual checks ────────────────────────────────────────────────────

  @doc false
  def check_hardware(opts) do
    cond do
      is_binary(opts[:hw_udid]) ->
        {:ok, "hardware UDID provided: #{opts[:hw_udid]}"}

      System.find_executable("idevice_id") ->
        case System.cmd("idevice_id", ["-l"], stderr_to_stdout: true) do
          {out, 0} ->
            udids =
              out
              |> String.split("\n")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            case udids do
              [] -> {:error, "no USB device detected (idevice_id -l returned empty)"}
              [_one] -> {:ok, "USB device connected"}
              many -> {:ok, "#{length(many)} USB devices connected"}
            end

          _ ->
            {:error, "idevice_id failed — is the device trusted?"}
        end

      true ->
        {:error,
         "no hw_udid given and idevice_id not installed " <>
           "(brew install libimobiledevice)"}
    end
  end

  @doc false
  def check_app_installed(opts) do
    bundle = opts[:bundle_id]
    device = opts[:device_id]

    cond do
      not is_binary(bundle) ->
        {:error, "bundle_id not configured"}

      not is_binary(device) ->
        # Without a device id, we can't query devicectl. Treat as informational.
        {:ok, "skipped (no device_id provided to verify)"}

      not System.find_executable("xcrun") ->
        {:ok, "skipped (xcrun unavailable)"}

      true ->
        case System.cmd(
               "xcrun",
               ["devicectl", "device", "info", "apps", "--device", device, "--bundle-identifier", bundle],
               stderr_to_stdout: true
             ) do
          {out, 0} ->
            if String.contains?(out, bundle) do
              {:ok, "#{bundle} found on device"}
            else
              {:error, "#{bundle} not installed on device — run `mix mob.deploy --native`"}
            end

          {out, _} ->
            {:error, "devicectl failed: #{String.trim(out) |> truncate()}"}
        end
    end
  end

  @doc false
  def check_beam_reachable(opts) do
    node = opts[:node]
    host = opts[:host] || derive_host(node)

    cond do
      not is_atom(node) or node == nil ->
        {:error, "no node provided"}

      not is_binary(host) ->
        {:error, "could not derive host from node #{inspect(node)}"}

      Probe.tcp_open?(host, 4369, 1500) ->
        {:ok, "EPMD reachable at #{host}:4369"}

      true ->
        {:error, "EPMD not reachable at #{host}:4369 — phone offline or BEAM dead"}
    end
  end

  @doc false
  def check_rpc_responsive(opts) do
    node = opts[:node]
    cookie = opts[:cookie]

    cond do
      not is_atom(node) or node == nil ->
        {:error, "no node provided"}

      true ->
        if is_atom(cookie), do: Node.set_cookie(node, cookie)

        case Node.connect(node) do
          true ->
            if Probe.rpc_responsive?(node, 2_000) do
              {:ok, "RPC ping returned in <2 s"}
            else
              {:error, "RPC ping timed out (BEAM may be suspended)"}
            end

          false ->
            {:error, "Node.connect/1 returned false — wrong cookie or dist down"}

          :ignored ->
            {:error, "Node.connect/1 returned :ignored — local node not started"}
        end
    end
  end

  @doc false
  def check_nif_version(opts) do
    check_nif_export(opts, :battery_level, "battery_level/0")
  end

  @doc false
  def check_keep_alive_nif(opts) do
    check_nif_export(opts, :background_keep_alive, "background_keep_alive/0")
  end

  defp check_nif_export(opts, fun_name, label) do
    node = opts[:node]

    case :rpc.call(node, :mob_nif, :module_info, [:exports], 2_000) do
      list when is_list(list) ->
        if Enum.any?(list, fn {f, _arity} -> f == fun_name end) do
          {:ok, "#{label} exported"}
        else
          {:error,
           "#{label} not exported on device — installed app is older than mob_dev expects"}
        end

      {:badrpc, reason} ->
        {:error, "could not query exports: #{inspect(reason)}"}

      other ->
        {:error, "unexpected exports result: #{inspect(other)}"}
    end
  end

  defp derive_host(nil), do: nil

  defp derive_host(node) when is_atom(node) do
    case Atom.to_string(node) |> String.split("@", parts: 2) do
      [_, host] -> host
      _ -> nil
    end
  end

  defp truncate(str) when is_binary(str) do
    if String.length(str) > 200, do: String.slice(str, 0, 200) <> "...", else: str
  end
end
