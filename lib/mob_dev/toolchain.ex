defmodule MobDev.Toolchain do
  @moduledoc false

  # This value must live in packaged source; the root toolchain file is not in
  # Hex archives. The source test keeps both release authorities in lockstep.
  @required_zig_version "0.17.0-dev.269+ebff43698"

  # iPhone Duo needs the iOS 27.1 SDK, which ships with Xcode 27.1 (MOB-201).
  @duo_min_version {27, 1, 0}

  @type zig_status ::
          :missing
          | {:ok, String.t()}
          | {:version_mismatch, String.t()}
          | {:version_command_failed, String.t(), non_neg_integer()}

  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type cmd_result :: {String.t(), non_neg_integer()}
  @type xcode :: %{version: version(), build: String.t() | nil, beta?: boolean()}
  @type xcode_probe :: %{
          xcodebuild: cmd_result(),
          ios_sdk: cmd_result(),
          developer_dir: String.t() | nil
        }

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

  # ── Xcode / iOS SDK ─────────────────────────────────────────────────────────
  #
  # Every probe goes through xcrun / xcodebuild / xcode-select, which resolve
  # the toolchain from DEVELOPER_DIR, then `xcode-select -s`. That is the same
  # resolution MobDev.NativeBuild's `xcrun --show-sdk-path` uses, so doctor
  # reports the Xcode a build would actually use.

  @doc "Runs the commands the Xcode checks parse. macOS only."
  @spec xcode_probe() :: xcode_probe()
  def xcode_probe do
    developer_dir =
      case safe_cmd("xcode-select", ["-p"]) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end

    %{
      xcodebuild: safe_cmd("xcodebuild", ["-version"]),
      ios_sdk: safe_cmd("xcrun", ["--sdk", "iphoneos", "--show-sdk-version"]),
      developer_dir: developer_dir
    }
  end

  @doc """
  Parses `xcodebuild -version` output:

      Xcode 27.1
      Build version 27A9269

  `beta?` is true when the version line says beta (the build number alone
  doesn't tell a beta from a release).
  """
  @spec parse_xcodebuild_version(String.t()) :: {:ok, xcode()} | :error
  def parse_xcodebuild_version(output) do
    lines = trimmed_lines(output)

    with "Xcode " <> rest <- Enum.find(lines, "", &String.starts_with?(&1, "Xcode ")),
         {:ok, version} <- parse_version(rest) do
      build =
        Enum.find_value(lines, fn
          "Build version " <> build -> String.trim(build)
          _ -> nil
        end)

      {:ok, %{version: version, build: build, beta?: beta?(rest)}}
    else
      _ -> :error
    end
  end

  @doc """
  Parses `xcrun --sdk iphoneos --show-sdk-version` output: the first line
  that is only a version, so warnings xcrun prints first are skipped.
  """
  @spec parse_sdk_version(String.t()) :: {:ok, version()} | :error
  def parse_sdk_version(output) do
    output
    |> trimmed_lines()
    |> Enum.find_value(:error, fn line ->
      case {String.split(line), parse_version(line)} do
        {[_single_token], {:ok, _} = ok} -> ok
        _ -> nil
      end
    end)
  end

  @doc """
  Parses a dotted version (`27`, `27.1`, `27.1.2`); text after the first
  whitespace (`27.1 beta 2`) is ignored.
  """
  @spec parse_version(String.t()) :: {:ok, version()} | :error
  def parse_version(text) do
    with [token | _] <- String.split(text),
         parts = token |> String.split(".") |> Enum.take(3) |> Enum.map(&Integer.parse/1),
         true <- Enum.all?(parts, &match?({_, ""}, &1)) do
      [major, minor, patch] = (Enum.map(parts, &elem(&1, 0)) ++ [0, 0]) |> Enum.take(3)
      {:ok, {major, minor, patch}}
    else
      _ -> :error
    end
  end

  @doc "Whether a version line or an Xcode app path names a beta."
  @spec beta?(String.t()) :: boolean()
  def beta?(text), do: text |> String.downcase() |> String.contains?("beta")

  @spec format_version(version()) :: String.t()
  def format_version({major, minor, 0}), do: "#{major}.#{minor}"
  def format_version({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"

  @doc "The Xcode and iOS SDK version iPhone Duo builds need."
  @spec duo_min_version() :: version()
  def duo_min_version, do: @duo_min_version

  @doc """
  Whether this Xcode and iOS SDK can build for iPhone Duo: both known and at
  least #{inspect(@duo_min_version)}. An unreadable version (`nil`) is not
  support.
  """
  @spec duo_supported?(version() | nil, version() | nil) :: boolean()
  def duo_supported?(xcode, ios_sdk) do
    Enum.all?([xcode, ios_sdk], &(&1 != nil and &1 >= @duo_min_version))
  end

  defp trimmed_lines(output), do: output |> String.split("\n") |> Enum.map(&String.trim/1)

  # xcodebuild / xcode-select can be missing on a CLT-less Mac; report that as
  # a failed command rather than crash the doctor run.
  defp safe_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {"#{cmd}: #{inspect(e.original)}", 127}
  end
end
