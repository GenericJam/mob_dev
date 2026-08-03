defmodule Mix.Tasks.Mob.DeployLock do
  use Mix.Task

  alias MobDev.{AndroidDeployLock, Config}

  @shortdoc "Inspect or clean a verified Android deploy-lock tombstone"

  @moduledoc """
  Inspects the app-private Android native-deploy lease for one exact device.

  The default operation is read-only. Recovery is deliberately narrow:
  `--cleanup-committed` removes only a single, structurally valid release
  tombstone whose record is already in a committed phase. It refuses active,
  malformed, missing, or topologically ambiguous leases. It never removes the
  app, clears app data, or deletes an active deploy lock.

      mix mob.deploy_lock --device <exact-adb-serial>
      mix mob.deploy_lock --device <exact-adb-serial> --cleanup-committed

  A retained active or ambiguous lease means the interrupted operation needs
  diagnosis. Do not retry a native deploy until its exact state is understood.
  """

  @switches [device: :string, cleanup_committed: :boolean]

  @impl Mix.Task
  def run(args) when is_list(args) do
    require_exactly_one_device_switch!(args)
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Usage: mix mob.deploy_lock --device <exact-adb-serial> [--cleanup-committed]")
    end

    device = exact_device!(opts)

    case inspect_or_cleanup(
           Config.bundle_id(),
           device,
           opts[:cleanup_committed] == true,
           &run_adb/1
         ) do
      {:ok, :clear} ->
        IO.puts("Android deploy lock: clear")

      {:ok, :held} ->
        IO.puts("Android deploy lock: active; manual diagnosis required")

      {:ok, :released_tombstone} ->
        IO.puts("Android deploy lock: release tombstone present; phase unverified")

      {:ok, :ambiguous} ->
        IO.puts("Android deploy lock: ambiguous; manual diagnosis required")

      {:ok, :cleaned} ->
        IO.puts("Android deploy lock: verified committed tombstone removed")

      {:error, {:cleanup_refused, state}} ->
        Mix.raise("Committed tombstone cleanup refused (#{status_label(state)})")

      {:error, reason} when reason in [:cleanup_ambiguous, :post_cleanup_ambiguous] ->
        Mix.raise(
          "Committed tombstone cleanup became ambiguous after its single attempt; do not retry"
        )

      {:error, _reason} ->
        Mix.raise("Android deploy-lock status is ambiguous; no cleanup was attempted")
    end
  end

  def run(_args),
    do: Mix.raise("Usage: mix mob.deploy_lock --device <exact-adb-serial> [--cleanup-committed]")

  @doc false
  @spec inspect_or_cleanup(String.t(), String.t(), boolean(), ([String.t()] -> term())) ::
          {:ok, :clear | :held | :released_tombstone | :ambiguous | :cleaned}
          | {:error, atom() | {:cleanup_refused, atom()}}
  def inspect_or_cleanup(bundle_id, serial, false, runner)
      when is_binary(bundle_id) and is_binary(serial) and is_function(runner, 1) do
    AndroidDeployLock.status(bundle_id, serial, runner)
  end

  def inspect_or_cleanup(bundle_id, serial, true, runner)
      when is_binary(bundle_id) and is_binary(serial) and is_function(runner, 1) do
    case AndroidDeployLock.status(bundle_id, serial, runner) do
      {:ok, :released_tombstone} ->
        clean_committed_tombstone(bundle_id, serial, runner)

      {:ok, state} when state in [:clear, :held, :ambiguous] ->
        {:error, {:cleanup_refused, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def inspect_or_cleanup(_bundle_id, _serial, _cleanup?, _runner),
    do: {:error, :invalid_request}

  defp clean_committed_tombstone(bundle_id, serial, runner) do
    with :ok <- AndroidDeployLock.cleanup_committed_tombstone(bundle_id, serial, runner) do
      case AndroidDeployLock.status(bundle_id, serial, runner) do
        {:ok, :clear} -> {:ok, :cleaned}
        _changed_or_invalid -> {:error, :post_cleanup_ambiguous}
      end
    end
  end

  defp run_adb(args) do
    case System.find_executable("adb") do
      nil -> {"", 127}
      adb -> System.cmd(adb, args, stderr_to_stdout: true)
    end
  end

  defp exact_device!(opts) do
    case Keyword.get_values(opts, :device) do
      [device] when is_binary(device) and device != "" ->
        device

      [] ->
        Mix.raise("An exact Android device serial is required; pass --device <serial>")

      [_device | _duplicates] ->
        Mix.raise("Exactly one Android device serial is required; pass --device once")
    end
  end

  defp require_exactly_one_device_switch!(args) do
    case Enum.count(args, &device_switch?/1) do
      1 ->
        :ok

      0 ->
        Mix.raise("An exact Android device serial is required; pass --device <serial>")

      _duplicates ->
        Mix.raise("Exactly one Android device serial is required; pass --device once")
    end
  end

  defp device_switch?("--device"), do: true
  defp device_switch?("--device=" <> _value), do: true
  defp device_switch?(_arg), do: false

  defp status_label(state), do: Atom.to_string(state)
end
