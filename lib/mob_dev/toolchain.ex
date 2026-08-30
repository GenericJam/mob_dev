defmodule MobDev.Toolchain do
  @moduledoc false

  @tool_versions_path Path.expand("../../.tool-versions", __DIR__)
  @external_resource @tool_versions_path
  @required_zig_version @tool_versions_path
                        |> File.read!()
                        |> String.split("\n")
                        |> Enum.find_value(fn line ->
                          case String.split(line) do
                            ["zig", version] -> version
                            _ -> nil
                          end
                        end) || raise("zig is not pinned in #{@tool_versions_path}")

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
