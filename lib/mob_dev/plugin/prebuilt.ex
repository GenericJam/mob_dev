defmodule MobDev.Plugin.Prebuilt do
  @moduledoc """
  Fetches the prebuilt bundle a `lang: :cpp_archive` plugin NIF declares under
  `:prebuilt`, and resolves the headers and static libraries it contributes.

  Some plugin NIFs sit on a large third-party C++ library that ships prebuilt:
  mob_scene3d's iOS renderer is Objective-C++ against Filament, whose release
  tarball carries the headers plus one static-library xcframework per component.
  That can't ride in a Hex package (tens of MB), and the plugin's own `.a`
  (`MobDev.Plugin.CppArchive`) only holds objects compiled from its sources. A
  cpp_archive entry therefore names the bundle and what to take from it:

      %{
        module: :mob_scene3d_nif,
        lang: :cpp_archive,
        platform: :ios,
        sources: ["priv/native/ios/mob_scene3d_nif.m", "priv/native/ios/MobScene3dView.mm"],
        includes: ["priv/native/ios", {:prebuilt, "filament/include"}],
        nm_symbol: "mob_scene3d_nif_nif_init",
        prebuilt: %{
          url: "https://github.com/google/filament/releases/download/v1.75.1/filament-v1.75.1-ios.tgz",
          sha256: "afdfdccfb0870a667c73400d9e81e5ec69c8604d867fc4430b9fbfe72934ade3",
          static_libs: %{
            ios_sim: ["filament/lib/libfilament.xcframework/ios-arm64_x86_64-simulator/libfilament.a"],
            ios_device: ["filament/lib/libfilament.xcframework/ios-arm64/libfilament.a"]
          }
        }
      }

  - `{:prebuilt, subpath}` in `:includes` is a directory inside the extracted
    bundle, passed to the compiler as `-I`.
  - `:static_libs` maps a `CppArchive` target id to archives inside the bundle.
    They are linked into the app beside `lib<module>.a`, through the same
    `-Dplugin_static_libs` / `MOB_PLUGIN_STATIC_LIBS` inputs, so the simulator
    and device deploys and `mix mob.release --ios` all link them.

  The bundle is downloaded once per `sha256` into
  `~/.mob/cache/plugin-prebuilt/` (or `$MOB_CACHE_DIR/plugin-prebuilt/`) and
  shared by every project, the `MobDev.MLXDownloader` pattern. The tarball must
  hash to the manifest's `sha256` before anything is extracted: the manifest is
  covered by the plugin signature, so the pin carries that trust to a file the
  signature cannot cover.
  """

  @marker ".mob_prebuilt_sha256"

  @typedoc "A cpp_archive entry's `:prebuilt` map."
  @type t :: %{
          required(:url) => String.t(),
          required(:sha256) => String.t(),
          optional(:static_libs) => %{optional(atom()) => [String.t()]}
        }

  # ── Pure surface ──────────────────────────────────────────────────────────

  @doc """
  Cache directory for a bundle: `<cache>/plugin-prebuilt/<name>-<sha256 prefix>`,
  where `<name>` is the URL's file name without its tarball extension. Keyed by
  the hash, so a manifest that pins a new file gets a new directory. Pure apart
  from reading `MOB_CACHE_DIR` / `HOME`.
  """
  @spec dir(t()) :: Path.t()
  def dir(%{url: url, sha256: sha}) do
    Path.join([cache_root(), "plugin-prebuilt", "#{stem(url)}-#{binary_part(sha, 0, 12)}"])
  end

  @doc """
  Replace each `{:prebuilt, subpath}` include with its path under `root`; other
  entries pass through unchanged. Pure.
  """
  @spec resolve_includes([term()], Path.t()) :: [term()]
  def resolve_includes(includes, root) when is_list(includes) do
    for entry <- includes do
      case entry do
        {:prebuilt, sub} -> Path.join(root, sub)
        other -> other
      end
    end
  end

  @doc """
  The bundle's archives to link for `target_id`, as absolute paths under `root`.
  A target the manifest doesn't list links none. Pure.
  """
  @spec static_libs(t(), atom(), Path.t()) :: [Path.t()]
  def static_libs(prebuilt, target_id, root) do
    for rel <- Map.get(prebuilt[:static_libs] || %{}, target_id, []), do: Path.join(root, rel)
  end

  @doc "Whether an `:includes` list references the prebuilt bundle. Pure."
  @spec uses_prebuilt?([term()]) :: boolean()
  def uses_prebuilt?(includes), do: Enum.any?(includes, &match?({:prebuilt, _}, &1))

  # ── Build entrypoint ──────────────────────────────────────────────────────

  @doc """
  Make a `Merge.static_archives/2` spec ready for `CppArchive.build/3` on
  `target_id`: fetch its prebuilt bundle (when it declares one), resolve
  `{:prebuilt, _}` includes, and return the bundle archives to link.

  Returns `{:ok, spec, link_libs}`; a spec without `:prebuilt` comes back
  unchanged with `[]`. Fails when the download, the hash or the extraction
  fails, or when a listed archive is missing from the bundle.
  """
  @spec prepare(map(), atom()) :: {:ok, map(), [Path.t()]} | {:error, String.t()}
  def prepare(spec, target_id) do
    includes = Map.get(spec, :includes, [])

    case Map.get(spec, :prebuilt) do
      nil ->
        if uses_prebuilt?(includes),
          do: {:error, "#{label(spec)}: {:prebuilt, _} include but no :prebuilt declared"},
          else: {:ok, spec, []}

      prebuilt ->
        with {:ok, root} <- ensure(prebuilt),
             libs = static_libs(prebuilt, target_id, root),
             :ok <- check_libs(libs, prebuilt, root) do
          {:ok, %{spec | includes: resolve_includes(includes, root)}, libs}
        end
    end
  end

  @doc """
  Ensure the bundle is downloaded, verified and extracted. Returns
  `{:ok, dir}` (see `dir/1`). A cached extraction is reused only when it records
  the same `sha256`; anything else in its place is removed and fetched again.
  """
  @spec ensure(t()) :: {:ok, Path.t()} | {:error, String.t()}
  def ensure(%{url: url, sha256: sha} = prebuilt) do
    dest = dir(prebuilt)

    if cached?(dest, sha) do
      {:ok, dest}
    else
      File.rm_rf!(dest)
      fetch(url, sha, dest)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp cached?(dest, sha), do: File.read(Path.join(dest, @marker)) == {:ok, sha}

  defp fetch(url, sha, dest) do
    tag = "#{binary_part(sha, 0, 12)}-#{System.unique_integer([:positive])}"
    tarball = Path.join(System.tmp_dir!(), "mob-prebuilt-#{tag}.tgz")
    staging = "#{dest}.partial-#{tag}"

    IO.puts("  Downloading plugin prebuilt #{url}")

    try do
      with :ok <- MobDev.Download.curl(url, tarball),
           :ok <- verify_sha256(tarball, sha, url),
           :ok <- File.mkdir_p(staging),
           :ok <- MobDev.Download.untar(tarball, staging),
           :ok <- File.write(Path.join(staging, @marker), sha) do
        install(staging, dest, sha)
      end
    after
      File.rm(tarball)
      File.rm_rf(staging)
    end
  end

  # Moves the finished extraction into place. A concurrent build may have
  # installed the same bundle first; its copy is just as good.
  defp install(staging, dest, sha) do
    File.mkdir_p!(Path.dirname(dest))

    case File.rename(staging, dest) do
      :ok ->
        IO.puts("  Cached plugin prebuilt at #{dest}")
        {:ok, dest}

      {:error, reason} ->
        if cached?(dest, sha),
          do: {:ok, dest},
          else: {:error, "could not move prebuilt into #{dest}: #{inspect(reason)}"}
    end
  end

  defp verify_sha256(path, expected, url) do
    actual =
      path
      |> File.stream!(2_097_152)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else:
        {:error,
         "prebuilt #{url} has sha256 #{actual}, but the plugin manifest pins " <>
           "#{expected}; refusing to use it"}
  end

  defp check_libs(libs, prebuilt, root) do
    case Enum.reject(libs, &File.regular?/1) do
      [] ->
        :ok

      missing ->
        {:error,
         "prebuilt #{prebuilt.url} (extracted at #{root}) has no " <>
           Enum.map_join(missing, ", ", &Path.relative_to(&1, root)) <>
           " — the manifest's static_libs don't match the bundle's layout"}
    end
  end

  defp label(spec), do: "plugin cpp_archive #{spec[:plugin]}/#{spec[:module]}"

  defp stem(url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/(\.tar\.gz|\.tgz)$/, "")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp cache_root do
    System.get_env("MOB_CACHE_DIR") ||
      Path.join([System.get_env("HOME") || ".", ".mob", "cache"])
  end
end
