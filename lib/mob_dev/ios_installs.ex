defmodule MobDev.IOSInstalls do
  @moduledoc """
  A record of which apps `mob_dev` has installed on which physical iOS device.

  This exists for exactly one reason: so that `mob_dev` can clear other Mob
  apps off a device without touching anything else on it.

  Physical-device Mob apps each start an in-process EPMD bound to
  `0.0.0.0:4369` (`mob/ios/mob_beam.m`), so only one can run at a time —
  launching a second gets EADDRINUSE and no BEAM. Clearing the others before
  launch is therefore necessary. What is *not* necessary, and what this module
  exists to prevent, is deciding which processes to kill by pattern-matching
  the running process list: every third-party app on the phone runs from
  `/private/var/containers/Bundle/Application/`, so that pattern matches
  Spotify, a banking app and everything else the owner had open (MOB-70).

  A device is someone's phone. `mob_dev` gets to kill what `mob_dev` put there,
  and nothing else. If this record is missing or empty, the correct behaviour
  is to kill nothing.

  Entries are dropped on uninstall (`forget/2`). Since the process listing
  carries no bundle ids, matching is by `.app` name — so a stale entry is not
  inert: it would stay killable, and a third-party app that later took that
  name would inherit it.

  Stored as JSON at `~/.mob/ios_installs.json`, keyed by device UDID. It is a
  cache, not a source of truth: deleting it costs a stale Mob app surviving a
  launch, not correctness.
  """

  @type app :: %{bundle_id: String.t(), app_name: String.t()}

  @doc "Path to the registry file. Override with `MOB_IOS_INSTALLS` in tests."
  @spec path() :: Path.t()
  def path do
    System.get_env("MOB_IOS_INSTALLS") || Path.expand("~/.mob/ios_installs.json")
  end

  @doc """
  Record that `bundle_id` (whose bundle is `app_name`.app) is installed on
  `udid`.

  Idempotent: re-installing the same app does not duplicate the entry, and a
  changed `app_name` for a known bundle id replaces it rather than accumulating.
  """
  @spec record(String.t(), String.t(), String.t()) :: :ok
  def record(udid, bundle_id, app_name)
      when is_binary(udid) and is_binary(bundle_id) and is_binary(app_name) do
    all = read_all()
    existing = Map.get(all, udid, [])

    updated =
      [%{"bundle_id" => bundle_id, "app_name" => app_name}] ++
        Enum.reject(existing, &(&1["bundle_id"] == bundle_id))

    write_all(Map.put(all, udid, updated))
  end

  def record(_, _, _), do: :ok

  @doc """
  Apps `mob_dev` has installed on `udid`, newest first. `[]` when unknown —
  which callers must treat as "kill nothing", not "kill everything".
  """
  @spec installed(String.t()) :: [app()]
  def installed(udid) when is_binary(udid) do
    all = read_all()

    # Shape-wrong-but-valid JSON is a different failure from unparseable JSON,
    # and `Map.get/3` happily returns a binary that `Enum.flat_map/2` then
    # raises on. Both mean the same thing here: we do not know what is ours.
    entries =
      case Map.get(all, udid, []) do
        list when is_list(list) -> list
        _ -> []
      end

    entries
    |> Enum.flat_map(fn
      %{"bundle_id" => b, "app_name" => n} when is_binary(b) and is_binary(n) ->
        [%{bundle_id: b, app_name: n}]

      _ ->
        []
    end)
  end

  def installed(_), do: []

  @doc """
  Drop `bundle_id` from `udid`'s record, after uninstalling it.

  Matching is by app NAME, so a stale entry is not inert: it stays killable
  for ever, and a third-party app that later takes that name inherits the
  entry. Forgetting on uninstall is what makes the module's promise — we kill
  what we put there — true rather than approximately true.
  """
  @spec forget(String.t(), String.t()) :: :ok
  def forget(udid, bundle_id) when is_binary(udid) and is_binary(bundle_id) do
    all = read_all()

    case Map.get(all, udid) do
      list when is_list(list) ->
        write_all(Map.put(all, udid, Enum.reject(list, &(&1["bundle_id"] == bundle_id))))

      _ ->
        :ok
    end
  end

  def forget(_, _), do: :ok

  # A corrupt or unreadable registry is indistinguishable from an absent one,
  # and both mean the same thing to every caller: we do not know what is ours,
  # so we touch nothing.
  defp read_all do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = decoded} <- decode(body) do
      decoded
    else
      _ -> %{}
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      %{} = m -> {:ok, m}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp write_all(map) do
    file = path()
    File.mkdir_p!(Path.dirname(file))

    # Write-then-rename. Two `mix mob.deploy` runs against different devices is
    # normal here, and `File.write!` is not atomic — a concurrent reader can
    # otherwise observe a half-written file, fail to decode, and treat the
    # whole registry as absent. Rename is atomic within a filesystem.
    tmp = file <> ".tmp"
    File.write!(tmp, :json.encode(map) |> IO.iodata_to_binary())
    File.rename!(tmp, file)
    :ok
  rescue
    # Losing the record costs a stale app surviving a later launch. It must
    # never cost the deploy that is happening now.
    _ -> :ok
  end
end
