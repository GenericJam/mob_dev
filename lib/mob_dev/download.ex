defmodule MobDev.Download do
  @moduledoc false

  # Fetch, verify and unpack helpers shared by the downloaders (OTP, MLX,
  # TFLite, Python apple/android) and plugin prebuilts.
  #
  # Every artifact mob_dev downloads and then extracts, links or ships is
  # pinned by SHA-256 in `MobDev.Download.Pins`. A download is verified before
  # anything reads it, and an extracted cache is trusted only when it carries
  # the marker `mark_verified/2` writes after a verified extraction.
  # See decisions/2026-11-26-pinned-runtime-downloads.md.

  alias MobDev.Download.Pins

  @marker ".mob_download_sha256"

  @doc """
  Fetch `url` to `dest` via curl. Does no verification; use
  `fetch_verified/3` for anything that gets extracted or executed.
  """
  @spec curl(String.t(), Path.t()) :: :ok | {:error, String.t()}
  def curl(url, dest) do
    case System.cmd("curl", ["-L", "--fail", "--progress-bar", "-o", dest, url],
           stderr_to_stdout: false
         ) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "curl failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  @doc """
  The pinned SHA-256 for `url`, or an error when the URL has no pin. Callers
  look the pin up before fetching, so an unpinned asset is never downloaded.
  """
  @spec pin(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def pin(url) do
    case Pins.sha256(url) do
      nil -> {:error, "no pinned sha256 for #{url}; refusing to download it"}
      sha -> {:ok, sha}
    end
  end

  @doc """
  Fetch `url` to `dest` and check it against `expected_sha256`. On a
  mismatch (or a failed fetch) `dest` is deleted.
  """
  @spec fetch_verified(String.t(), Path.t(), String.t()) :: :ok | {:error, String.t()}
  def fetch_verified(url, dest, expected_sha256) do
    case curl(url, dest) do
      :ok ->
        verify_sha256(dest, expected_sha256)

      {:error, _} = err ->
        File.rm(dest)
        err
    end
  end

  @doc """
  Check the file at `path` against `expected_sha256`. A file that does not
  match is deleted, and the error names both hashes.
  """
  @spec verify_sha256(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def verify_sha256(path, expected_sha256) do
    case sha256_file(path) do
      {:ok, ^expected_sha256} ->
        :ok

      {:ok, actual} ->
        File.rm(path)

        {:error,
         "sha256 mismatch for #{path}: expected #{expected_sha256}, got #{actual}. " <>
           "The file was deleted; it is not the artifact this mob_dev release pins."}

      {:error, _} = err ->
        err
    end
  end

  @doc "Lowercase hex SHA-256 of the file at `path`, read in 2 MiB chunks."
  @spec sha256_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def sha256_file(path) do
    case File.open(path, [:read, :binary], &hash_device/1) do
      {:ok, {:ok, digest}} -> {:ok, Base.encode16(digest, case: :lower)}
      {:ok, {:error, reason}} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
      {:error, reason} -> {:error, "could not open #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp hash_device(io, ctx \\ :crypto.hash_init(:sha256)) do
    case IO.binread(io, 2_097_152) do
      :eof -> {:ok, :crypto.hash_final(ctx)}
      {:error, reason} -> {:error, reason}
      chunk -> hash_device(io, :crypto.hash_update(ctx, chunk))
    end
  end

  @doc """
  Record that `dir` was extracted from an archive verified as `sha256`.
  """
  @spec mark_verified(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def mark_verified(dir, sha256) do
    case File.write(Path.join(dir, @marker), sha256) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not write #{dir}/#{@marker}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  True when `dir` carries the marker for `sha256`. A cache extracted by an
  older mob_dev (no marker) or from a different archive is not trusted.
  """
  @spec verified?(Path.t(), String.t() | nil) :: boolean()
  def verified?(_dir, nil), do: false
  def verified?(dir, sha256), do: File.read(Path.join(dir, @marker)) == {:ok, sha256}

  @doc """
  The path beside `dest` to download `url` into: in the user's cache, not at
  a predictable name in a shared temp directory. The name is fixed per asset,
  so an interrupted download is overwritten by the next attempt.
  """
  @spec staging_path(Path.t(), String.t()) :: Path.t()
  def staging_path(dest, url),
    do: Path.join(Path.dirname(dest), ".download-#{Path.basename(url)}")

  @doc """
  Extract the gzipped `tarball` into `dest_dir`.

  The member list is checked before anything is written: absolute names,
  `..` segments, entry types other than file/directory/symlink, and members
  stored beneath a symlink (compared after `:strip_components` and
  case-insensitively, as macOS resolves paths) are refused. After extraction
  the tree is made owner-readable and every symlink must resolve inside
  `dest_dir` (following links, so a chain cannot climb out); offending links
  are removed and an error returned. The caller discards `dest_dir` on error.

  Options: `:strip_components` (default 0), passed to `tar`.
  """
  @spec untar(Path.t(), Path.t(), keyword()) :: :ok | {:error, String.t()}
  def untar(tarball, dest_dir, opts \\ []) do
    strip = Keyword.get(opts, :strip_components, 0)

    with {:ok, entries} <- tar_entries(tarball),
         :ok <- check_entries(entries, tarball, strip),
         :ok <- run_tar(tarball, dest_dir, strip) do
      check_tree(dest_dir)
    end
  end

  @doc """
  Extract `zip` into `dest_dir` with `unzip`, refusing absolute names and
  `..` segments up front and escaping symlinks afterwards (as `untar/3`).
  """
  @spec unzip(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def unzip(zip, dest_dir) do
    with {:ok, entries} <- zip_entries(zip),
         :ok <- check_entries(entries, zip, 0),
         :ok <- run_unzip(zip, dest_dir) do
      check_tree(dest_dir)
    end
  end

  defp tar_entries(tarball) do
    case :erl_tar.table(String.to_charlist(tarball), [:compressed, :verbose]) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn row -> {to_string(elem(row, 0)), elem(row, 1)} end)}

      {:error, reason} ->
        {:error, "could not list #{tarball}: #{:erl_tar.format_error(reason)}"}
    end
  end

  defp zip_entries(zip) do
    case :zip.list_dir(String.to_charlist(zip)) do
      {:ok, items} ->
        {:ok, for({:zip_file, name, _, _, _, _} <- items, do: zip_entry(to_string(name)))}

      {:error, reason} ->
        {:error, "could not list #{zip}: #{inspect(reason)}"}
    end
  end

  defp zip_entry(name),
    do: {name, if(String.ends_with?(name, "/"), do: :directory, else: :regular)}

  @doc false
  # Member-list policy shared by tar and zip. `entries` are `{name, type}`
  # with erl_tar's type atoms; `strip` is the --strip-components tar applies.
  @spec check_entries([{String.t(), atom()}], Path.t(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  def check_entries(entries, archive, strip) do
    symlinks =
      for {name, :symlink} <- entries,
          key <- landing_keys(name, strip),
          into: MapSet.new(),
          do: key

    Enum.find_value(entries, :ok, fn {name, type} ->
      case entry_problem(name, type, strip, symlinks) do
        nil -> nil
        problem -> {:error, "refusing to extract #{archive}: member #{inspect(name)} #{problem}"}
      end
    end)
  end

  defp entry_problem(name, type, strip, symlinks) do
    cond do
      type not in [:regular, :directory, :symlink] -> "is a #{type} entry (hard link or device)"
      Path.type(name) != :relative -> "has an absolute path"
      ".." in String.split(name, "/") -> "has a .. segment"
      under_symlink?(name, strip, symlinks) -> "is stored beneath a symlink"
      true -> nil
    end
  end

  # Where a member lands after --strip-components, as folded segments. bsdtar
  # and GNU tar count a `./` prefix as a component; both readings are kept
  # (counted and not counted) so a tar that differs is still covered. Names
  # are folded the way a case- and normalization-insensitive filesystem
  # (APFS) compares them.
  defp landings(name, strip) do
    parts = String.split(name, "/", trim: true)
    dotted = parts |> Enum.drop(strip) |> Enum.reject(&(&1 == "."))
    plain = parts |> Enum.reject(&(&1 == ".")) |> Enum.drop(strip)

    [dotted, plain] |> Enum.uniq() |> Enum.map(fn segs -> Enum.map(segs, &fold/1) end)
  end

  defp landing_keys(name, strip), do: name |> landings(strip) |> Enum.map(&Enum.join(&1, "/"))

  defp fold(segment) do
    case :unicode.characters_to_nfc_binary(segment) do
      nfc when is_binary(nfc) -> String.downcase(nfc)
      _ -> segment
    end
  end

  defp under_symlink?(name, strip, symlinks) do
    Enum.any?(landings(name, strip), fn segs ->
      Enum.any?(1..(length(segs) - 1)//1, fn n ->
        MapSet.member?(symlinks, segs |> Enum.take(n) |> Enum.join("/"))
      end)
    end)
  end

  defp run_tar(tarball, dest_dir, strip) do
    strip_args = if strip > 0, do: ["--strip-components=#{strip}"], else: []

    case System.cmd("tar", ["xzf", tarball, "-C", dest_dir] ++ strip_args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "tar failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  defp run_unzip(zip, dest_dir) do
    case System.cmd("unzip", ["-q", "-o", zip, "-d", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "unzip failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  # Make the extracted tree owner-traversable (an archive can ship a directory
  # without read permission, which would hide what is inside it from the
  # symlink scan and from cleanup), then check its symlinks.
  defp check_tree(root) do
    case System.cmd("chmod", ["-R", "u+rwX", root], stderr_to_stdout: true) do
      {_, 0} -> check_symlinks(root)
      {out, rc} -> {:error, "chmod of #{root} failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  @doc false
  # Every symlink under `root` must resolve (through any other links) to a
  # path inside `root`. Offending links are deleted. A directory that cannot
  # be listed is an error, not an empty directory.
  @spec check_symlinks(Path.t()) :: :ok | {:error, String.t()}
  def check_symlinks(root) do
    root_cl = String.to_charlist(root)

    with {:ok, links} <- symlinks_under(root, "") do
      escaping =
        Enum.filter(
          links,
          &(:filelib.safe_relative_path(String.to_charlist(&1), root_cl) == :unsafe)
        )

      case escaping do
        [] ->
          :ok

        links ->
          Enum.each(links, &File.rm(Path.join(root, &1)))

          {:error,
           "refusing archive extracted into #{root}: symlink(s) " <>
             Enum.map_join(links, ", ", &inspect/1) <> " point outside it"}
      end
    end
  end

  defp symlinks_under(root, rel) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case symlink_entry(root, Path.join(rel, name)) do
            {:ok, found} -> {:cont, {:ok, found ++ acc}}
            err -> {:halt, err}
          end
        end)

      {:error, reason} ->
        {:error, "could not inspect #{Path.join(root, rel)}: #{:file.format_error(reason)}"}
    end
  end

  defp symlink_entry(root, rel) do
    case File.lstat(Path.join(root, rel)) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, [rel]}

      {:ok, %File.Stat{type: :directory}} ->
        symlinks_under(root, rel)

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "could not inspect #{Path.join(root, rel)}: #{:file.format_error(reason)}"}
    end
  end
end
