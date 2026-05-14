defmodule MobDev.SupportMatrix do
  @moduledoc """
  Per-feature device requirements + the validation that runs before
  `mix mob.deploy` builds anything.

  The instinct is to ship the latest-arch path because that's where the
  upstream toolchains are easiest to integrate. The cost of that
  instinct is silent failure: a user with an older / cheaper / 32-bit
  device buys hardware, runs `mix mob.deploy`, sees a vague gradle
  error, and walks away assuming Mob is broken. They never find out
  the device was below our floor.

  This module makes the floors explicit, declarable, and enforced:

    * `feature_requirements/1` — the data. What ABIs / SDK levels does
      a feature need? Where does the constraint come from upstream
      (Chaquopy, BeeWare, Apple)?
    * `enabled_features/1` — what features does *this* project use?
      Inferred from the project's mix.exs / generated files, not from
      a flag the user has to remember to set.
    * `check_device/2` — given a device's discovered properties + a
      list of enabled features, return `:ok` or
      `{:error, [%{feature, reason, device}]}`.

  `mix mob.deploy` calls these before invoking `MobDev.NativeBuild` so
  the message a user sees on an unsupported device is:

      ✗ Moto e (armeabi-v7a, Android 10) cannot run this project:
          - pythonx requires Android arm64-v8a or x86_64. Chaquopy
            (the upstream Python distribution we bundle) dropped
            32-bit Android support several releases ago.

      To target this device, either disable Pythonx or use an arm64
      device. See guides/support_matrix.md for the full floor.

  …rather than a build that silently produces an APK the device can't
  load.

  ## Adding a new feature

  When you add a feature that has device requirements distinct from
  the base Mob floor, add a clause to `feature_requirements/1` and a
  detection clause to `enabled_features/1`. Don't bury the constraint
  in build-time code — that's how silent failures happen.
  """

  alias MobDev.Device

  @typedoc "Requirement spec for a single feature on a single platform."
  @type platform_req :: %{
          required(:abis) => [String.t()],
          required(:min_sdk) => non_neg_integer(),
          optional(:reason) => String.t()
        }

  @typedoc """
  Full requirement spec for a feature. No feature currently models
  `:unsupported` (a feature outright incompatible with a platform) —
  if one needs to, add `| :unsupported` to the platform value type
  here AND re-add the matching case clause in `check_against/2`.
  """
  @type feature_req :: %{
          required(:android) => platform_req(),
          required(:ios) => platform_req()
        }

  @typedoc "An incompatibility found by check_device/2."
  @type incompatibility :: %{
          device: Device.t(),
          feature: atom(),
          reason: String.t()
        }

  # ── Base Mob floor ─────────────────────────────────────────────────────────
  #
  # Every Mob app needs at least these. Features that just inherit the
  # floor don't need a separate clause in feature_requirements/1 —
  # they're covered by `:base`.

  # Empirically corrected after a 32-bit Moto e deploy:
  #   - The BEAM, libpigeon.so, and erts helper binaries all build
  #     and run on armeabi-v7a (`mob.install` already fetches an
  #     `otp-android-arm32-*` cache and the gradle build's
  #     abiFilters include armeabi-v7a). A vanilla Mob app boots
  #     through all 5 launcher steps on a 2018-vintage Moto e.
  #   - The 32-bit failure mode lives in `:pythonx`, not the base.
  #     Chaquopy stopped shipping armv7 CPython, so `:pythonx` apps
  #     fall through PythonPaths.detect → `:desktop`, then crash on
  #     `Pythonx.Uv.fetch` because uv has no
  #     `arm-unknown-linux-androideabi` build either.
  @base %{
    android: %{
      abis: ["arm64-v8a", "x86_64", "armeabi-v7a"],
      min_sdk: 28,
      reason:
        "Mob's BEAM/erts is built for arm64-v8a, x86_64 (emulator), " <>
          "and armeabi-v7a. Older 32-bit Android phones (Moto e, " <>
          "low-end devices through ~2018) can run vanilla Mob apps " <>
          "— the per-feature constraints below are what cut deeper."
    },
    ios: %{
      abis: ["arm64"],
      min_sdk: 13,
      reason:
        "Mob targets iOS 13+ and bundles arm64 OTP. The simulator slice is " <>
          "arm64 on Apple Silicon Macs, x86_64 on Intel Macs."
    }
  }

  @doc """
  Returns the base device requirements every Mob app inherits.
  """
  @spec base_requirements() :: feature_req()
  def base_requirements, do: @base

  # ── Per-feature requirements ───────────────────────────────────────────────

  @doc """
  Returns the device requirements for a specific feature.

  Returns `nil` for unknown features (caller should treat as base-only).
  """
  @spec feature_requirements(atom()) :: feature_req() | nil
  def feature_requirements(:base), do: @base

  def feature_requirements(:pythonx) do
    %{
      android: %{
        abis: ["arm64-v8a", "x86_64"],
        min_sdk: 28,
        reason:
          "Pythonx on Android bundles Chaquopy's prebuilt CPython distribution. " <>
            "Chaquopy ships arm64-v8a and x86_64 only — they dropped armeabi-v7a " <>
            "(32-bit ARM) several releases back. On a 32-bit phone the asset " <>
            "extraction yields no usable lib-dynload, MOB_PYTHON_DL stays unset, " <>
            "PythonPaths.detect/1 falls through to :desktop, and Pythonx.Uv.fetch " <>
            "then crashes with \"uv is not available for architecture: " <>
            "arm-unknown-linux-androideabi\" — there's no uv build for armv7 " <>
            "Android either. Verified empirically on a Moto e (Android 10)."
      },
      ios: %{
        abis: ["arm64"],
        min_sdk: 13,
        reason:
          "Pythonx on iOS bundles BeeWare's Python-Apple-support framework " <>
            "(arm64 device + arm64/x86_64 simulator). iOS 13 is the BeeWare floor."
      }
    }
  end

  def feature_requirements(_), do: nil

  # ── Enabled-features detection ─────────────────────────────────────────────

  @doc """
  Returns the list of features enabled in `project_dir` that have
  non-base device requirements.

  Inferred from project artifacts (deps in `mix.exs`, generated source
  files), not from a flag — so a user can't accidentally bypass the
  validation by forgetting an option.
  """
  @spec enabled_features(Path.t()) :: [atom()]
  def enabled_features(project_dir) do
    [
      {:pythonx, &pythonx_enabled?/1}
    ]
    |> Enum.filter(fn {_feature, detect} -> detect.(project_dir) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp pythonx_enabled?(project_dir) do
    mix_exs = Path.join(project_dir, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} -> String.contains?(content, ":pythonx")
      _ -> false
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  @doc """
  Checks that `device` can run the given list of enabled features
  (plus the base Mob floor).

  Returns `:ok` if every requirement is satisfied, or
  `{:error, [incompatibility]}` listing every reason the device is
  unsupported. We collect every reason rather than short-circuiting so
  the user sees the full picture, not a one-at-a-time game of
  whack-a-mole.
  """
  @spec check_device(Device.t(), [atom()]) :: :ok | {:error, [incompatibility()]}
  def check_device(%Device{} = device, features) when is_list(features) do
    issues =
      [:base | features]
      |> Enum.flat_map(&check_against(&1, device))

    case issues do
      [] -> :ok
      _ -> {:error, issues}
    end
  end

  defp check_against(feature, %Device{platform: platform} = device) do
    case feature_requirements(feature) do
      nil ->
        []

      reqs ->
        case Map.get(reqs, platform) do
          %{} = req ->
            check_platform(feature, device, req)

          nil ->
            []
        end
    end
  end

  defp check_platform(feature, %Device{} = device, %{abis: abis, min_sdk: min_sdk} = req) do
    abi_issue =
      cond do
        # Discovery may not populate abi (older mob_dev installs, or
        # iOS where we don't query it). When unknown, we skip the
        # check rather than guess — better silent passthrough than a
        # false positive that blocks a valid device.
        device.abi == nil -> nil
        device.abi in abis -> nil
        true -> abi_message(feature, device, abis, req)
      end

    sdk_issue =
      cond do
        device.sdk_level == nil -> nil
        device.sdk_level >= min_sdk -> nil
        true -> sdk_message(feature, device, min_sdk, req)
      end

    [abi_issue, sdk_issue]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn reason -> %{device: device, feature: feature, reason: reason} end)
  end

  defp abi_message(feature, device, abis, req) do
    base =
      "#{label(feature)} requires #{device.platform} #{Enum.join(abis, " or ")}; " <>
        "this device is #{device.abi}."

    case Map.get(req, :reason) do
      nil -> base
      detail -> base <> " " <> detail
    end
  end

  defp sdk_message(feature, device, min_sdk, req) do
    base =
      "#{label(feature)} requires #{device.platform} SDK/version " <>
        ">= #{min_sdk}; this device is at #{device.sdk_level}."

    case Map.get(req, :reason) do
      nil -> base
      detail -> base <> " " <> detail
    end
  end

  defp label(:base), do: "Mob"
  defp label(feature), do: to_string(feature)

  # ── Pretty error block ─────────────────────────────────────────────────────

  @doc """
  Renders an `{:error, [incompatibility]}` result as the human-readable
  block printed by `mix mob.deploy` before exiting.

  Groups by device so multi-feature failures on one device collapse
  into a single block, then re-displays the device summary line.
  """
  @spec format_error([incompatibility()]) :: String.t()
  def format_error(issues) when is_list(issues) do
    issues
    |> Enum.group_by(& &1.device)
    |> Enum.map_join("\n", fn {device, group} ->
      header = "  ✗ #{Device.summary(device)}"

      reasons =
        group
        |> Enum.map(fn %{reason: reason} -> "      - #{reason}" end)
        |> Enum.join("\n")

      header <> "\n" <> reasons
    end)
  end
end
