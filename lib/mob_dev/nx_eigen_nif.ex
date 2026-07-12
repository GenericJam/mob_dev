defmodule MobDev.NxEigenNif do
  @moduledoc """
  Cross-compiles the `nx_eigen` C++ NIF (Eigen-backed Nx backend) for one
  Android or iOS target ABI and archives the result as `libnx_eigen.a`.
  The archive gets static-linked into the user app's main native binary
  alongside `crypto.a`, `libemlx.a`, and any other static NIFs.

  ## Why static-link this NIF?

  Same constraints as every other NIF mob ships on phones:

    * **Android.** `dlopen`'d children inherit `RTLD_LOCAL`, hiding the
      parent's `enif_*` symbols from a separately-loaded `libnx_eigen.so`.
      `on_load` then fails with "cannot locate symbol". Static linking
      sidesteps that — BEAM finds `nx_eigen_nif_init` via
      `dlsym(RTLD_DEFAULT)` against the main app binary.
    * **iOS.** App Store forbids loading unsigned dylibs / `dlopen`; every
      NIF must already be present in the signed binary.

  ## Per-target deltas

  All four targets compile the same two source files (`@sources`) with the
  shared base CXXFLAGS list (`@base_cxxflags`). The deltas are:

  | Target        | Arch dir                        | Toolchain          | Extra CXXFLAGS                                | nm symbol            |
  |---------------|---------------------------------|--------------------|-----------------------------------------------|----------------------|
  | android_arm64 | aarch64-unknown-linux-android   | NDK clang++/llvm-ar | Android hardening: branch-protect, stack-clash, _GNU_SOURCE | `nx_eigen_nif_init`   |
  | android_arm32 | arm-unknown-linux-androideabi   | NDK clang++/llvm-ar | Android hardening + `-march=armv7-a -mfloat-abi=softfp -mthumb` | `nx_eigen_nif_init`   |
  | ios_sim       | aarch64-apple-iossimulator      | xcrun (sim SDK)    | iOS minimal — no Android hardening            | `_nx_eigen_nif_init`  |
  | ios_device    | aarch64-apple-ios               | xcrun (device SDK) | iOS minimal — no Android hardening            | `_nx_eigen_nif_init`  |

  ## STATIC_ERLANG_NIF_LIBNAME

  We pass `-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen` rather than plain
  `-DSTATIC_ERLANG_NIF`. The reason: `nx_eigen_nif.cpp` uses Fine's
  `FINE_INIT(...)` macro, which expands to `ERL_NIF_INIT_DECL(NAME)` —
  passing the literal token `NAME` as MODNAME. With STATIC_ERLANG_NIF
  alone the emitted symbol would be the unhelpful `NAME_nif_init`.
  Setting LIBNAME overrides MODNAME entirely and forces the symbol to
  `nx_eigen_nif_init`, which is what mob's driver_tab references.

  ## FFT — Eigen's built-in kissfft backend

  We don't use NxEigen's bundled FFT variants. Instead, mob_dev ships
  its own `priv/cpp_nif/nx_eigen_fft_eigen.cpp` bridge that calls
  Eigen's `unsupported/Eigen/FFT` module (kissfft underneath — header
  only, embedded in the Eigen tarball). This gives `Nx.fft/3` and
  `Nx.ifft/3` working on-device with no additional cross-compile.

  Kissfft is roughly 2x slower than FFTW for large transforms but
  microseconds for audio-sized buffers; switch to a FFTW variant later
  if a real workload measures a bottleneck.

  ## Phases

  Each `build/2` call:
    1. Precheck — nx_eigen source dir + Fine + Eigen headers + erts
       include all present; Android/iOS toolchain reachable.
    2. Compile — for each of @sources, run `<cxx> <cxxflags> -c -o obj src`.
    3. Archive — `<ar> rcs libnx_eigen.a obj1 obj2` then `<ranlib> ...`.
    4. Verify — `<nm> libnx_eigen.a`, scan for the expected symbol.
       Symbol missing is a `:precondition_failed` (means our compile
       didn't actually produce `nx_eigen_nif_init` — usually because Fine
       or NxEigen's source moved out from under us, or LIBNAME wasn't
       picked up).
  """

  alias MobDev.NdkVersion
  alias MobDev.Release.{Errors, Shell}

  @android_api 28
  @ios_min_version "17.0"
  @eigen_version "3.4.0"

  # ── Source list ────────────────────────────────────────────────────────
  #
  # Sources come from two roots: NxEigen's own `c_src/` (the main NIF) and
  # mob_dev's own `priv/cpp_nif/` (the Eigen-FFT bridge we wrote — see
  # the "FFT" section in the moduledoc). Each entry is
  # `{root, basename}` where `root` is `:nx_eigen | :bridge`; the build
  # resolves to absolute paths once the dep paths are known.

  @sources [
    {:nx_eigen, "nx_eigen_nif.cpp"},
    {:bridge, "nx_eigen_fft_eigen.cpp"}
  ]

  @doc """
  Source files compiled for every target — list of `{root, basename}`.
  Public so tests can pin the surface.
  """
  @spec sources() :: [{:nx_eigen | :bridge, String.t()}]
  def sources, do: @sources

  # ── Base CXXFLAGS — shared across all targets ───────────────────────────

  @base_cxxflags [
    "-fPIC",
    "-O3",
    "-std=c++17",
    "-fvisibility=hidden",
    # Exceptions + RTTI stay enabled — Fine throws std::runtime_error /
    # std::invalid_argument for decode failures and NxEigen propagates
    # them through `try`/`catch` in FINE_INIT. Disabling either flag
    # leads to "cannot use 'throw' with exceptions disabled" at compile
    # time. Matches Pythonx's working build (also C++17 + exceptions).
    "-ffunction-sections",
    "-fdata-sections",
    # Forces the FINE_INIT-emitted symbol to nx_eigen_nif_init regardless
    # of the (broken-looking) NAME token Fine passes through.
    "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen"
  ]

  @doc "Base CXXFLAGS shared across all targets. Public for testing."
  @spec base_cxxflags() :: [String.t()]
  def base_cxxflags, do: @base_cxxflags

  # Android targets add hardening flags + _GNU_SOURCE. iOS doesn't ship
  # these — they're either non-applicable (no branch-protect on iOS arm64,
  # Apple's PAC is enabled differently) or Apple's SDK already defines
  # equivalents.
  @android_extra_cxxflags [
    "-fstrict-flex-arrays=3",
    "-mbranch-protection=standard",
    "-fstack-clash-protection",
    "-D_GNU_SOURCE"
  ]

  # arm32 additionally needs ABI flags: armv7-a target arch, softfp ABI
  # (Android API contract), -mthumb to match NDK code-gen.
  @arm32_extra_cxxflags ["-march=armv7-a", "-mfloat-abi=softfp", "-mthumb"]

  # ── Target spec ─────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc "Per-target description: arch path layout, toolchain factory, extra CXXFLAGS, expected nm symbol."

    @enforce_keys [:id, :arch_dir, :tools_fn, :extra_cxxflags, :nm_symbol]
    defstruct [:id, :arch_dir, :tools_fn, :extra_cxxflags, :nm_symbol]

    @type tools :: %{
            cxx: [String.t()],
            ar: [String.t()],
            ranlib: [String.t()],
            nm: [String.t()]
          }

    @type t :: %__MODULE__{
            id: :android_arm64 | :android_arm32 | :ios_sim | :ios_device,
            arch_dir: String.t(),
            tools_fn: (keyword() -> tools()),
            extra_cxxflags: [String.t()],
            nm_symbol: String.t()
          }
  end

  @doc "All known NxEigen targets."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :ios_sim, :ios_device]

  @doc """
  Per-target spec. Public so tests can lock down the surface (especially
  the `extra_cxxflags` lists — silent drops there would silently weaken
  released binaries).
  """
  @spec target_spec(atom()) :: Target.t()
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      arch_dir: "aarch64-unknown-linux-android",
      tools_fn: &android_tools(&1, :android_arm64),
      extra_cxxflags: @android_extra_cxxflags,
      nm_symbol: "nx_eigen_nif_init"
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      arch_dir: "arm-unknown-linux-androideabi",
      tools_fn: &android_tools(&1, :android_arm32),
      extra_cxxflags: @arm32_extra_cxxflags ++ @android_extra_cxxflags,
      nm_symbol: "nx_eigen_nif_init"
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      arch_dir: "aarch64-apple-iossimulator",
      tools_fn: &ios_tools(&1, :ios_sim),
      extra_cxxflags: [],
      # Mach-O symbols carry a leading underscore in nm output.
      nm_symbol: "_nx_eigen_nif_init"
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      arch_dir: "aarch64-apple-ios",
      tools_fn: &ios_tools(&1, :ios_device),
      extra_cxxflags: [],
      nm_symbol: "_nx_eigen_nif_init"
    }
  end

  # ── CXXFLAGS assembly (pure) ────────────────────────────────────────────

  @doc """
  Assemble the full CXXFLAGS list for a target plus the include path
  list. Pure function for testability — silent flag drops are the exact
  regression class this module exists to prevent.

  `includes` is a list of absolute directory paths to be `-I`-prefixed.
  Order is preserved.
  """
  @spec cxxflags(Target.t(), [Path.t()]) :: [String.t()]
  def cxxflags(%Target{} = target, includes) when is_list(includes) do
    @base_cxxflags ++
      target.extra_cxxflags ++
      Enum.map(includes, &"-I#{&1}")
  end

  # ── Build entrypoint ────────────────────────────────────────────────────

  @doc """
  Compile + archive + verify libnx_eigen.a for one target. Returns
  `{:ok, info}` naming the produced archive, or a tagged error.

  Options:
    * `:nx_eigen_dir` — path to the nx_eigen Hex dep (the dir containing
      `c_src/` and the Eigen download). **Required.**
    * `:fine_dir` — path to the fine Hex dep (containing `c_include/`).
      **Required.**
    * `:erts_include` — path to the per-target `erts-VSN/include/` dir
      (carries `erl_nif.h`, etc.). **Required.**
    * `:eigen_dir` — Eigen header root (defaults to
      `<nx_eigen_dir>/eigen-#{@eigen_version}`).
    * `:bridge_dir` — directory holding the Eigen-FFT bridge source
      we ship (defaults to `:code.priv_dir(:mob_dev)/cpp_nif`).
    * `:out_dir` — directory the archive + per-arch obj subdir get
      written to. **Required.**
    * `:ndk_root` — Android NDK root (Android targets only; defaults to
      `~/Library/Android/sdk/ndk/<NdkVersion.effective()>`).
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ [])
      when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()

    with {:ok, nx_eigen_dir} <- require_opt(opts, :nx_eigen_dir),
         {:ok, fine_dir} <- require_opt(opts, :fine_dir),
         {:ok, erts_inc} <- require_opt(opts, :erts_include),
         {:ok, out_dir} <- require_opt(opts, :out_dir) do
      eigen_dir = opts[:eigen_dir] || Path.join(nx_eigen_dir, "eigen-#{@eigen_version}")
      bridge_dir = opts[:bridge_dir] || default_bridge_dir()
      nx_eigen_src = Path.join(nx_eigen_dir, "c_src")

      paths = %{
        nx_eigen: nx_eigen_src,
        bridge: bridge_dir,
        obj_dir: Path.join([out_dir, "obj", target.arch_dir]),
        lib_dir: out_dir
      }

      includes = [
        nx_eigen_src,
        eigen_dir,
        Path.join(fine_dir, "c_include"),
        erts_inc,
        Path.join(erts_inc, "internal")
      ]

      with :ok <-
             precheck(target, shell, paths, eigen_dir, fine_dir, erts_inc, opts),
           tools = target.tools_fn.(opts),
           flags = cxxflags(target, includes),
           :ok <- shell.mkdir_p(paths.obj_dir),
           :ok <- shell.mkdir_p(paths.lib_dir),
           {:ok, objects} <- compile_sources(shell, tools, flags, paths),
           archive = Path.join(paths.lib_dir, "libnx_eigen.a"),
           :ok <- shell.rm_f(archive),
           {:ok, _} <- shell.cmd(tools.ar ++ ["rcs", archive | objects], []),
           {:ok, _} <- shell.cmd(tools.ranlib ++ [archive], []),
           :ok <- verify_symbol(shell, tools.nm, archive, target.nm_symbol) do
        {:ok, %{target: target_id, archive: archive, objects: objects}}
      end
    end
  end

  # Resolves the priv/cpp_nif dir at runtime. `Application.app_dir/2`
  # works in dev, test, and releases (more robust than `:code.priv_dir/1`
  # which requires the app to be loaded).
  defp default_bridge_dir, do: Application.app_dir(:mob_dev, "priv/cpp_nif")

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      _ -> Errors.precondition("MobDev.NxEigenNif.build/2 requires #{inspect(key)}")
    end
  end

  defp compile_sources(shell, tools, flags, paths) do
    Enum.reduce_while(@sources, {:ok, []}, fn {root, basename}, {:ok, acc} ->
      src_path = Path.join(Map.fetch!(paths, root), basename)
      obj_path = Path.join(paths.obj_dir, String.replace_suffix(basename, ".cpp", ".o"))

      argv = tools.cxx ++ flags ++ ["-c", "-o", obj_path, src_path]

      case shell.cmd(argv, []) do
        {:ok, _} -> {:cont, {:ok, [obj_path | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, objs} -> {:ok, Enum.reverse(objs)}
      err -> err
    end
  end

  defp verify_symbol(shell, nm_argv, archive, expected_symbol) do
    case shell.cmd(nm_argv ++ [archive], []) do
      {:ok, output} -> check_symbol_present(output, expected_symbol, archive)
      err -> err
    end
  end

  @doc """
  Parse `nm` output and confirm the expected `nx_eigen_nif_init` symbol
  is exported (`T` flag in nm's output). Returns `:ok` or a tagged
  precondition_failed.

  Mirror of `MobDev.Release.OpenSSL.CryptoNif.check_symbol_present/3` —
  the parsing logic is identical, just a different expected symbol.
  Missing symbol on an otherwise-successful build almost always means
  `STATIC_ERLANG_NIF_LIBNAME=nx_eigen` got dropped from the flags or
  Fine's FINE_INIT macro changed shape.
  """
  @spec check_symbol_present(binary(), String.t(), Path.t()) :: :ok | Errors.t()
  def check_symbol_present(nm_output, expected_symbol, archive) when is_binary(nm_output) do
    pattern = ~r/^\s*[0-9a-f]+ T #{Regex.escape(expected_symbol)}\s*$/m

    if Regex.match?(pattern, nm_output) do
      :ok
    else
      Errors.precondition(
        "expected `T #{expected_symbol}` not found in #{archive} — " <>
          "did Fine's FINE_INIT macro change shape? Did " <>
          "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen get dropped?"
      )
    end
  end

  # ── Preconditions ──────────────────────────────────────────────────────

  defp precheck(target, shell, paths, eigen_dir, fine_dir, erts_inc, opts) do
    cond do
      not shell.dir?(paths.nx_eigen) ->
        Errors.precondition(
          "nx_eigen source not found at #{paths.nx_eigen} — run `mix deps.get` " <>
            "(needs `:nx_eigen` in mix.exs deps)"
        )

      not shell.dir?(paths.bridge) ->
        Errors.precondition(
          "Eigen-FFT bridge source not found at #{paths.bridge} — mob_dev " <>
            "should ship priv/cpp_nif/nx_eigen_fft_eigen.cpp. Is the " <>
            "mob_dev install corrupt?"
        )

      not shell.dir?(eigen_dir) ->
        Errors.precondition(
          "Eigen headers not found at #{eigen_dir} — run `mix deps.compile " <>
            "nx_eigen` on host once to trigger the auto-download, or pass " <>
            ":eigen_dir explicitly"
        )

      not shell.dir?(Path.join(fine_dir, "c_include")) ->
        Errors.precondition(
          "Fine headers not found at #{Path.join(fine_dir, "c_include")} " <>
            "— check :fine dep is fetched"
        )

      not shell.dir?(erts_inc) ->
        Errors.precondition(
          "erts include dir missing at #{erts_inc} — needs the per-target " <>
            "OTP tarball extracted"
        )

      target.id in [:android_arm64, :android_arm32] ->
        android_precheck(shell, opts)

      target.id in [:ios_sim, :ios_device] ->
        :ok
    end
  end

  defp android_precheck(_shell, opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root()
    ndk_version = NdkVersion.effective()

    cond do
      not NdkVersion.installed?(ndk_version) ->
        Errors.precondition(
          "Android NDK #{ndk_version} not installed — install with: " <>
            NdkVersion.install_command()
        )

      not File.dir?(Path.join([ndk_root, "toolchains/llvm/prebuilt"])) ->
        Errors.precondition("NDK toolchain not found at #{ndk_root}")

      true ->
        :ok
    end
  end

  # ── Per-target toolchain factories ─────────────────────────────────────

  defp android_tools(opts, target_id) do
    toolchain_bin = android_toolchain_bin(opts)
    cxx_name = android_cxx_name(target_id)

    %{
      cxx: [Path.join(toolchain_bin, cxx_name)],
      ar: [Path.join(toolchain_bin, "llvm-ar")],
      ranlib: [Path.join(toolchain_bin, "llvm-ranlib")],
      nm: [Path.join(toolchain_bin, "llvm-nm")]
    }
  end

  defp android_cxx_name(:android_arm64), do: "aarch64-linux-android#{@android_api}-clang++"
  defp android_cxx_name(:android_arm32), do: "armv7a-linux-androideabi#{@android_api}-clang++"

  # iOS uses -stdlib=libc++ explicitly so the link step pulls libc++ rather
  # than expecting libstdc++ (which Apple's SDK doesn't ship). On Android
  # we get libc++ via the NDK's clang++ default + we statically link via
  # -static-libstdc++ at the final link step (the app, not here).
  defp ios_tools(_opts, target_id) do
    sdk = ios_sdk_name(target_id)
    min_flag = ios_min_version_flag(target_id)

    %{
      cxx: ["xcrun", "-sdk", sdk, "clang++", "-arch", "arm64", min_flag, "-stdlib=libc++"],
      ar: ["xcrun", "-sdk", sdk, "ar"],
      ranlib: ["xcrun", "-sdk", sdk, "ranlib"],
      nm: ["xcrun", "-sdk", sdk, "nm"]
    }
  end

  defp ios_sdk_name(:ios_sim), do: "iphonesimulator"
  defp ios_sdk_name(:ios_device), do: "iphoneos"

  defp ios_min_version_flag(:ios_sim), do: "-mios-simulator-version-min=#{@ios_min_version}"
  defp ios_min_version_flag(:ios_device), do: "-miphoneos-version-min=#{@ios_min_version}"

  # Honors ANDROID_HOME / ANDROID_SDK_ROOT via the shared NdkVersion helper (MOB-89).
  defp default_ndk_root, do: NdkVersion.root()

  defp android_toolchain_bin(opts) do
    case opts[:ndk_root] do
      nil -> NdkVersion.toolchain_bin()
      root -> Path.join([root, "toolchains", "llvm", "prebuilt", NdkVersion.host(), "bin"])
    end
  end
end
