defmodule MobDev.TaskTargets do
  @moduledoc """
  Shared device-selection policy for tasks that can change device state.

  A named device is always explicit. Broad selection keeps physical
  devices behind `:all_physical`; `:all_devices` means development
  emulators and simulators. **Combined `:all_devices` and
  `:all_physical` selects every connected device.** With no scope
  flags, exactly one non-physical device may be selected automatically;
  multiple development devices are an ambiguity error.

  `resolve/3` honours agent-device leases passed as `:leases`
  (`MobDev.DeviceLeases`): every selection the user did not name skips
  devices another session has claimed, and a named device that is claimed
  is used with a warning. A device chosen automatically is always printed.
  """

  alias MobDev.{Device, DeviceLeases}

  @type selection_error ::
          :no_devices
          | :ambiguous_devices
          | :no_matching_devices
          | :no_dev_devices
          | :no_physical_devices
          | :all_claimed

  @doc """
  Resolve a device snapshot into the exact targets for one task run.

  `opts[:leases]` is the `MobDev.DeviceLeases` snapshot to honour (default:
  no claims). Skipped, warned-about and auto-selected devices are printed.
  """
  @spec resolve([Device.t()], [String.t()], keyword()) ::
          {:ok, [Device.t()]} | {:error, selection_error(), map()}
  def resolve(all, device_ids, opts) do
    leases = Keyword.get(opts, :leases, %DeviceLeases{})

    if device_ids == [] do
      resolve_unnamed(all, leases, opts)
    else
      resolve_named(all, device_ids, leases)
    end
  end

  defp resolve_named([], _device_ids, _leases), do: {:error, :no_devices, %{detected: 0}}

  defp resolve_named(all, device_ids, leases) do
    case filter_by_id(all, device_ids) do
      [] ->
        {:error, :no_matching_devices, %{requested: device_ids, detected: length(all)}}

      selected ->
        {:ok, DeviceLeases.warn_claimed(selected, leases)}
    end
  end

  defp resolve_unnamed([], _leases, _opts), do: {:error, :no_devices, %{detected: 0}}

  defp resolve_unnamed(all, leases, opts) do
    free = DeviceLeases.exclude_claimed(all, leases)
    claimed = all -- free
    in_scope? = scope_filter(opts)

    case select(free, [], opts) do
      [] ->
        if claimed != [] and Enum.any?(claimed, in_scope?) and not Enum.any?(free, in_scope?),
          do: {:error, :all_claimed, %{claimed: length(claimed)}},
          else: empty_selection_error(free, opts)

      selected ->
        unless broad?(opts) do
          Enum.each(selected, &IO.puts("  Auto-selected #{DeviceLeases.label(&1)}"))
        end

        {:ok, selected}
    end
  end

  defp broad?(opts),
    do:
      Keyword.get(opts, :all_devices, false) == true or
        Keyword.get(opts, :all_physical, false) == true

  # Which devices a run without named ids could pick at all, before
  # ambiguity: used to tell "everything you could have had is claimed" apart
  # from the ordinary empty-selection errors.
  defp scope_filter(opts) do
    case {Keyword.get(opts, :all_devices, false) == true,
          Keyword.get(opts, :all_physical, false) == true} do
      {true, true} -> fn _ -> true end
      {false, true} -> &Device.physical?/1
      _ -> &(not Device.physical?(&1))
    end
  end

  @doc """
  Select devices from an already-discovered snapshot.

  Precedence is named devices, both broad flags, development devices,
  physical devices, then safe single-development-device auto-selection.
  """
  @spec select([Device.t()], [String.t()], keyword()) :: [Device.t()]
  def select(all, device_ids, opts) do
    all_devices? = Keyword.get(opts, :all_devices, false) == true
    all_physical? = Keyword.get(opts, :all_physical, false) == true

    cond do
      device_ids != [] ->
        filter_by_id(all, device_ids)

      all_devices? and all_physical? ->
        all

      all_devices? ->
        Enum.reject(all, &Device.physical?/1)

      all_physical? ->
        Enum.filter(all, &Device.physical?/1)

      true ->
        non_physical = Enum.reject(all, &Device.physical?/1)
        if match?([_], non_physical), do: non_physical, else: []
    end
  end

  @doc """
  Filter devices by the identifiers accepted by `MobDev.Device.match_id?/2`.
  """
  @spec filter_by_id([Device.t()], [String.t()]) :: [Device.t()]
  def filter_by_id(devices, []), do: devices

  def filter_by_id(devices, ids) do
    Enum.filter(devices, fn device ->
      Enum.any?(ids, &Device.match_id?(device, &1))
    end)
  end

  defp empty_selection_error(all, opts) do
    physical = Enum.filter(all, &Device.physical?/1)
    non_physical = Enum.reject(all, &Device.physical?/1)
    all_devices? = Keyword.get(opts, :all_devices, false) == true
    all_physical? = Keyword.get(opts, :all_physical, false) == true

    cond do
      all_devices? and non_physical == [] ->
        {:error, :no_dev_devices,
         %{
           physical_count: length(physical),
           hint:
             "Only physical devices are connected. `--all-devices` targets " <>
               "emulators/simulators only; use `--all-physical` to include " <>
               "physical devices, or `--device <id>` to target one explicitly."
         }}

      all_physical? and physical == [] ->
        {:error, :no_physical_devices, %{detected: length(all)}}

      true ->
        {:error, :ambiguous_devices,
         %{
           detected: length(all),
           non_physical: length(non_physical),
           physical: length(physical)
         }}
    end
  end
end
