defmodule MobDev.TfliteNif do
  @moduledoc """
  Cross-compiles `tflite_nif.c` (the NIF wrapping TensorFlow Lite's C API)
  for one Android or iOS target ABI and archives the result as
  `libtflite_nif.a`. The archive gets static-linked into the user app's
  main native binary alongside `crypto.a`, `libemlx.a`, and any other
  static NIFs.

  ## Companion bits

  * **Native libs** — `MobDev.TfliteDownloader` fetches the TFLite native
    libraries (AAR for Android, xcframework tarball for iOS) and supplies
    headers + the runtime library that gets linked into the launcher
    binary alongside this archive.
  * **C source** — `tflite_nif.c` ships in the `:nx_tflite_mob` Hex dep
    (the user adds `{:nx_tflite_mob, ...}` to their `mix.exs` when they
    run `mix mob.enable tflite`). This module looks it up via
    `:code.lib_dir(:nx_tflite_mob)`.
  * **Static-NIF table entry** — `:tflite_nif` is registered in
    `MobDev.StaticNifs.default_nifs/0` with guard `MOB_STATIC_TFLITE_NIF`.
    The guard threads into `build_device.zig` as `tflite_static` and is
    set to `true` when the project enables this feature.

  ## Why static-link this NIF?

  Same constraints as every other NIF mob ships on phones:

    * **Android.** `dlopen`'d children inherit `RTLD_LOCAL`, hiding the
      parent's `enif_*` symbols from a separately-loaded `libtflite_nif.so`.
      `on_load` then fails with "cannot locate symbol". Static linking
      sidesteps that — BEAM finds `tflite_nif_nif_init` via
      `dlsym(RTLD_DEFAULT)` against the main app binary.
    * **iOS.** App Store forbids loading unsigned dylibs / `dlopen`; every
      NIF must already be present in the signed binary.

  The TFLite runtime itself (`libtensorflowlite_jni.so` on Android,
  `TensorFlowLiteC.framework` on iOS) IS allowed to load via the normal
  dynamic-linker path: it's code-signed (iOS) or part of the standard
  jniLibs/ contract (Android). Only the NIF init has to be static.

  ## Per-target deltas

  | Target        | Source              | Compiler             | nm symbol            |
  |---------------|---------------------|----------------------|----------------------|
  | android_arm64 | NDK aarch64 clang   | aarch64 cross        | `tflite_nif_nif_init` |
  | android_arm32 | NDK arm clang       | arm cross (armv7-a)  | `tflite_nif_nif_init` |
  | ios_sim       | xcrun iphonesimulator | arm64-apple-ios-simulator | `_tflite_nif_nif_init` |
  | ios_device    | xcrun iphoneos      | arm64-apple-ios      | `_tflite_nif_nif_init` |

  ## STATIC_ERLANG_NIF_LIBNAME

  We pass `-DSTATIC_ERLANG_NIF_LIBNAME=tflite_nif` to make `ERL_NIF_INIT`
  emit symbol `tflite_nif_nif_init`. That matches the convention used by
  `MobDev.NxEigenNif` (`nx_eigen` → `nx_eigen_nif_init`) and what
  `MobDev.StaticNifs.init_fn/1` derives for the `:tflite_nif` module
  entry.
  """

  alias MobDev.NdkVersion
  alias MobDev.Release.{Errors, Shell}

  @android_api 28
  @ios_min_version "15.0"

  @doc "All known TFLite NIF targets."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :ios_sim, :ios_device]

  # ── Target spec ─────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc false
    @enforce_keys [:id, :tools_fn, :extra_cflags, :nm_symbol]
    defstruct [:id, :tools_fn, :extra_cflags, :nm_symbol]
  end

  @android_extra_cflags [
    "-fstrict-flex-arrays=3",
    "-mbranch-protection=standard",
    "-fstack-clash-protection",
    "-D_GNU_SOURCE",
    "-D__ANDROID__"
  ]

  @arm32_extra_cflags ["-march=armv7-a", "-mfloat-abi=softfp", "-mthumb"]

  @doc "Per-target spec. Public for testing."
  @spec target_spec(atom()) :: %Target{}
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      tools_fn: &android_tools(&1, :android_arm64),
      extra_cflags: @android_extra_cflags,
      nm_symbol: "tflite_nif_nif_init"
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      tools_fn: &android_tools(&1, :android_arm32),
      extra_cflags: @arm32_extra_cflags ++ @android_extra_cflags,
      nm_symbol: "tflite_nif_nif_init"
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      tools_fn: &ios_tools(&1, :ios_sim),
      extra_cflags: [],
      nm_symbol: "_tflite_nif_nif_init"
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      tools_fn: &ios_tools(&1, :ios_device),
      extra_cflags: [],
      nm_symbol: "_tflite_nif_nif_init"
    }
  end

  # ── CFLAGS assembly ─────────────────────────────────────────────────────

  @base_cflags [
    "-fPIC",
    "-O2",
    "-Wall",
    "-std=c99",
    "-DSTATIC_ERLANG_NIF_LIBNAME=tflite_nif"
  ]

  @doc "Base CFLAGS shared across all targets. Public for testing."
  @spec base_cflags() :: [String.t()]
  def base_cflags, do: @base_cflags

  @doc """
  Assemble full CFLAGS for a target plus include / framework search paths.

  `includes` are `-I`-prefixed; `frameworks` are `-F`-prefixed (iOS only —
  ignored on Android targets). Order is preserved.
  """
  @spec cflags(%Target{}, [Path.t()], [Path.t()]) :: [String.t()]
  def cflags(%Target{} = target, includes, frameworks \\ [])
      when is_list(includes) and is_list(frameworks) do
    @base_cflags ++
      target.extra_cflags ++
      Enum.map(includes, &"-I#{&1}") ++
      Enum.map(frameworks, &"-F#{&1}")
  end

  # ── Build entrypoint ────────────────────────────────────────────────────

  @doc """
  Compile + archive + verify `libtflite_nif.a` for one target.

  Options:
    * `:nx_tflite_mob_dir` — path to the `:nx_tflite_mob` Hex dep (the
      dir containing `c_src/tflite_nif.c`). **Required.**
    * `:tflite_dir` — path returned by `MobDev.TfliteDownloader.ensure/1`
      for this target. **Required.**
    * `:erts_include` — per-target `erts-VSN/include/` dir. **Required.**
    * `:out_dir` — where the archive + object subdir get written.
      **Required.**
    * `:ndk_root` — Android NDK root (Android targets only; defaults to
      `~/Library/Android/sdk/ndk/<NdkVersion.effective()>`).
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ [])
      when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()

    with {:ok, src_root} <- require_opt(opts, :nx_tflite_mob_dir),
         {:ok, tflite_dir} <- require_opt(opts, :tflite_dir),
         {:ok, erts_inc} <- require_opt(opts, :erts_include),
         {:ok, out_dir} <- require_opt(opts, :out_dir) do
      src = Path.join([src_root, "c_src", "tflite_nif.c"])

      {includes, frameworks} = include_paths(target_id, tflite_dir, erts_inc)

      paths = %{
        obj_dir: Path.join([out_dir, "obj", arch_dir(target_id)]),
        lib_dir: out_dir,
        src: src
      }

      with :ok <- precheck(target, shell, paths, tflite_dir, erts_inc, opts),
           tools = target.tools_fn.(opts),
           flags = cflags(target, includes, frameworks),
           :ok <- shell.mkdir_p(paths.obj_dir),
           :ok <- shell.mkdir_p(paths.lib_dir),
           obj = Path.join(paths.obj_dir, "tflite_nif.o"),
           {:ok, _} <- shell.cmd(tools.cc ++ flags ++ ["-c", "-o", obj, src], []),
           archive = Path.join(paths.lib_dir, "libtflite_nif.a"),
           :ok <- shell.rm_f(archive),
           {:ok, _} <- shell.cmd(tools.ar ++ ["rcs", archive, obj], []),
           {:ok, _} <- shell.cmd(tools.ranlib ++ [archive], []),
           :ok <- verify_symbol(shell, tools.nm, archive, target.nm_symbol) do
        {:ok, %{target: target_id, archive: archive, object: obj}}
      end
    end
  end

  # ── Per-target tool / path helpers ──────────────────────────────────────

  defp arch_dir(:android_arm64), do: "aarch64-unknown-linux-android"
  defp arch_dir(:android_arm32), do: "arm-unknown-linux-androideabi"
  defp arch_dir(:ios_sim), do: "aarch64-apple-iossimulator"
  defp arch_dir(:ios_device), do: "aarch64-apple-ios"

  defp include_paths(target_id, tflite_dir, erts_inc)
       when target_id in [:android_arm64, :android_arm32] do
    {[
       Path.join(tflite_dir, "headers"),
       erts_inc,
       Path.join(erts_inc, "internal")
     ], []}
  end

  defp include_paths(:ios_device, tflite_dir, erts_inc) do
    fw_root = Path.join(tflite_dir, "Frameworks")

    {[erts_inc, Path.join(erts_inc, "internal")],
     [
       Path.join([fw_root, "TensorFlowLiteC.xcframework", "ios-arm64"]),
       Path.join([fw_root, "TensorFlowLiteCCoreML.xcframework", "ios-arm64"])
     ]}
  end

  defp include_paths(:ios_sim, tflite_dir, erts_inc) do
    fw_root = Path.join(tflite_dir, "Frameworks")
    slice = "ios-arm64_x86_64-simulator"

    {[erts_inc, Path.join(erts_inc, "internal")],
     [
       Path.join([fw_root, "TensorFlowLiteC.xcframework", slice]),
       Path.join([fw_root, "TensorFlowLiteCCoreML.xcframework", slice])
     ]}
  end

  defp android_tools(opts, arch) do
    ndk_root =
      opts[:ndk_root] ||
        Path.join([System.user_home!(), "Library/Android/sdk/ndk", NdkVersion.effective()])

    host = ndk_host()
    bin = Path.join([ndk_root, "toolchains/llvm/prebuilt/#{host}/bin"])

    cc_name =
      case arch do
        :android_arm64 -> "aarch64-linux-android#{@android_api}-clang"
        :android_arm32 -> "armv7a-linux-androideabi#{@android_api}-clang"
      end

    %{
      cc: [Path.join(bin, cc_name)],
      ar: [Path.join(bin, "llvm-ar")],
      ranlib: [Path.join(bin, "llvm-ranlib")],
      nm: [Path.join(bin, "llvm-nm")]
    }
  end

  defp ios_tools(_opts, target) do
    sdk =
      case target do
        :ios_device -> "iphoneos"
        :ios_sim -> "iphonesimulator"
      end

    sdk_path = String.trim(System.cmd("xcrun", ["--sdk", sdk, "--show-sdk-path"]) |> elem(0))

    target_triple =
      case target do
        :ios_device -> "arm64-apple-ios#{@ios_min_version}"
        :ios_sim -> "arm64-apple-ios#{@ios_min_version}-simulator"
      end

    cc_path = String.trim(System.cmd("xcrun", ["--find", "clang"]) |> elem(0))
    ar_path = String.trim(System.cmd("xcrun", ["--find", "ar"]) |> elem(0))
    ranlib_path = String.trim(System.cmd("xcrun", ["--find", "ranlib"]) |> elem(0))
    nm_path = String.trim(System.cmd("xcrun", ["--find", "nm"]) |> elem(0))

    %{
      cc: [cc_path, "-arch", "arm64", "-target", target_triple, "-isysroot", sdk_path],
      ar: [ar_path],
      ranlib: [ranlib_path],
      nm: [nm_path]
    }
  end

  defp ndk_host do
    case :os.type() do
      {:unix, :darwin} -> "darwin-x86_64"
      {:unix, :linux} -> "linux-x86_64"
      _ -> "darwin-x86_64"
    end
  end

  # ── Precondition + verification ─────────────────────────────────────────

  defp precheck(target, shell, paths, tflite_dir, erts_inc, opts) do
    cond do
      not shell.file?(paths.src) ->
        Errors.precondition(
          "nx_tflite_mob c_src/tflite_nif.c not found at #{paths.src} — is :nx_tflite_mob in mix deps?"
        )

      not shell.dir?(tflite_dir) ->
        Errors.precondition(
          "TFLite bundle missing at #{tflite_dir} — TfliteDownloader.ensure/1 not run for #{target.id}?"
        )

      not shell.dir?(erts_inc) ->
        Errors.precondition("erts include dir missing at #{erts_inc}")

      true ->
        ensure_toolchain(target, opts)
    end
  end

  defp ensure_toolchain(%Target{id: id}, opts) when id in [:android_arm64, :android_arm32] do
    ndk_root =
      opts[:ndk_root] ||
        Path.join([System.user_home!(), "Library/Android/sdk/ndk", NdkVersion.effective()])

    if File.dir?(ndk_root) do
      :ok
    else
      Errors.precondition("Android NDK not found at #{ndk_root}")
    end
  end

  defp ensure_toolchain(%Target{id: id}, _opts) when id in [:ios_sim, :ios_device] do
    case System.cmd("xcrun", ["--find", "clang"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> Errors.precondition("xcrun / Xcode command-line tools missing")
    end
  end

  defp verify_symbol(shell, nm_cmd, archive, expected) do
    case shell.cmd(nm_cmd ++ [archive], []) do
      {:ok, out} ->
        if String.contains?(out, expected) do
          :ok
        else
          Errors.precondition(
            "compile produced libtflite_nif.a without `#{expected}` symbol — STATIC_ERLANG_NIF_LIBNAME=tflite_nif may have been overridden by something upstream"
          )
        end

      err ->
        err
    end
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} -> {:ok, v}
      :error -> Errors.precondition("required option missing: #{inspect(key)}")
    end
  end
end
