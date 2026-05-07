defmodule MobDev.SecurityScan.BundledRuntime.Fingerprint do
  @moduledoc """
  Extracts versions from `~/.mob/cache/otp-*-{hash}/` and from exqlite
  C sources in a project's `deps/`.

  This module is the *receipt* side of the manifest-first design.
  `BundledVersions` records what we *claim* shipped; `Fingerprint`
  reads what's *actually* on disk. The bundled-runtime scan layer
  asserts they agree.

  Pure functions only — no advisory feed lookups, no severity
  judgements. The fingerprinter answers "what version is this binary?"
  and nothing else.
  """

  @cache_dir Path.join([System.user_home() || "/", ".mob", "cache"])

  @typedoc """
  One cached tarball found on disk.
  `:platform` is decoded from the directory name; `:hash` is the trailing
  OTP commit hash from `MobDev.OtpDownloader`.
  """
  @type tarball :: %{
          platform: :android | :android_arm32 | :ios_sim | :ios_device,
          hash: String.t(),
          path: Path.t()
        }

  @typedoc """
  Versions extracted from a single tarball. Any field may be `nil` if
  fingerprinting failed for that artifact (e.g. libcrypto.a was stripped
  in an unexpected way). The layer reports such cases as findings, not
  silent failures.
  """
  @type tarball_versions :: %{
          erts: String.t() | nil,
          elixir: String.t() | nil,
          openssl: String.t() | nil,
          exqlite_beam: String.t() | nil
        }

  @doc """
  Locate every cached OTP tarball under `~/.mob/cache/`.

  Returns a list of `tarball/0` entries, sorted by platform then hash
  for stable output. Filters out anything that isn't a directory or
  doesn't match the `otp-{platform}-{hash}` naming scheme.

  Pass `:cache_dir` to override the default path (used in tests).
  """
  @spec locate_cached_tarballs(keyword()) :: [tarball()]
  def locate_cached_tarballs(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, @cache_dir)

    case File.ls(cache_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(cache_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&decode_tarball_dir/1)
        |> Enum.sort_by(&{&1.platform, &1.hash})

      {:error, _} ->
        []
    end
  end

  defp decode_tarball_dir(path) do
    case Regex.run(~r/^otp-(android-arm32|android|ios-sim|ios-device)-([0-9a-f]+)$/, Path.basename(path)) do
      [_, "android", hash] -> [%{platform: :android, hash: hash, path: path}]
      [_, "android-arm32", hash] -> [%{platform: :android_arm32, hash: hash, path: path}]
      [_, "ios-sim", hash] -> [%{platform: :ios_sim, hash: hash, path: path}]
      [_, "ios-device", hash] -> [%{platform: :ios_device, hash: hash, path: path}]
      _ -> []
    end
  end

  @doc """
  Fingerprint a single tarball directory. Returns the versions
  extracted from disk.
  """
  @spec fingerprint_tarball(Path.t()) :: tarball_versions()
  def fingerprint_tarball(tarball_path) do
    %{
      erts: extract_erts_version(tarball_path),
      elixir: extract_elixir_version(tarball_path),
      openssl: extract_openssl_version(tarball_path),
      exqlite_beam: extract_exqlite_version(tarball_path)
    }
  end

  @doc """
  Fingerprint the SQLite version compiled into exqlite from a
  project's `deps/exqlite/c_src/sqlite3.c`. SQLite is bundled per-app
  via the exqlite Hex package, not via the OTP tarball, so it's
  scanned at the project level.
  """
  @spec fingerprint_sqlite(Path.t()) :: {:ok, String.t()} | {:error, :not_found | :unparseable}
  def fingerprint_sqlite(project_root) do
    path = Path.join([project_root, "deps", "exqlite", "c_src", "sqlite3.c"])

    cond do
      not File.exists?(path) ->
        {:error, :not_found}

      true ->
        # SQLite source files are tens of MB; only read the head where
        # the version macro lives.
        case File.open(path, [:read, :utf8], &read_sqlite_version/1) do
          {:ok, {:ok, version}} -> {:ok, version}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, _} -> {:error, :unparseable}
        end
    end
  end

  defp read_sqlite_version(io) do
    # Linear scan — the macro is in the first ~200 lines of sqlite3.c
    # historically. Bail after 5000 lines as a safety net.
    Enum.reduce_while(1..5000, {:error, :unparseable}, fn _, _acc ->
      case IO.read(io, :line) do
        :eof ->
          {:halt, {:error, :unparseable}}

        {:error, _} = e ->
          {:halt, e}

        line ->
          case Regex.run(~r/^#define\s+SQLITE_VERSION\s+"([^"]+)"/, line) do
            [_, version] -> {:halt, {:ok, version}}
            nil -> {:cont, {:error, :unparseable}}
          end
      end
    end)
  end

  defp extract_erts_version(tarball_path) do
    tarball_path
    |> Path.join("erts-*")
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> nil
      path -> path |> Path.basename() |> String.replace_prefix("erts-", "")
    end
  end

  defp extract_elixir_version(tarball_path) do
    app_file = Path.join([tarball_path, "lib", "elixir", "ebin", "elixir.app"])

    case File.read(app_file) do
      {:ok, content} ->
        case Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content) do
          [_, version] -> version
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp extract_exqlite_version(tarball_path) do
    tarball_path
    |> Path.join(["lib", "/", "exqlite-*"])
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> nil
      path -> path |> Path.basename() |> String.replace_prefix("exqlite-", "")
    end
  end

  defp extract_openssl_version(tarball_path) do
    libcrypto =
      [tarball_path, "erts-*", "lib", "libcrypto.a"]
      |> Path.join()
      |> Path.wildcard()
      |> List.first()

    cond do
      libcrypto == nil -> nil
      not File.exists?(libcrypto) -> nil
      true -> scan_openssl_version_string(libcrypto)
    end
  end

  # OpenSSL embeds its version banner in libcrypto.a's .rodata as
  #
  #     OpenSSL <version> <DD Mon YYYY>\0
  #
  # e.g. "OpenSSL 3.4.0 22 Oct 2024". libcrypto also contains lots of
  # other strings starting with "OpenSSL " ("OpenSSL default", "OpenSSL
  # DH Method", etc.), so we have to scan every match and pick the one
  # whose second token looks like a version. No `strings` binary needed.
  defp scan_openssl_version_string(path) do
    case File.read(path) do
      {:ok, content} -> scan_for_version_banner(content)
      _ -> nil
    end
  end

  defp scan_for_version_banner(content) do
    content
    |> :binary.matches("OpenSSL ")
    |> Enum.find_value(&match_version_at(content, &1))
  end

  defp match_version_at(content, {pos, _len}) do
    blob =
      content
      |> :binary.part(pos, min(64, byte_size(content) - pos))
      |> :binary.split(<<0>>)
      |> List.first()

    case Regex.run(~r/^OpenSSL\s+(\d+\.\d+\.\d+[a-z]?)\b/, blob) do
      [_, version] -> version
      _ -> nil
    end
  end
end
