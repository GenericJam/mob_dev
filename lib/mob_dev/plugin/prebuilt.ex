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

  ## Offline builds and mirrors

  Set `MOB_PLUGIN_PREBUILT_DIR=/path/to/dir` to take each tarball from
  `<dir>/<file name of the url>` instead of downloading it. The `sha256` is
  checked all the same.
  """

  @marker ".mob_prebuilt_sha256"
  @local_dir_env "MOB_PLUGIN_PREBUILT_DIR"

  # A `.partial-*` sibling older than this is a fetch that died (the VM halted
  # before its `after` ran); younger ones may belong to a build still running.
  @stale_partial_seconds 3600

  @typedoc "A cpp_archive entry's `:prebuilt` map."
  @type t :: %{
          required(:url) => String.t(),
          required(:sha256) => String.t(),
          optional(:static_libs) => %{optional(atom()) => [String.t()]}
        }

  # ── Pure surface ──────────────────────────────────────────────────────────

  @doc """
  Structural problems with a `:prebuilt` map, as messages (empty when it is
  well formed): the URL must be https, the `sha256` 64 lowercase hex characters,
  and `:static_libs` a map of `CppArchive` targets to relative paths that stay
  inside the bundle. `MobDev.Plugin.Manifest.validate/1` reports these, and
  `prepare/2` refuses a bundle that has any, since a host build does not run
  manifest validation. Pure.
  """
  @spec errors(term()) :: [String.t()]
  def errors(%{} = prebuilt) do
    url_errors(prebuilt[:url]) ++ sha_errors(prebuilt[:sha256]) ++ lib_errors(prebuilt)
  end

  def errors(other), do: [":prebuilt must be a map, got: #{inspect(other)}"]

  @doc "A path inside an extracted bundle: relative, no `..` component. Pure."
  @spec bundle_relative?(term()) :: boolean()
  def bundle_relative?(path) when is_binary(path) and path != "",
    do: Path.type(path) == :relative and ".." not in Path.split(path)

  def bundle_relative?(_), do: false

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

  # ── Build entrypoint ──────────────────────────────────────────────────────

  @doc """
  Make a `Merge.static_archives/2` spec ready for `CppArchive.build/3` on
  `target_id`: fetch its prebuilt bundle (when it declares one), resolve
  `{:prebuilt, _}` includes, and return the bundle archives to link.

  Returns `{:ok, spec, link_libs}`; a spec without `:prebuilt` comes back
  unchanged with `[]`. Fails, with a message, on a malformed `:prebuilt` or
  include, a failed download, hash or extraction, or a listed archive missing
  from the bundle.
  """
  @spec prepare(map(), atom()) :: {:ok, map(), [Path.t()]} | {:error, String.t()}
  def prepare(spec, target_id) do
    includes = Map.get(spec, :includes, [])
    prebuilt_includes = for {:prebuilt, sub} <- includes, do: sub

    case Map.get(spec, :prebuilt) do
      nil when prebuilt_includes == [] ->
        {:ok, spec, []}

      nil ->
        {:error, "#{label(spec)}: {:prebuilt, _} include but no :prebuilt declared"}

      prebuilt ->
        problems =
          errors(prebuilt) ++
            for sub <- prebuilt_includes,
                not bundle_relative?(sub),
                do: "{:prebuilt, #{inspect(sub)}} include must stay inside the bundle"

        with :ok <- no_problems(spec, problems),
             {:ok, root} <- ensure(prebuilt),
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
      sweep_stale_partials(dest)

      with :ok <- posix(File.rm_rf(dest) |> rm_rf_result(), "remove #{dest}"),
           :ok <- posix(File.mkdir_p(Path.dirname(dest)), "create #{Path.dirname(dest)}") do
        fetch(url, sha, dest)
      end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp url_errors("https://" <> _), do: []
  defp url_errors(url), do: [":prebuilt :url must be an https:// URL, got: #{inspect(url)}"]

  defp sha_errors(sha) when is_binary(sha) do
    if sha =~ ~r/\A[0-9a-f]{64}\z/,
      do: [],
      else: [":prebuilt :sha256 must be 64 lowercase hex characters"]
  end

  defp sha_errors(_), do: [":prebuilt requires a :sha256 of the tarball"]

  defp lib_errors(prebuilt) do
    targets = MobDev.Plugin.CppArchive.targets()

    case Map.get(prebuilt, :static_libs, %{}) do
      %{} = libs ->
        for {target, paths} <- libs,
            error <- lib_entry_errors(target, paths, targets),
            do: error

      other ->
        [":prebuilt :static_libs must be a map of target => paths, got: #{inspect(other)}"]
    end
  end

  defp lib_entry_errors(target, paths, targets) do
    cond do
      target not in targets ->
        [":prebuilt :static_libs key #{inspect(target)} is not one of #{inspect(targets)}"]

      not (is_list(paths) and Enum.all?(paths, &bundle_relative?/1)) ->
        [
          ":prebuilt :static_libs #{inspect(target)} must be a list of relative paths " <>
            "inside the bundle"
        ]

      true ->
        []
    end
  end

  defp no_problems(_spec, []), do: :ok

  defp no_problems(spec, problems),
    do: {:error, "#{label(spec)}: " <> Enum.join(problems, "; ")}

  defp cached?(dest, sha), do: File.read(Path.join(dest, @marker)) == {:ok, sha}

  # The tarball and the extraction both live beside `dest` (same filesystem, so
  # the final rename is atomic) under a name unique to this OS process.
  defp fetch(url, sha, dest) do
    tag = "#{System.pid()}-#{System.unique_integer([:positive])}"
    staging = "#{dest}.partial-#{tag}"
    tarball = staging <> ".tgz"

    try do
      with {:ok, source} <- obtain(url, tarball),
           :ok <- verify_sha256(source, sha, url),
           :ok <- posix(File.mkdir_p(staging), "create #{staging}"),
           :ok <- MobDev.Download.untar(source, staging),
           :ok <- posix(File.write(Path.join(staging, @marker), sha), "write #{staging}") do
        install(staging, dest, sha)
      end
    after
      File.rm(tarball)
      File.rm_rf(staging)
    end
  end

  # The tarball to verify: a local copy when MOB_PLUGIN_PREBUILT_DIR is set,
  # otherwise a download to `tarball`.
  defp obtain(url, tarball) do
    case System.get_env(@local_dir_env) do
      dir when dir in [nil, ""] ->
        IO.puts("  Downloading plugin prebuilt #{url}")

        with :ok <- MobDev.Download.curl(url, tarball), do: {:ok, tarball}

      dir ->
        local = Path.join(dir, url_file_name(url))

        if File.regular?(local) do
          IO.puts("  Using local plugin prebuilt #{local}")
          {:ok, local}
        else
          {:error, "#{@local_dir_env} is set to #{dir} but #{url_file_name(url)} is not there"}
        end
    end
  end

  # Moves the finished extraction into place. A concurrent build may have
  # installed the same bundle first; its copy is just as good.
  defp install(staging, dest, sha) do
    case File.rename(staging, dest) do
      :ok ->
        IO.puts("  Cached plugin prebuilt at #{dest}")
        {:ok, dest}

      {:error, reason} ->
        if cached?(dest, sha),
          do: {:ok, dest},
          else: {:error, "could not move prebuilt into #{dest}: #{:file.format_error(reason)}"}
    end
  end

  defp verify_sha256(path, expected, url) do
    with {:ok, actual} <- sha256_file(path) do
      if actual == expected,
        do: :ok,
        else:
          {:error,
           "prebuilt #{url} has sha256 #{actual}, but the plugin manifest pins " <>
             "#{expected}; refusing to use it"}
    end
  end

  defp sha256_file(path) do
    case File.open(path, [:read, :binary], &hash_device/1) do
      {:ok, {:ok, digest}} -> {:ok, Base.encode16(digest, case: :lower)}
      {:ok, {:error, reason}} -> posix({:error, reason}, "read #{path}")
      {:error, reason} -> posix({:error, reason}, "open #{path}")
    end
  end

  defp hash_device(io, ctx \\ :crypto.hash_init(:sha256)) do
    case IO.binread(io, 2_097_152) do
      :eof -> {:ok, :crypto.hash_final(ctx)}
      {:error, reason} -> {:error, reason}
      chunk -> hash_device(io, :crypto.hash_update(ctx, chunk))
    end
  end

  defp sweep_stale_partials(dest) do
    cutoff = System.os_time(:second) - @stale_partial_seconds
    parent = Path.dirname(dest)
    prefix = Path.basename(dest) <> ".partial-"

    with {:ok, names} <- File.ls(parent) do
      for name <- names,
          String.starts_with?(name, prefix),
          path = Path.join(parent, name),
          {:ok, %File.Stat{mtime: mtime}} <- [File.lstat(path, time: :posix)],
          mtime < cutoff,
          do: File.rm_rf(path)
    end
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

  defp rm_rf_result({:ok, _}), do: :ok
  defp rm_rf_result({:error, reason, _path}), do: {:error, reason}

  defp posix(:ok, _what), do: :ok

  defp posix({:error, reason}, what),
    do: {:error, "could not #{what}: #{:file.format_error(reason)}"}

  defp label(spec), do: "plugin cpp_archive #{spec[:plugin]}/#{spec[:module]}"

  defp url_file_name(url) do
    url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename()
  end

  defp stem(url) do
    url
    |> url_file_name()
    |> String.replace(~r/(\.tar\.gz|\.tgz)$/, "")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp cache_root do
    System.get_env("MOB_CACHE_DIR") ||
      Path.join([System.get_env("HOME") || ".", ".mob", "cache"])
  end
end
