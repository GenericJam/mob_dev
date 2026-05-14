defmodule MobDev.Release.AndroidPrecheck do
  @moduledoc false

  # Shared precondition checks for Android release builds. Both the OTP
  # cross-compile and the OpenSSL/crypto NIF cross-compile need to verify
  # that an NDK install exists at the expected path before running any
  # of their own logic. This module factors that out so the two recipes
  # don't drift.

  alias MobDev.NdkVersion
  alias MobDev.Release.Errors

  @doc """
  Verify the Android NDK is installed at the path implied by
  `opts[:ndk_root]` (or the default location). Returns :ok or raises
  via Errors.precondition/1.

  Takes a `shell` module so callers can pass in a fake during tests.
  """
  @spec verify_ndk(module(), keyword()) :: :ok | no_return()
  def verify_ndk(shell, opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root(opts[:ndk_version])

    if shell.dir?(ndk_root) do
      :ok
    else
      Errors.precondition("Android NDK not at #{ndk_root} — install NDK #{NdkVersion.effective()}")
    end
  end

  @doc """
  Canonical NDK install path: `~/Library/Android/sdk/ndk/<version>`.
  Falls back to `NdkVersion.effective/0` when no version is supplied.
  """
  @spec default_ndk_root(String.t() | nil) :: String.t()
  def default_ndk_root(version \\ nil) do
    Path.join([System.user_home!(), "Library/Android/sdk/ndk", version || NdkVersion.effective()])
  end
end
