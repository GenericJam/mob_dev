defmodule MobDev.Paths do
  @moduledoc """
  Resolution helpers for paths Mob writes to outside the project tree.

  Centralised here so the deployer, the build script, the iOS simulator
  app's `mob_beam.m`, the cache-listing task, and the doctor all agree on
  one answer.
  """

  @doc """
  Returns the directory where the iOS simulator's OTP runtime lives.

  Resolution order:

    1. `MOB_SIM_RUNTIME_DIR` env var if set
    2. `~/.mob/runtime/ios-sim` (new default — managed by `mix mob.cache`)
    3. `/tmp/otp-ios-sim` (legacy fallback for projects whose `ios/build.sh`
       was generated before the env-var-aware template)

  The third branch is the back-compat path: a project's `ios/build.sh` is
  generated once at project creation and kept thereafter, so old projects
  still write the OTP runtime to `/tmp/otp-ios-sim`. We detect that case
  by looking inside the project's own `ios/build.sh` for the
  `MOB_SIM_RUNTIME_DIR` token. If it's missing, the project hasn't been
  regenerated against the new mob_new template and we honor its old
  hardcoded path so `mix mob.deploy` keeps working.

  When `:project_dir` is passed, the build.sh-presence check uses that
  directory; otherwise it uses `File.cwd!/0`. Pure of side effects.
  """
  @spec sim_runtime_dir(keyword()) :: String.t()
  def sim_runtime_dir(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    cond do
      env = System.get_env("MOB_SIM_RUNTIME_DIR") ->
        env

      build_sh_aware?(project_dir) ->
        default_runtime_dir()

      true ->
        legacy_tmp_path()
    end
  end

  @doc """
  The new default runtime path — under `~/.mob/runtime/` so `mix mob.cache`
  can list and clear it the same way it handles the OTP cache.
  """
  @spec default_runtime_dir() :: String.t()
  def default_runtime_dir do
    Path.join([System.user_home!(), ".mob", "runtime", "ios-sim"])
  end

  @doc """
  The pre-runtime-dir-relocation path. Old `ios/build.sh` scripts hardcode
  this; we keep recognising it so existing projects keep deploying.
  """
  @spec legacy_tmp_path() :: String.t()
  def legacy_tmp_path, do: "/tmp/otp-ios-sim"

  @doc """
  True when the project's `ios/build.sh` was generated from a template that
  knows about `MOB_SIM_RUNTIME_DIR` (mob_new ≥ 0.1.20). False if the file
  is missing or predates the env-var support.
  """
  @spec build_sh_aware?(String.t()) :: boolean()
  def build_sh_aware?(project_dir) do
    path = Path.join([project_dir, "ios", "build.sh"])

    case File.read(path) do
      {:ok, content} -> String.contains?(content, "MOB_SIM_RUNTIME_DIR")
      _ -> false
    end
  end
end
