defmodule MobDev.Toolchain do
  @moduledoc false

  # This value must live in packaged source; the root toolchain file is not in
  # Hex archives. The source test keeps both release authorities in lockstep.
  @required_zig_version "0.17.0-dev.269+ebff43698"

  @type zig_status ::
          :missing
          | {:ok, String.t()}
          | {:version_mismatch, String.t()}
          | {:version_command_failed, String.t(), non_neg_integer()}

  @spec required_zig_version() :: String.t()
  def required_zig_version, do: @required_zig_version

  @spec zig_status() :: zig_status()
  def zig_status do
    case System.find_executable("zig") do
      nil ->
        :missing

      executable ->
        zig_status_from_result(System.cmd(executable, ["version"], stderr_to_stdout: true))
    end
  end

  @spec zig_status_from_result({String.t(), non_neg_integer()}) :: zig_status()
  def zig_status_from_result({output, 0}) do
    version = String.trim(output)

    if version == @required_zig_version do
      {:ok, version}
    else
      {:version_mismatch, version}
    end
  end

  def zig_status_from_result({output, exit_status}) do
    {:version_command_failed, String.trim(output), exit_status}
  end

  @spec zig_install_instructions() :: String.t()
  def zig_install_instructions do
    "Install the exact Zig build toolchain with mise:\n" <>
      "      mise install zig@#{@required_zig_version}\n" <>
      "      mise use zig@#{@required_zig_version}"
  end
end
