defmodule MobDev.Plugin.SelfTest do
  @moduledoc """
  Runs every activated plugin's `Mob.Plugin.SelfTest` on a device.

  A plugin declares `selftest: Module` in its manifest; `run_all/3` calls
  `Module.run/1` on the device's node, one plugin at a time, and returns one
  entry per activated plugin. `mix mob.selftest` prints those as a table;
  mob_ci records them per nightly cell (invariant P12).

  The entry's `:result` is always one of the contract's three shapes:

    * `:pass`
    * `{:fail, reason}` — also what a self-test that raised, exited, threw,
      timed out, is not on the device or returned something outside the
      contract gets, and what a plugin whose manifest failed signature
      verification gets. The reason says which.
    * `{:skip, :needs_hardware | :needs_user | reason}` — including plugins
      with no `selftest:` in their manifest (`module: nil`), so a plugin
      without one is visible, not silently absent.

  Permissions are not granted here: the node is already running, and on an
  iOS simulator a privacy change can terminate the app. Callers grant
  **before** launching the app with `grant_permissions/4`, as
  `mix mob.selftest` does.
  """

  alias MobDev.Device

  @default_timeout_ms 30_000

  @typedoc "What a self-test is told about where it runs (`Mob.Plugin.SelfTest.ctx/0`)."
  @type ctx :: %{platform: :ios | :android, device: :simulator | :emulator | :physical}

  @typedoc "One plugin's outcome. `:ms` is the wall time of the call on the host."
  @type entry :: %{plugin: atom(), module: module() | nil, result: term(), ms: non_neg_integer()}

  @typedoc """
  An activated plugin as `MobDev.Plugin.activated_with_verify/0` (3-tuple) or
  `activated/0` (2-tuple) lists them; the first element is the plugin's name
  or its dependency directory.
  """
  @type plugin :: {atom() | Path.t(), map() | nil} | {atom() | Path.t(), map() | nil, term()}

  @typedoc "A granted (or attempted) permission."
  @type grant :: %{plugin: atom(), permission: String.t(), status: :ok | {:error, String.t()}}

  @doc """
  Runs the self-test of every activated plugin on `node` and returns an entry per plugin.

  Options:

    * `:plugins` — `t:plugin/0` list (default:
      `MobDev.Plugin.activated_with_verify/0`, read from the host project's
      `mob.exs` and deps). A plugin whose manifest failed verification is a
      `{:fail, _}` entry; one with no manifest (tier 0) is a skip.
    * `:timeout_ms` — per self-test (default #{@default_timeout_ms}). A test
      still running at the deadline is killed on the device, so the next
      plugin's test never runs beside it.
    * `:boot_timeout_ms` — how long to wait for the plugins' OTP applications
      to be started on the node before the first test (default 15000). mob
      starts them after the node is up, so a run right after a relaunch
      would otherwise test a plugin whose supervisor is not there yet. A
      plugin whose application never starts is tested anyway and reports it.
  """
  @spec run_all(node(), ctx(), keyword()) :: [entry()]
  def run_all(node, %{platform: _, device: _} = ctx, opts \\ []) do
    plugins = Keyword.get_lazy(opts, :plugins, &MobDev.Plugin.activated_with_verify/0)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    await_applications(node, plugins, Keyword.get(opts, :boot_timeout_ms, 15_000))
    for plugin <- plugins, do: run_one(node, plugin, ctx, timeout)
  end

  defp await_applications(node, plugins, remaining) do
    wanted = for {_, %{name: name}} <- manifests(plugins), is_atom(name), do: name

    started =
      try do
        :erpc.call(node, Application, :started_applications, [], 5_000) |> Enum.map(&elem(&1, 0))
      catch
        _, _ -> wanted
      end

    cond do
      wanted -- started == [] ->
        :ok

      remaining <= 0 ->
        :ok

      true ->
        Process.sleep(250)
        await_applications(node, plugins, remaining - 250)
    end
  end

  defp run_one(node, {name_or_dir, manifest}, ctx, timeout),
    do: run_one(node, {name_or_dir, manifest, :ok}, ctx, timeout)

  defp run_one(_node, {name_or_dir, nil, {:error, reason}}, _ctx, _timeout) do
    entry(name_or_dir, nil, nil, {:fail, "manifest failed verification: #{inspect(reason)}"}, 0)
  end

  defp run_one(_node, {name_or_dir, nil, _status}, _ctx, _timeout),
    do: entry(name_or_dir, nil, nil, {:skip, "no manifest (tier-0 plugin)"}, 0)

  defp run_one(node, {name_or_dir, manifest, _status}, ctx, timeout) do
    case Map.get(manifest, :selftest) do
      nil ->
        entry(name_or_dir, manifest, nil, {:skip, "no selftest in manifest"}, 0)

      module when is_atom(module) ->
        {ms, result} = timed(fn -> call(node, module, ctx, timeout) end)
        entry(name_or_dir, manifest, module, result, ms)

      other ->
        entry(
          name_or_dir,
          manifest,
          nil,
          {:fail, "selftest is not a module: #{inspect(other)}"},
          0
        )
    end
  end

  defp entry(name_or_dir, manifest, module, result, ms),
    do: %{plugin: plugin_name(name_or_dir, manifest), module: module, result: result, ms: ms}

  # The remote run/1 is spawned the way `:erpc.call/5` spawns it (its
  # `execute_call/4` reports the return or the exception as the exit reason)
  # but with the pid in hand, so a test that overruns the deadline is killed
  # instead of abandoned. Every way it can go wrong lands here as {:fail, why},
  # so a broken self-test never takes the runner, or the next plugin's run, down.
  defp call(node, module, ctx, timeout) do
    ref = make_ref()

    req =
      :erlang.spawn_request(node, :erpc, :execute_call, [ref, module, :run, [ctx]], [
        :monitor,
        {:reply, :yes}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout

    receive do
      {:spawn_reply, ^req, :ok, pid} ->
        await(req, pid, ref, module, node, deadline, timeout)

      {:spawn_reply, ^req, :error, reason} ->
        {:fail, "could not spawn on #{node}: #{inspect(reason)}"}
    after
      timeout ->
        # A spawn that lands after the deadline must not run beside the
        # next plugin's test, nor leave its reply and :DOWN in the mailbox.
        unless :erlang.spawn_request_abandon(req) do
          receive do
            {:spawn_reply, ^req, :ok, pid} -> Process.exit(pid, :kill)
            {:spawn_reply, ^req, :error, _} -> :ok
          after
            0 -> :ok
          end
        end

        Process.demonitor(req, [:flush])
        {:fail, "no answer from #{node} in #{timeout} ms"}
    end
  end

  defp await(req, pid, ref, module, node, deadline, timeout) do
    receive do
      {:DOWN, ^req, :process, ^pid, reason} -> normalize(reason, ref, module, node)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^req, :process, ^pid, _} -> :ok
        after
          1_000 -> Process.demonitor(req, [:flush])
        end

        {:fail, "timed out after #{timeout} ms"}
    end
  end

  # The exit reasons `:erpc.execute_call/4` produces, plus the signals.
  defp normalize({ref, :return, value}, ref, module, _node), do: contract(value, module)

  defp normalize({ref, :throw, value}, ref, _module, _node),
    do: {:fail, "threw: #{inspect(value, limit: 20)}"}

  defp normalize({ref, :exit, reason}, ref, _module, _node),
    do: {:fail, "exited: #{inspect(reason, limit: 20)}"}

  defp normalize({ref, :error, :undef, [{module, :run, [_], _} | _]}, ref, module, _node),
    do:
      {:fail,
       "#{inspect(module)}.run/1 is not on the device (deployed before the self-test was added?)"}

  defp normalize({ref, :error, reason, stack}, ref, _module, _node),
    do: {:fail, "raised: " <> format_exception(reason, stack)}

  defp normalize({ref, :error, {:erpc, reason}}, ref, _module, _node),
    do: {:fail, "erpc failed: #{inspect(reason)}"}

  defp normalize(:noconnection, _ref, _module, node), do: {:fail, "node #{node} is not reachable"}

  defp normalize(reason, _ref, _module, _node),
    do: {:fail, "killed: #{inspect(reason, limit: 20)}"}

  defp format_exception(reason, stack) do
    exception = Exception.normalize(:error, reason, stack)
    banner = Exception.format_banner(:error, exception, stack)

    case stack do
      [frame | _] -> banner <> " at " <> Exception.format_stacktrace_entry(frame)
      [] -> banner
    end
  end

  # The contract (`Mob.Plugin.SelfTest.result?/1`), restated here so the
  # runner does not need mob at runtime.
  defp contract(:pass, _module), do: :pass
  defp contract({:fail, reason} = fail, _module) when is_binary(reason), do: fail

  defp contract({:skip, reason} = skip, _module) when reason in [:needs_hardware, :needs_user],
    do: skip

  defp contract({:skip, reason} = skip, _module) when is_binary(reason), do: skip

  defp contract(other, module),
    do:
      {:fail,
       "#{inspect(module)}.run/1 returned #{inspect(other, limit: 20)}, " <>
         "not :pass | {:fail, reason} | {:skip, reason}"}

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp plugin_name(_name_or_dir, %{name: name})
       when is_atom(name) and not is_nil(name) and name != false,
       do: name

  defp plugin_name(name, _manifest) when is_atom(name), do: name

  defp plugin_name(dir, _manifest) when is_binary(dir),
    do: dir |> Path.basename() |> String.to_atom()

  # ── permissions ───────────────────────────────────────────────────────────

  # `xcrun simctl privacy` services for the capability atoms manifests declare
  # under `permissions: [%{capability: ...}]`. Capabilities with no service
  # (bluetooth, notifications, speech, ...) cannot be pre-granted on a
  # simulator; their self-tests skip with :needs_user if a prompt would block.
  @simctl_services %{
    location: "location",
    microphone: "microphone",
    photo_library: "photos",
    photos: "photos",
    media: "media-library",
    contacts: "contacts",
    calendar: "calendar",
    reminders: "reminders",
    motion: "motion"
  }

  @doc """
  Grants the permissions the plugins' manifests declare to `bundle_id` on
  `device`, so self-tests do not hit a system prompt. Call it **before**
  launching the app: a simulator may terminate a running app whose privacy
  settings change.

    * Android emulator: each `android.permissions` entry via
      `adb -s <serial> shell pm grant`. Only runtime permissions are
      grantable; a normal or signature permission answers with an error,
      which is recorded, not raised.
    * iOS simulator: each `permissions: [%{capability: cap}]` whose
      capability maps to a `simctl privacy` service.
    * Physical devices: nothing is granted (returns `[]`); a self-test that
      needs a permission the user has not given skips with `:needs_user`.

  Returns one `t:grant/0` per attempt. `cmd` is `fn exe, argv -> {output, status} end`.
  """
  @spec grant_permissions(
          Device.t(),
          [plugin()],
          String.t(),
          (String.t(), [String.t()] -> {String.t(), integer()})
        ) :: [grant()]
  def grant_permissions(
        %Device{platform: :android, type: :emulator, serial: serial},
        plugins,
        bundle_id,
        cmd
      ) do
    for {plugin, perm} <- android_permissions(plugins) do
      {out, status} = cmd.("adb", ["-s", serial, "shell", "pm", "grant", bundle_id, perm])
      %{plugin: plugin, permission: perm, status: status(out, status)}
    end
  end

  def grant_permissions(
        %Device{platform: :ios, type: :simulator, serial: udid},
        plugins,
        bundle_id,
        cmd
      ) do
    for {plugin, service} <- simctl_services(plugins) do
      {out, status} = cmd.("xcrun", ["simctl", "privacy", udid, "grant", service, bundle_id])
      %{plugin: plugin, permission: service, status: status(out, status)}
    end
  end

  def grant_permissions(%Device{}, _plugins, _bundle_id, _cmd), do: []

  @doc false
  @spec android_permissions([plugin()]) :: [{atom(), String.t()}]
  def android_permissions(plugins) do
    for {name_or_dir, %{} = manifest} <- manifests(plugins),
        perm <- get_in(manifest, [:android, :permissions]) || [],
        is_binary(perm),
        do: {plugin_name(name_or_dir, manifest), perm}
  end

  @doc false
  @spec simctl_services([plugin()]) :: [{atom(), String.t()}]
  def simctl_services(plugins) do
    for {name_or_dir, %{} = manifest} <- manifests(plugins),
        %{capability: cap} <- Map.get(manifest, :permissions) || [],
        service = Map.get(@simctl_services, cap),
        do: {plugin_name(name_or_dir, manifest), service}
  end

  defp manifests(plugins) do
    Enum.map(plugins, fn
      {name_or_dir, manifest} -> {name_or_dir, manifest}
      {name_or_dir, manifest, _status} -> {name_or_dir, manifest}
    end)
  end

  defp status(_out, 0), do: :ok
  defp status(out, _status), do: {:error, out |> String.trim() |> String.slice(0, 200)}

  # ── reporting ─────────────────────────────────────────────────────────────

  @doc """
  The table `mix mob.selftest` prints for one device: a header plus one
  line per entry, `plugin  outcome  ms  detail`.
  """
  @spec table([entry()]) :: [String.t()]
  def table(entries) do
    rows = [["plugin", "outcome", "ms", "detail"] | Enum.map(entries, &row/1)]

    widths =
      Enum.zip_with(rows, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    for row <- rows do
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end
  end

  defp row(%{plugin: plugin, result: result, ms: ms}) do
    {outcome, detail} = describe(result)
    [to_string(plugin), outcome, to_string(ms), detail]
  end

  defp describe(:pass), do: {"pass", ""}
  defp describe({:fail, reason}), do: {"FAIL", reason}
  defp describe({:skip, reason}) when is_atom(reason), do: {"skip", to_string(reason)}
  defp describe({:skip, reason}), do: {"skip", reason}

  @doc "The entries whose result is `{:fail, _}`."
  @spec failures([entry()]) :: [entry()]
  def failures(entries), do: Enum.filter(entries, &match?(%{result: {:fail, _}}, &1))

  @doc "One line: `N passed, N failed, N skipped`."
  @spec summary([entry()]) :: String.t()
  def summary(entries) do
    counts = Enum.frequencies_by(entries, &outcome/1)

    "#{Map.get(counts, :pass, 0)} passed, #{Map.get(counts, :fail, 0)} failed, " <>
      "#{Map.get(counts, :skip, 0)} skipped"
  end

  defp outcome(%{result: :pass}), do: :pass
  defp outcome(%{result: {:fail, _}}), do: :fail
  defp outcome(%{result: {:skip, _}}), do: :skip
end
