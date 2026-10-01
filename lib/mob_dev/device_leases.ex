defmodule MobDev.DeviceLeases do
  @moduledoc """
  agent-device device claims, read as leases, so a task that picks devices on
  its own leaves alone a device another agent has claimed (MOB-330).

  Several agents share one machine's phones, emulators and simulators, and
  each claims the device it works on with `agent-device open --serial <s>
  --session <name>`. Only agent-device enforces those claims; adb and the mob
  tasks never saw them, so a bare `mix mob.deploy` once installed and launched
  an app on an emulator another agent was driving.

  The claims come from `agent-device device status --json`, which reads the
  host-local claim records without contacting the daemon or any device.
  When `agent-device` is not on PATH there are no claims and selection is
  unchanged.

  A claim is yours when its session equals `AGENT_DEVICE_SESSION`, the
  variable agent-device itself reads for the session name. With the variable
  unset every claim belongs to someone else: a lease only counts as yours when
  you have said who you are.

  The policy, applied by every task that chooses devices:

    * **Auto-selection skips claimed devices** and prints each one it skipped
      and who holds it (`exclude_claimed/2`). That covers single-device
      auto-selection and the broad `--all-devices` / `--all-physical` scopes
      (`MobDev.TaskTargets`), `mix mob.connect` without `--device`,
      `mix mob.push` / `mix mob.watch` (`MobDev.HotPush.connect/1`) and the
      battery benches' device auto-detection.
    * **A device named explicitly is used anyway, with a loud warning**
      (`warn_claimed/2`). Naming the device is the same consent
      `--device` already gives for a phone; refusing would leave no
      way to reach a device whose lease outlived its owner short of releasing
      someone else's claim.

  An iPhone found over the LAN (`MobDev.Discovery.IOS.find_physical_at/1`)
  carries its IP as its serial: EPMD names the app's node, not the phone,
  so there is no hardware UDID to match against a claim. Such an iPhone
  counts as claimed whenever another session claims a device that could be
  a physical iPhone (an iOS claim, or one of unknown platform, that is not a
  simulator). That can skip a free phone, which `--device <ip>` still
  reaches; the alternative deploys onto a leased one.
  """

  alias MobDev.Device

  defstruct claims: [], session: nil

  @type claim :: %{
          id: String.t(),
          platform: :android | :ios | nil,
          kind: :device | :emulator | :simulator | nil,
          session: String.t() | nil,
          workspace: String.t() | nil
        }

  @type t :: %__MODULE__{claims: [claim()], session: String.t() | nil}

  @doc """
  Read the current claims, and this process's session from
  `AGENT_DEVICE_SESSION`.

  Returns no claims when `agent-device` is not on PATH. When it is installed
  but its output can't be read, warns that leases are not being honoured and
  returns no claims, rather than blocking every deploy on a broken tool.
  """
  @spec load() :: t()
  def load do
    case System.find_executable("agent-device") do
      nil ->
        from_claims([])

      exe ->
        {out, _status} = System.cmd(exe, ["device", "status", "--json"])
        from_status(out)
    end
  end

  @doc """
  Leases from `agent-device device status --json` output a caller already
  ran, with the same warning as `load/0` when it can't be read.
  """
  @spec from_status(String.t()) :: t()
  def from_status(output) do
    case parse_status(output) do
      {:ok, claims} ->
        from_claims(claims)

      {:error, reason} ->
        IO.puts(
          "  #{IO.ANSI.yellow()}Could not read agent-device claims (#{reason}); " <>
            "device selection is not honouring leases this run.#{IO.ANSI.reset()}"
        )

        from_claims([])
    end
  end

  defp from_claims(claims),
    do: %__MODULE__{
      claims: claims,
      session: current_session(System.get_env("AGENT_DEVICE_SESSION"))
    }

  @doc false
  # The session a claim must name to count as this process's own; `nil` when
  # unset, in which case no claim is ours.
  @spec current_session(String.t() | nil) :: String.t() | nil
  def current_session(nil), do: nil

  def current_session(value) do
    case String.trim(value) do
      "" -> nil
      session -> session
    end
  end

  @doc false
  # Parse `agent-device device status --json`. Stale claims are hidden from
  # that listing (`hiddenStaleClaims`), so every listed claim is live or of
  # uncertain liveness, and both count. Public for testing; `MobDev.Smoke`
  # reads claims through it too.
  @spec parse_status(String.t()) :: {:ok, [claim()]} | {:error, String.t()}
  def parse_status(json) do
    case Jason.decode(String.trim(json)) do
      {:ok, %{"success" => true, "data" => %{"claims" => claims}}} when is_list(claims) ->
        {:ok, Enum.flat_map(claims, &parse_claim/1)}

      {:ok, %{"success" => false, "error" => %{"message" => message}}} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, "agent-device device status did not print a claims report"}
    end
  end

  # A claim whose owner names no session still holds the device; it just
  # can't be anyone's own.
  defp parse_claim(%{} = claim) do
    device = Map.get(claim, "device") || %{}
    owner = Map.get(claim, "owner") || %{}

    case device["id"] || key_id(claim["deviceKey"]) do
      id when is_binary(id) and id != "" ->
        [
          %{
            id: id,
            platform: platform(device["platform"]),
            kind: kind(device["kind"]),
            session: owner["session"],
            workspace: owner["workspace"]
          }
        ]

      _ ->
        []
    end
  end

  defp parse_claim(_), do: []

  # "local:android:none:ZY22DP6HFL" — the id is the last segment.
  defp key_id(key) when is_binary(key), do: key |> String.split(":") |> List.last()
  defp key_id(_), do: nil

  defp platform("android"), do: :android
  defp platform("ios"), do: :ios
  defp platform(_), do: nil

  defp kind("device"), do: :device
  defp kind("emulator"), do: :emulator
  defp kind("simulator"), do: :simulator
  defp kind(_), do: nil

  @doc """
  The claim another session holds on `device`, or `nil` when it is free or
  claimed by this session.
  """
  @spec foreign_claim(Device.t(), t()) :: claim() | nil
  def foreign_claim(%Device{} = device, %__MODULE__{claims: claims, session: session}) do
    Enum.find(claims, fn claim ->
      (is_nil(claim.session) or claim.session != session) and claims_device?(claim, device)
    end)
  end

  defp claims_device?(claim, %Device{platform: platform, serial: serial} = device) do
    if lan_iphone?(device),
      do: could_be_iphone?(claim),
      else:
        claim.platform in [nil, platform] and is_binary(serial) and
          String.downcase(claim.id) == String.downcase(serial)
  end

  # An iPhone known only by the IP it answered EPMD on: which phone it is,
  # and so which claim is its, can't be told.
  defp lan_iphone?(%Device{platform: :ios, type: :physical, serial: serial})
       when is_binary(serial),
       do: match?({:ok, _}, :inet.parse_address(String.to_charlist(serial)))

  defp lan_iphone?(_), do: false

  defp could_be_iphone?(claim),
    do: claim.platform in [nil, :ios] and claim.kind not in [:emulator, :simulator]

  @doc """
  Split `devices` into the ones auto-selection may use and the ones another
  session has claimed, each paired with its claim. Order is preserved.
  """
  @spec partition([Device.t()], t()) :: {[Device.t()], [{Device.t(), claim()}]}
  def partition(devices, %__MODULE__{} = leases) do
    {free, claimed} =
      Enum.reduce(devices, {[], []}, fn device, {free, claimed} ->
        case foreign_claim(device, leases) do
          nil -> {[device | free], claimed}
          claim -> {free, [{device, claim} | claimed]}
        end
      end)

    {Enum.reverse(free), Enum.reverse(claimed)}
  end

  @doc """
  Auto-selection's filter: drop every device another session has claimed,
  printing one line per skipped device. Returns the devices left.

  `hint` ends each line; the default points at `--device`, for tasks that
  have one.
  """
  @spec exclude_claimed([Device.t()], t(), String.t()) :: [Device.t()]
  def exclude_claimed(
        devices,
        %__MODULE__{} = leases,
        hint \\ "Name it with --device to use it anyway."
      ) do
    {free, claimed} = partition(devices, leases)

    Enum.each(claimed, fn {device, claim} ->
      IO.puts(
        "  #{IO.ANSI.yellow()}Skipping #{label(device)}: #{reason(device, claim)}. " <>
          "#{hint}#{IO.ANSI.reset()}"
      )
    end)

    free
  end

  @doc """
  For devices the user named: warn loudly about each one another session has
  claimed, and return the list unchanged.
  """
  @spec warn_claimed([Device.t()], t()) :: [Device.t()]
  def warn_claimed(devices, %__MODULE__{} = leases) do
    devices
    |> partition(leases)
    |> elem(1)
    |> Enum.each(fn {device, claim} ->
      IO.puts(
        "\n  #{IO.ANSI.red()}#{IO.ANSI.bright()}WARNING: #{label(device)} is " <>
          "#{reason(device, claim)}.#{IO.ANSI.reset()}\n" <>
          "  #{IO.ANSI.red()}Using it because you named it; this may disrupt that agent's work." <>
          "#{IO.ANSI.reset()}\n"
      )
    end)

    devices
  end

  @doc """
  "claimed by agent-device session \\"name\\" (in /workspace)".
  """
  @spec describe(claim()) :: String.t()
  def describe(%{session: session, workspace: workspace}) do
    where = if is_binary(workspace), do: " (in #{workspace})", else: ""
    "claimed by agent-device session #{inspect(session || "?")}#{where}"
  end

  defp reason(device, claim) do
    if lan_iphone?(device),
      do:
        "possibly #{describe(claim)}: an iPhone found over the LAN can't be matched " <>
          "to its claim",
      else: describe(claim)
  end

  @doc false
  @spec label(Device.t()) :: String.t()
  def label(%Device{name: name, serial: serial}) when is_binary(name) and name != serial,
    do: "#{name} (#{serial})"

  def label(%Device{serial: serial}), do: to_string(serial)
end
