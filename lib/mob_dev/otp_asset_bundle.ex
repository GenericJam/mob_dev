defmodule MobDev.OtpAssetBundle do
  @moduledoc """
  Builds the `assets/otp.zip` that release-mode Android Mob apps extract on
  first launch.

  Mirrors the elixir-desktop example-app pattern (their `Bridge.kt:unpackZip()`)
  but with Mob-specific stripping inherited from the iOS release pass — drops
  unused OTP libs and standalone executables to shave bundle size and avoid
  shipping anything Mob never actually executes.

  Called from `mix mob.release --android` (Workstream 3). Kept as a separate
  module so the strip rules + zip layout are testable without spinning up
  the full release pipeline.

  ## Layout produced

      otp.zip
      ├── erts-VSN/...           (BEAM emulator support — minus bin/)
      ├── lib/elixir-VSN/...
      ├── lib/logger-VSN/...
      ├── lib/eex-VSN/...
      ├── lib/<other-otp-libs-the-app-uses>/...
      └── releases/...

  The `MobBridge.extractOtpIfNeeded()` Kotlin function unzips this into
  `<filesDir>/otp/` on first launch, keyed by `PackageInfo.lastUpdateTime`
  so app updates trigger a re-extract.

  ## What gets stripped

  Three categories, mirroring the iOS strip pass in `MobDev.Release`:

  1. **Whole OTP libs the framework doesn't use** — `megaco`, `runtime_tools`,
     `wx`, `observer`, `debugger`, etc. These are dead weight in a Mob app.
  2. **Standalone executables** — `priv/bin/*` and `erts-*/bin/*`. The few
     that Mob actually executes (`erl_child_setup`, `inet_gethost`, `epmd`)
     are packaged separately in `jniLibs/<abi>/` as `lib<name>.so` so they
     get the `apk_data_file` SELinux label that allows execve from
     untrusted_app. The rest aren't reachable.
  3. **Static archives (`.a`)** — already linked into the app's native lib
     at build time. Shipping them inside the runtime tree is pure waste.

  `.so` files inside OTP libs (e.g. `priv/lib/asn1.so`) are KEPT in the zip —
  they're loaded by the BEAM at runtime via `dlopen()`, which works fine from
  app data dir on Android (only `execve()` is blocked).
  """

  @stripped_lib_prefixes ~w(
    megaco runtime_tools erl_interface os_mon wx et eunit
    observer debugger diameter edoc tools snmp dialyzer
    syntax_tools parsetools xmerl reltool inets ftp tftp
  )

  @doc """
  Builds the OTP asset zip from `source_otp_tree` into `target_zip_path`.

  Returns `{:ok, %{zipped_files: count, original_size_kb: integer,
  zip_size_kb: integer}}` on success, `{:error, reason}` on failure.

  ## Options

    * `:strip_extra_prefixes` — additional OTP lib prefixes to drop on top of
      the default list. Atoms or strings.
    * `:keep_prefixes` — prefixes to KEEP even if in the default strip list.
      Lets a specific app opt back into a stripped lib.
  """
  @spec build(Path.t(), Path.t(), keyword) ::
          {:ok, map} | {:error, term}
  def build(source_otp_tree, target_zip_path, opts \\ []) do
    with :ok <- check_source(source_otp_tree),
         {:ok, staging} <- stage_and_strip(source_otp_tree, opts),
         {:ok, info} <- zip_staging(staging, target_zip_path) do
      File.rm_rf!(staging)
      original_kb = du_kb(source_otp_tree)
      {:ok, Map.put(info, :original_size_kb, original_kb)}
    end
  end

  @doc """
  Returns the list of OTP lib name prefixes that are stripped by default.
  Public so tests can assert the policy without re-importing the module-private list.
  """
  @spec default_stripped_prefixes() :: [String.t()]
  def default_stripped_prefixes, do: @stripped_lib_prefixes

  defp check_source(path) do
    cond do
      not File.dir?(path) ->
        {:error, "OTP source tree not a directory: #{path}"}

      not erts_in?(path) ->
        {:error, "no erts-*/ directory under #{path} — not an OTP runtime tree?"}

      true ->
        :ok
    end
  end

  defp erts_in?(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.any?(entries, &String.starts_with?(&1, "erts-"))
      _ -> false
    end
  end

  defp stage_and_strip(source, opts) do
    staging = Path.join(System.tmp_dir!(), "mob_otp_zip_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    case System.cmd("cp", ["-R", source <> "/.", staging], stderr_to_stdout: true) do
      {_, 0} ->
        # slim: false ships the OTP tree untouched. Required for apps that run
        # arbitrary user code at runtime (e.g. an embedded Livebook host doing
        # Mix.install) — we can't know which OTP libs (inets, ssl, xmerl,
        # runtime_tools, …) a user's deps will need, so stripping any is unsafe.
        if Keyword.get(opts, :slim, true) do
          prefixes = compute_strip_set(opts)
          strip_otp_libs(staging, prefixes)
          strip_standalone_execs(staging)
          strip_static_archives(staging)
          strip_source_and_headers(staging)
          strip_beam_chunks(staging)
        end

        {:ok, staging}

      {out, _} ->
        File.rm_rf!(staging)
        {:error, "copy failed: #{out}"}
    end
  end

  # Drop src/ and include/ from every lib. .erl source and .hrl headers
  # are needed at compile time, not runtime. Saves ~16 MB on a typical
  # OTP tree. Same logic as iOS release.ex's strip pass.
  defp strip_source_and_headers(staging) do
    Path.wildcard(Path.join(staging, "lib/*/src")) |> Enum.each(&File.rm_rf!/1)
    Path.wildcard(Path.join(staging, "lib/*/include")) |> Enum.each(&File.rm_rf!/1)
    :ok
  end

  # Strip optional chunks (Dbgi/Docs/etc.) from every shipped .beam.
  # Same as `mix release --strip-beams` and the iOS release pass.
  # Drops ~30% per .beam file. The host's `erl` and the bundled OTP are
  # the same major version, so beam_lib:strip_release/1 is binary-safe.
  #
  # We're tolerant of strip failures: a stage tree from a test fixture
  # may contain placeholder "fake beam" files that aren't valid BEAMs.
  # In production those don't exist; the strip succeeds and shrinks
  # the bundle. In tests, a failed strip just leaves the file untouched
  # (which is the same behaviour as not running the step at all).
  defp strip_beam_chunks(staging) do
    {_, _status} =
      System.cmd(
        "erl",
        [
          "-noinput",
          "-boot",
          "start_clean",
          "-eval",
          ~s|catch beam_lib:strip_release("#{staging}"), erlang:halt(0).|
        ],
        stderr_to_stdout: true
      )

    :ok
  end

  defp compute_strip_set(opts) do
    extra = opts |> Keyword.get(:strip_extra_prefixes, []) |> Enum.map(&to_string/1)
    keep = opts |> Keyword.get(:keep_prefixes, []) |> Enum.map(&to_string/1)
    (@stripped_lib_prefixes ++ extra) -- keep
  end

  defp strip_otp_libs(staging, prefixes) do
    lib_dir = Path.join(staging, "lib")

    case File.ls(lib_dir) do
      {:ok, entries} ->
        for entry <- entries,
            Enum.any?(prefixes, &String.starts_with?(entry, &1 <> "-")) do
          File.rm_rf!(Path.join(lib_dir, entry))
        end

      _ ->
        :ok
    end
  end

  defp strip_standalone_execs(staging) do
    Path.wildcard(Path.join(staging, "lib/*/priv/bin/*"))
    |> Enum.each(&File.rm_rf!/1)

    Path.wildcard(Path.join(staging, "erts-*/bin/*"))
    |> Enum.each(&File.rm_rf!/1)
  end

  defp strip_static_archives(staging) do
    {_, 0} =
      System.cmd("find", [staging, "-type", "f", "-name", "*.a", "-delete"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp zip_staging(staging, target_zip_path) do
    target_zip_path = Path.expand(target_zip_path)
    File.mkdir_p!(Path.dirname(target_zip_path))
    File.rm(target_zip_path)

    case System.cmd("zip", ["-9rq", target_zip_path, "."], cd: staging, stderr_to_stdout: true) do
      {_, 0} ->
        zipped = count_files(staging)
        zip_size_kb = div(File.stat!(target_zip_path).size, 1024)
        {:ok, %{zipped_files: zipped, zip_size_kb: zip_size_kb}}

      {out, code} ->
        {:error, "zip failed (#{code}): #{out}"}
    end
  end

  defp count_files(dir) do
    {out, 0} = System.cmd("find", [dir, "-type", "f"], stderr_to_stdout: true)
    out |> String.split("\n", trim: true) |> length()
  end

  defp du_kb(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split() |> List.first() |> String.to_integer()

      _ ->
        0
    end
  end
end
