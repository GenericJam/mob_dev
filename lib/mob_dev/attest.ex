defmodule MobDev.Attest do
  @moduledoc """
  Prove that the code running on a device is the code you just pushed.

  `mix mob.deploy` reports what it *did*, not what is now *true*. Those come
  apart more often than the exit code suggests, and the interesting failures
  are the quiet ones — a deploy that prints a tick while the app keeps running
  something else entirely.

  The case that produced this module: two bundle ids diverged, so the BEAM push
  addressed one app's container while a different app was running. It did not
  fail with "not installed". It succeeded, printed a tick, and the app carried
  on with the old code. Both containers existed on the device, so every layer
  of the deploy was telling the truth about its own step, and the run as a whole
  was a lie.

  Every guide in these repos says "verify effects, not exit codes". That
  instruction exists because the tools cannot be trusted, and it only works
  while a human remembers to follow it. This makes it a property the tool
  checks.

  ## How

  `module_info(:md5)` on a loaded module is the same digest `:beam_lib.md5/1`
  reports for the `.beam` it was loaded from. Ask the device for one, compute
  the other locally, compare. A module that never arrived, arrived somewhere
  else, or arrived and was never loaded all show up.

  This deliberately does not hash whole files or directories: two builds of the
  same source differ in timestamps and paths, and a check that cries wolf gets
  turned off.
  """

  @typedoc """
  What a single module's comparison found.

  * `:match` — the device is running the bytes we have.
  * `:stale` — it is running *something*, but not this. The push did not land,
    or landed somewhere else, or landed and was not loaded.
  * `:missing` — the device has never loaded this module. Expected for a lazily
    loaded module, damning for one the app needs to boot.
  * `:unreadable` — the local `.beam` could not be digested, so nothing can be
    concluded. Not a pass.
  """
  @type verdict :: :match | :stale | :missing | :unreadable

  @type finding :: %{
          module: module(),
          verdict: verdict(),
          expected: binary() | nil,
          actual: binary() | nil
        }

  @doc """
  The digest of a module as built locally.

  Returns `nil` when the file cannot be read or is not a beam — the caller must
  treat that as "cannot tell", never as agreement.
  """
  @spec local_digest(Path.t()) :: {module(), binary()} | nil
  def local_digest(path) do
    case :beam_lib.md5(String.to_charlist(path)) do
      {:ok, {module, digest}} -> {module, digest}
      _ -> nil
    end
  end

  @doc """
  Compare one module's local digest against what the device reports.

  `remote` is whatever `module_info(:md5)` came back with, including the
  failure shapes: `nil`, `{:badrpc, _}`, or an `:undef` exit for a module the
  device has never loaded.
  """
  @spec compare(module(), binary() | nil, term()) :: finding()
  def compare(module, nil, _remote),
    do: %{module: module, verdict: :unreadable, expected: nil, actual: nil}

  def compare(module, expected, remote) do
    case normalise_remote(remote) do
      ^expected -> %{module: module, verdict: :match, expected: expected, actual: expected}
      nil -> %{module: module, verdict: :missing, expected: expected, actual: nil}
      actual -> %{module: module, verdict: :stale, expected: expected, actual: actual}
    end
  end

  # A module the device has never loaded raises :undef, which arrives as a
  # badrpc EXIT rather than a value. That is "missing", not "different" — the
  # distinction matters because a lazily loaded module being absent is normal
  # and a mismatched one never is.
  defp normalise_remote(digest) when is_binary(digest), do: digest
  defp normalise_remote(_other), do: nil

  @doc """
  Whether a set of findings means the deploy can be believed.

  `:stale` is always fatal: the device is running code we did not build, which
  is the failure this module exists to catch.

  `:unreadable` is fatal too. It means the check could not run, and a check that
  could not run must not report success — that is the same defect as a deploy
  exiting 0 having shipped nothing.

  `:missing` is not fatal on its own. Interactive BEAM loads a module when
  something first calls it, so a module that is shipped but not yet loaded is
  the normal state of most of the bundle. It is reported, not failed on.
  """
  @spec verdict([finding()]) :: :ok | {:error, String.t()}
  def verdict(findings) do
    stale = Enum.filter(findings, &(&1.verdict == :stale))
    unreadable = Enum.filter(findings, &(&1.verdict == :unreadable))

    cond do
      stale != [] ->
        {:error,
         "#{length(stale)} module(s) on the device do not match this build: " <>
           name_list(stale) <> ". The app is running code you did not just push."}

      unreadable != [] ->
        {:error,
         "#{length(unreadable)} module(s) could not be digested locally: " <>
           name_list(unreadable) <> ". Nothing can be concluded about the device."}

      true ->
        :ok
    end
  end

  defp name_list(findings) do
    findings
    |> Enum.map(&inspect(&1.module))
    |> Enum.sort()
    |> Enum.take(5)
    |> Enum.join(", ")
  end

  @doc """
  Counts per verdict, for the summary line and the JSON payload.

  Every verdict is present whether or not it occurred, so a consumer reading
  `.stale` never gets `nil` on the runs that found nothing — the same reason
  `mix mob.mutate`'s summary has a fixed shape.
  """
  @spec tally([finding()]) :: %{verdict() => non_neg_integer()}
  def tally(findings) do
    base = %{match: 0, stale: 0, missing: 0, unreadable: 0}
    Enum.reduce(findings, base, fn f, acc -> Map.update!(acc, f.verdict, &(&1 + 1)) end)
  end
end
