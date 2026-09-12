defmodule MobDev.TaskTargets do
  @moduledoc """
  Shared device-selection policy for tasks that can change device state.

  A named device is always explicit. Broad selection keeps physical
  devices behind `:all_physical`; `:all_devices` means development
  emulators and simulators. **Combined `:all_devices` and
  `:all_physical` selects every connected device.** With no scope
  flags, exactly one non-physical device may be selected automatically;
  multiple development devices are an ambiguity error.
  """

  alias MobDev.Device

  @type selection_error ::
          :no_devices
          | :ambiguous_devices
          | :no_matching_devices
          | :no_dev_devices
          | :no_physical_devices

  @doc """
  Resolve a device snapshot into the exact targets for one task run.
  """
  @spec resolve([Device.t()], [String.t()], keyword()) ::
          {:ok, [Device.t()]} | {:error, selection_error(), map()}
  def resolve(all, device_ids, opts) do
    selected = select(all, device_ids, opts)

    cond do
      all == [] ->
        {:error, :no_devices, %{detected: 0}}

      device_ids != [] and selected == [] ->
        {:error, :no_matching_devices, %{requested: device_ids, detected: length(all)}}

      selected == [] ->
        empty_selection_error(all, opts)

      true ->
        {:ok, selected}
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
        if length(non_physical) == 1, do: non_physical, else: []
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
