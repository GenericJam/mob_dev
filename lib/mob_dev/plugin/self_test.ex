defmodule MobDev.Plugin.SelfTest do
  @moduledoc """
  Runs every activated plugin's `Mob.Plugin.SelfTest` on a device.

  A plugin declares `selftest: Module` in its manifest; `run_all/3` calls
  `Module.run/1` on the device's node over `:erpc`, one plugin at a time,
  and returns one entry per activated plugin. `mix mob.selftest` prints
  those as a table; mob_ci records them per nightly cell (invariant P12).

  The entry's `:result` is always one of the contract's three shapes:

    * `:pass`
    * `{:fail, reason}` — also what a self-test that raised, exited, threw,
      timed out, is not on the device or returned something outside the
      contract gets. The reason says which.
    * `{:skip, :needs_hardware | :needs_user | reason}` — including plugins
      with no `selftest:` in their manifest (`module: nil`), so a plugin
      without one is visible, not silently absent.

  Before the first call, when `:device` names an emulator or simulator,
  the permissions the manifests declare are granted on the device
  (`adb shell pm grant`, `xcrun simctl privacy grant`), so a self-test
  reaches its native code without a system prompt. See `grant_permissions/4`.
  """

  alias MobDev.Device

  @default_timeout_ms 30_000

  @typedoc "What a self-test is told about where it runs (`Mob.Plugin.SelfTest.ctx/0`)."
  @type ctx :: %{platform: :ios | :android, device: :simulator | :emulator | :physical}

  @typedoc "One plugin's outcome. `:ms` is the wall time of the call on the host."
  @type entry :: %{plugin: atom(), module: module() | nil, result: term(), ms: non_neg_integer()}

  @typedoc "A granted (or attempted) permission."
  @type grant :: %{plugin: atom(), permission: String.t(), status: :ok | {:error, String.t()}}

  @doc """
  Runs the self-test of every activated plugin on `node` and returns an entry per plugin.

  Options:

    * `:plugins` — `[{name_or_dir, manifest | nil}]` as `MobDev.Plugin.activated/0`
      returns (the default, read from the host project's `mob.exs` and deps).
    * `:timeout_ms` — per self-test (default #{@default_timeout_ms}).
    * `:device` — the `MobDev.Device` the node runs on; emulators and simulators
      get the manifests' permissions granted first. `nil` grants nothing.
    * `:cmd` — `fn exe, argv -> {output, status} end` for the grant commands
      (default `System.cmd/2`).
    * `:bundle_id` — the app id to grant to (default `MobDev.Config` for the
      device's platform).
  """
  @spec run_all(node(), ctx(), keyword()) :: [entry()]
  def run_all(node, %{platform: _, device: _} = ctx, opts \\ []) do
    plugins = Keyword.get_lazy(opts, :plugins, &MobDev.Plugin.activated/0)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Keyword.get(opts, :device) do
      nil -> :ok
      device -> grant_permissions(device, plugins, bundle_id(opts, device), cmd(opts))
    end

    for {name_or_dir, manifest} <- plugins,
        plugin = plugin_name(name_or_dir, manifest),
        do: run_one(node, plugin, manifest, ctx, timeout)
  end

  defp run_one(_node, plugin, nil, _ctx, _timeout),
    do: %{plugin: plugin, module: nil, result: {:skip, "no manifest (tier-0 plugin)"}, ms: 0}

  defp run_one(node, plugin, manifest, ctx, timeout) do
    case Map.get(manifest, :selftest) do
      nil ->
        %{plugin: plugin, module: nil, result: {:skip, "no selftest in manifest"}, ms: 0}

      module ->
        {ms, result} = timed(fn -> call(node, module, ctx, timeout) end)
        %{plugin: plugin, module: module, result: result, ms: ms}
    end
  end

  # Everything a remote run/1 can do wrong lands here as {:fail, why}, so a
  # broken self-test never takes the runner (or the other plugins' runs) down.
  defp call(node, module, ctx, timeout) do
    normalize(:erpc.call(node, module, :run, [ctx], timeout), module)
  catch
    :error, {:erpc, :timeout} ->
      {:fail, "timed out after #{timeout} ms"}

    :error, {:erpc, :noconnection} ->
      {:fail, "node #{node} is not reachable"}

    :error, {:exception, :undef, [{^module, :run, _, _} | _]} ->
      {:fail,
       "#{inspect(module)}.run/1 is not on the device (deployed before the self-test was added?)"}

    :error, {:exception, reason, stack} ->
      {:fail, "raised: " <> format_exception(reason, stack)}

    :exit, {:exception, reason} ->
      {:fail, "exited: #{inspect(reason, limit: 20)}"}

    :exit, {:signal, reason} ->
      {:fail, "killed: #{inspect(reason, limit: 20)}"}

    :throw, value ->
      {:fail, "threw: #{inspect(value, limit: 20)}"}
  end

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
  defp normalize(:pass, _module), do: :pass
  defp normalize({:fail, reason} = fail, _module) when is_binary(reason), do: fail

  defp normalize({:skip, reason} = skip, _module) when reason in [:needs_hardware, :needs_user],
    do: skip

  defp normalize({:skip, reason} = skip, _module) when is_binary(reason), do: skip

  defp normalize(other, module),
    do:
      {:fail,
       "#{inspect(module)}.run/1 returned #{inspect(other, limit: 20)}, " <>
         "not :pass | {:fail, reason} | {:skip, reason}"}

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp plugin_name(_name_or_dir, %{name: name}) when is_atom(name), do: name
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
  `device`, so self-tests do not hit a system prompt.

    * Android (emulator or physical): each `android.permissions` entry via
      `adb -s <serial> shell pm grant`. Only runtime permissions are
      grantable; a normal or signature permission answers with an error,
      which is recorded, not raised.
    * iOS simulator: each `permissions: [%{capability: cap}]` whose
      capability maps to a `simctl privacy` service.
    * iOS physical device: nothing can be granted from the host; returns `[]`.

  Returns one `t:grant/0` per attempt. `cmd` is `fn exe, argv -> {output, status} end`.
  """
  @spec grant_permissions(Device.t(), [{term(), map() | nil}], String.t(), (String.t(),
                                                                            [String.t()] ->
                                                                              {String.t(),
                                                                               integer()})) ::
          [grant()]
  def grant_permissions(%Device{platform: :android, serial: serial}, plugins, bundle_id, cmd) do
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

  def grant_permissions(%Device{platform: :ios}, _plugins, _bundle_id, _cmd), do: []

  @doc false
  @spec android_permissions([{term(), map() | nil}]) :: [{atom(), String.t()}]
  def android_permissions(plugins) do
    for {name_or_dir, %{} = manifest} <- plugins,
        perm <- get_in(manifest, [:android, :permissions]) || [],
        is_binary(perm),
        do: {plugin_name(name_or_dir, manifest), perm}
  end

  @doc false
  @spec simctl_services([{term(), map() | nil}]) :: [{atom(), String.t()}]
  def simctl_services(plugins) do
    for {name_or_dir, %{} = manifest} <- plugins,
        %{capability: cap} <- Map.get(manifest, :permissions) || [],
        service = Map.get(@simctl_services, cap),
        do: {plugin_name(name_or_dir, manifest), service}
  end

  defp status(_out, 0), do: :ok
  defp status(out, _status), do: {:error, out |> String.trim() |> String.slice(0, 200)}

  defp bundle_id(opts, device) do
    Keyword.get_lazy(opts, :bundle_id, fn ->
      case device.platform do
        :ios -> MobDev.Config.ios_bundle_id()
        :android -> MobDev.Config.bundle_id()
      end
    end)
  end

  defp cmd(opts) do
    Keyword.get(opts, :cmd, fn exe, argv -> System.cmd(exe, argv, stderr_to_stdout: true) end)
  end

  # ── reporting ─────────────────────────────────────────────────────────────

  @doc """
  The table `mix mob.selftest` prints for one device: a header plus one
  line per entry, `plugin  outcome  ms  detail`.
  """
  @spec table([entry()]) :: [String.t()]
  def table(entries) do
    rows = Enum.map(entries, &row/1)
    widths = column_widths([["plugin", "outcome", "ms", "detail"] | rows])

    for row <- [["plugin", "outcome", "ms", "detail"] | rows] do
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

  defp column_widths(rows) do
    rows
    |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

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
