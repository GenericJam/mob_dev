defmodule MobDev.OtpRequiredApps do
  @moduledoc """
  The applications a Mob app needs at runtime, so no slim pass strips one.

  Every slim pass (`MobDev.OtpAssetBundle` for the Android release, the iOS
  release script in `MobDev.Release`, `MobDev.OtpAudit.Slim` for
  `mix mob.deploy --slim`) drops whole OTP libs from the bundled runtime. If a
  shipped app lists a dropped lib in its `.app` `applications` or
  `included_applications`, starting that app fails on the device, e.g.
  `{:inets, {~c"no such file or directory", ~c"inets.app"}}`. Debug deploys
  ship the full OTP tree, so the failure only shows in release builds.

  The closure starts from the project's runtime dependency set
  (`MobDev.HotPush.runtime_lib_names/0`, which walks the `.app` files under
  `_build`) and continues through the `.app` files of the OTP tree being
  bundled, so an OTP lib needed only by another OTP lib is kept as well.
  """

  @doc """
  Every app the current Mix project needs at runtime, resolved against the
  OTP tree at `otp_tree`. A slim pass must not strip any name in it.
  """
  @spec for_project(Path.t()) :: MapSet.t(String.t())
  def for_project(otp_tree), do: closure(otp_tree, MobDev.HotPush.runtime_lib_names())

  @doc """
  `seeds` plus every app they need, transitively, through the
  `lib/*/ebin/*.app` files of `otp_tree`. Names with no `.app` in the tree are
  kept as they are.
  """
  @spec closure(Path.t(), Enumerable.t()) :: MapSet.t(String.t())
  def closure(otp_tree, seeds) do
    index =
      otp_tree
      |> Path.join("lib/*/ebin/*.app")
      |> Path.wildcard()
      |> Enum.flat_map(fn app_file ->
        case read_app(app_file) do
          {:ok, name, deps} -> [{name, deps}]
          :error -> []
        end
      end)
      |> Map.new()

    expand(MapSet.new(seeds, &to_string/1), index)
  end

  @doc """
  The apps the `.app` file at `path` needs started or loaded: its
  `applications` and `included_applications`. `[]` when it can't be read.
  """
  @spec app_dependencies(Path.t()) :: [String.t()]
  def app_dependencies(path) do
    case read_app(path) do
      {:ok, _name, deps} -> deps
      :error -> []
    end
  end

  defp read_app(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, name, props}]} when is_list(props) ->
        deps =
          Keyword.get(props, :applications, []) ++
            Keyword.get(props, :included_applications, [])

        {:ok, to_string(name), Enum.map(deps, &to_string/1)}

      _ ->
        :error
    end
  end

  defp expand(set, index) do
    new =
      set
      |> Enum.flat_map(&Map.get(index, &1, []))
      |> MapSet.new()
      |> MapSet.difference(set)

    if MapSet.size(new) == 0, do: set, else: expand(MapSet.union(set, new), index)
  end
end
