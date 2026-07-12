defmodule MobDev.Plugin.CppArchive do
  @moduledoc """
  Cross-compiles a plugin's `lang: :cpp_archive` NIF — a set of C++ sources —
  into `lib<module>.a` for one target ABI, and verifies the NIF-init symbol is
  present. The archive is then static-linked into the app's single signed native
  binary (same slot as `crypto.a` / `libnx_eigen.a`).

  This is the generic, manifest-driven generalization of `MobDev.NxEigenNif`:
  the sources, include dirs, CXXFLAGS, and expected symbol all come from the
  plugin's `Merge.static_archives/2` spec rather than being hardcoded. It exists
  because the single-source `:c`/`:zig` plugin NIF path (compiled inline by
  `build.zig`) can't express a C++ build with external headers (Eigen/Fine),
  RTTI/exceptions, a per-arch hardening flag set, and an archive output.

  ## Why static-link (same as every on-device NIF)

    * **Android.** A separately-`dlopen`'d `.so` inherits `RTLD_LOCAL`, hiding
      the BEAM's `enif_*` symbols → `on_load` fails. Static-linking lets the
      BEAM resolve the init symbol via `dlsym(RTLD_DEFAULT)` on the app binary.
    * **iOS.** The App Store forbids loading unsigned dylibs / `dlopen`; the NIF
      must already be in the signed binary.

  ## What the builder forces vs. what the plugin controls

  The builder forces only `-fPIC` (a static lib linked into a shared object must
  be position-independent) and the compile/output flags (`-c -o`). Everything
  else — C++ standard, optimization, visibility, exceptions, the
  `-DSTATIC_ERLANG_NIF_LIBNAME=…` that fixes the emitted init symbol, and any
  Android hardening — is the plugin's via `:cxxflags` / `:cxxflags_android` /
  `:cxxflags_ios`, so a plugin author keeps full control of its own ABI.
  """

  alias MobDev.NdkVersion
  alias MobDev.Release.{Errors, Shell}

  @android_api 28
  @ios_min_version "17.0"

  @forced_cxxflags ["-fPIC"]

  @doc "All target ABIs a cpp_archive can be built for."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :ios_sim, :ios_device]

  # ── Pure surface (unit-tested) ───────────────────────────────────────────

  # Target-intrinsic ABI flags the builder always supplies (like -fPIC): the
  # armeabi-v7a Android ABI mandates these for correct code-gen, so they belong
  # to the target, not the plugin — a plugin author shouldn't have to know them.
  defp target_abi_cxxflags(:android_arm32),
    do: ["-march=armv7-a", "-mfloat-abi=softfp", "-mthumb"]

  defp target_abi_cxxflags(_), do: []

  @doc """
  Assemble the full CXXFLAGS for one target: forced `-fPIC` + the target's
  intrinsic ABI flags (e.g. armv7 flags for android_arm32), then the plugin's
  base `:cxxflags`, then the target's platform-specific flags
  (`:cxxflags_android` / `:cxxflags_ios`), then `-I` for each resolved include
  dir (order preserved). Pure — silent flag drops are the regression class this
  whole module guards against, so it's directly testable.
  """
  @spec cxxflags(map(), atom(), [Path.t()]) :: [String.t()]
  def cxxflags(spec, target_id, includes) when is_map(spec) and is_list(includes) do
    platform_flags =
      case platform_of(target_id) do
        :android -> List.wrap(spec[:cxxflags_android])
        :ios -> List.wrap(spec[:cxxflags_ios])
      end

    @forced_cxxflags ++
      target_abi_cxxflags(target_id) ++
      List.wrap(spec[:cxxflags]) ++
      platform_flags ++
      Enum.map(includes, &"-I#{&1}")
  end

  @doc """
  Resolve a spec's `:sources`/`:includes` (a mix of absolute strings and
  `{:dep, name, subpath}` tokens left by `Merge.static_archives/2`) to absolute
  paths, resolving dep tokens against `deps_path`. Pure.
  """
  @spec resolve_deps([Path.t() | {:dep, atom(), String.t()}], Path.t()) :: [Path.t()]
  def resolve_deps(entries, deps_path) when is_list(entries) do
    for entry <- entries do
      case entry do
        {:dep, name, sub} -> Path.join([deps_path, Atom.to_string(name), sub])
        bin when is_binary(bin) -> bin
      end
    end
  end

  @doc "Archive filename for a NIF module — `lib<module>.a`."
  @spec archive_name(atom()) :: String.t()
  def archive_name(module) when is_atom(module), do: "lib#{module}.a"

  @doc """
  Parse `nm` output and confirm the expected init symbol is exported (`T`).
  Mirrors `MobDev.NxEigenNif.check_symbol_present/3`. Pure.
  """
  @spec check_symbol_present(binary(), String.t(), Path.t()) :: :ok | Errors.t()
  def check_symbol_present(nm_output, expected_symbol, archive) when is_binary(nm_output) do
    pattern = ~r/^\s*[0-9a-f]+ T #{Regex.escape(expected_symbol)}\s*$/m

    if Regex.match?(pattern, nm_output) do
      :ok
    else
      Errors.precondition(
        "expected `T #{expected_symbol}` not found in #{archive} — the " <>
          "cpp_archive plugin's sources didn't emit it. Check the source's " <>
          "ERL_NIF_INIT / -DSTATIC_ERLANG_NIF_LIBNAME and :nm_symbol agree."
      )
    end
  end

  # ── Build entrypoint ──────────────────────────────────────────────────────

  @doc """
  Compile + archive + verify a cpp_archive `spec` (from `Merge.static_archives/2`)
  for one `target_id`. Returns `{:ok, %{module:, archive:, objects:}}` or a
  tagged error.

  Options:
    * `:out_dir` — where the archive + per-arch objs land. **Required.**
    * `:erts_include` — per-target `erts-VSN/include/` dir (carries `erl_nif.h`).
      **Required.**
    * `:deps_path` — for resolving `{:dep, …}` include tokens (defaults to
      `Mix.Project.deps_path/0`).
    * `:ndk_root` — Android NDK root (Android targets; default derived).
  """
  @spec build(map(), atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(spec, target_id, opts \\ [])
      when is_map(spec) and target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    shell = Shell.impl()

    with {:ok, out_dir} <- require_opt(opts, :out_dir),
         {:ok, erts_inc} <- require_opt(opts, :erts_include),
         {:ok, _} <- require_field(spec, :nm_symbol),
         {:ok, _} <- require_sources(spec) do
      deps_path = opts[:deps_path] || Mix.Project.deps_path()

      includes =
        resolve_deps(spec.includes, deps_path) ++ [erts_inc, Path.join(erts_inc, "internal")]

      sources = resolve_deps(spec.sources, deps_path)
      arch_dir = arch_dir(target_id)
      obj_dir = Path.join([out_dir, "obj", arch_dir])
      archive = Path.join(out_dir, archive_name(spec.module))
      flags = cxxflags(spec, target_id, includes)
      tools = tools(target_id, opts)

      with :ok <- precheck(sources, target_id, shell, opts),
           :ok <- shell.mkdir_p(obj_dir),
           :ok <- shell.mkdir_p(out_dir),
           {:ok, objects} <- compile_sources(shell, tools, flags, sources, obj_dir),
           :ok <- shell.rm_f(archive),
           {:ok, _} <- shell.cmd(tools.ar ++ ["rcs", archive | objects], []),
           {:ok, _} <- shell.cmd(tools.ranlib ++ [archive], []),
           {:ok, nm_out} <- shell.cmd(tools.nm ++ [archive], []),
           :ok <- check_symbol_present(nm_out, nm_symbol(target_id, spec.nm_symbol), archive) do
        {:ok, %{module: spec.module, archive: archive, objects: objects}}
      end
    end
  end

  # Mach-O nm prefixes symbols with an underscore; ELF (Android) doesn't.
  defp nm_symbol(target_id, sym) do
    case platform_of(target_id) do
      :ios -> "_" <> sym
      :android -> sym
    end
  end

  defp compile_sources(shell, tools, flags, sources, obj_dir) do
    sources
    |> Enum.reduce_while({:ok, []}, fn src, {:ok, acc} ->
      obj = Path.join(obj_dir, Path.basename(src, Path.extname(src)) <> ".o")

      case shell.cmd(tools.cxx ++ flags ++ ["-c", "-o", obj, src], []) do
        {:ok, _} -> {:cont, {:ok, [obj | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, objs} -> {:ok, Enum.reverse(objs)}
      err -> err
    end
  end

  defp precheck(sources, target_id, shell, opts) do
    missing = Enum.reject(sources, &shell.file?/1)

    cond do
      missing != [] ->
        Errors.precondition("cpp_archive sources missing: #{Enum.join(missing, ", ")}")

      platform_of(target_id) == :android ->
        android_precheck(opts)

      true ->
        :ok
    end
  end

  defp android_precheck(opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root()
    version = NdkVersion.effective()

    cond do
      not NdkVersion.installed?(version) ->
        Errors.precondition(
          "Android NDK #{version} not installed — #{NdkVersion.install_command()}"
        )

      not File.dir?(Path.join([ndk_root, "toolchains/llvm/prebuilt"])) ->
        Errors.precondition("NDK toolchain not found at #{ndk_root}")

      true ->
        :ok
    end
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      _ -> Errors.precondition("MobDev.Plugin.CppArchive.build/3 requires #{inspect(key)}")
    end
  end

  defp require_field(spec, key) do
    case Map.get(spec, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> Errors.precondition("cpp_archive spec requires #{inspect(key)}")
    end
  end

  defp require_sources(%{sources: [_ | _] = s}), do: {:ok, s}
  defp require_sources(_), do: Errors.precondition("cpp_archive spec requires non-empty :sources")

  # ── Target plumbing (same toolchain layout as MobDev.NxEigenNif) ───────────

  defp platform_of(:android_arm64), do: :android
  defp platform_of(:android_arm32), do: :android
  defp platform_of(:ios_sim), do: :ios
  defp platform_of(:ios_device), do: :ios

  defp arch_dir(:android_arm64), do: "aarch64-unknown-linux-android"
  defp arch_dir(:android_arm32), do: "arm-unknown-linux-androideabi"
  defp arch_dir(:ios_sim), do: "aarch64-apple-iossimulator"
  defp arch_dir(:ios_device), do: "aarch64-apple-ios"

  defp tools(target_id, opts) when target_id in [:android_arm64, :android_arm32] do
    bin = android_toolchain_bin(opts)

    %{
      cxx: [Path.join(bin, android_cxx_name(target_id))],
      ar: [Path.join(bin, "llvm-ar")],
      ranlib: [Path.join(bin, "llvm-ranlib")],
      nm: [Path.join(bin, "llvm-nm")]
    }
  end

  defp tools(target_id, _opts) when target_id in [:ios_sim, :ios_device] do
    sdk = ios_sdk_name(target_id)

    %{
      cxx: [
        "xcrun",
        "-sdk",
        sdk,
        "clang++",
        "-arch",
        "arm64",
        ios_min_flag(target_id),
        "-stdlib=libc++"
      ],
      ar: ["xcrun", "-sdk", sdk, "ar"],
      ranlib: ["xcrun", "-sdk", sdk, "ranlib"],
      nm: ["xcrun", "-sdk", sdk, "nm"]
    }
  end

  defp android_cxx_name(:android_arm64), do: "aarch64-linux-android#{@android_api}-clang++"
  defp android_cxx_name(:android_arm32), do: "armv7a-linux-androideabi#{@android_api}-clang++"

  defp ios_sdk_name(:ios_sim), do: "iphonesimulator"
  defp ios_sdk_name(:ios_device), do: "iphoneos"

  defp ios_min_flag(:ios_sim), do: "-mios-simulator-version-min=#{@ios_min_version}"
  defp ios_min_flag(:ios_device), do: "-miphoneos-version-min=#{@ios_min_version}"

  # Honors ANDROID_HOME / ANDROID_SDK_ROOT via the shared NdkVersion helper —
  # do NOT re-derive the SDK path here (MOB-89: this used to hardcode
  # ~/Library/Android/sdk, breaking builds where the NDK lives elsewhere).
  defp default_ndk_root, do: NdkVersion.root()

  defp android_toolchain_bin(opts) do
    case opts[:ndk_root] do
      nil -> NdkVersion.toolchain_bin()
      root -> Path.join([root, "toolchains", "llvm", "prebuilt", NdkVersion.host(), "bin"])
    end
  end
end
