defmodule MobDev.Plugin.IosLinkCheck do
  @moduledoc """
  Fails an iOS build early when a plugin's `cpp_archive` references a symbol
  nothing in the app defines.

  The iOS links (`mix mob.deploy`'s `ios/build.zig` / `build_device.zig` and
  `mix mob.release --ios`) all pass `-dead_strip`, and ld64 reports an
  undefined symbol only from code that survives dead-stripping. A reference
  in code the app never reaches therefore links everywhere, until a link
  without `-dead_strip`, or a change that makes that code reachable, fails
  at the worst moment (MOB-470: mob_whisper 0.1.1's ggml `dl_*` helpers
  passed every dev build and failed `mix mob.release --ios`).

  `check/5` links the plugin's archive into a throwaway dylib *without*
  `-dead_strip`: every member of its own `lib<module>.a` (`-force_load`),
  plus the members of its prebuilt archives (MOB-427) that those pull in,
  as the app's link would. The symbols left unresolved must each be
  defined by something the app's link supplies, and the allow-list is
  derived from those inputs, not written down:

    * the BEAM: every symbol the target's ERTS static libraries define
      (`<otp>/erts-*/lib/**/*.a`; the `enif_*` API and the rest of ERTS),
    * mob core: the non-static C functions, globals and ObjC classes mob's
      iOS sources (`<mob_dir>/ios/*.{m,mm,c}`) define, e.g.
      `mob_register_permission_handler`,
    * the iOS SDK: every symbol a library or framework of the target's SDK
      exports (its `.tbd` stubs), since the app may link any of them,
      explicitly or through clang module autolinking.

  Anything else is a dangling reference and fails the build, naming the
  plugin, the symbols and the archive members that reference them. See
  `decisions/2026-10-13-ios-release-dead-strips-and-plugin-link-check.md`.
  """

  @word_chars ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"
  @objc_prefixes ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", "_OBJC_EHTYPE_$_", "_OBJC_IVAR_$_"]

  @doc """
  Check one built plugin archive for `target_id` (`:ios_sim` or `:ios_device`).

  `spec` is the `MobDev.Plugin.Merge.static_archives/2` entry (`:plugin`,
  `:module`); `archive` its `lib<module>.a`; `prebuilt` the archives its
  prebuilt bundle contributes for the target. Options: `:otp_dir` (the
  target's OTP runtime, **required**) and `:mob_dir` (mob's checkout; mob
  core's symbols are allowed only when given).

  Returns `:ok`, or `{:error, message}`.
  """
  @spec check(map(), :ios_sim | :ios_device, Path.t(), [Path.t()], keyword()) ::
          :ok | {:error, String.t()}
  def check(spec, target_id, archive, prebuilt, opts)
      when target_id in [:ios_sim, :ios_device] do
    otp_dir = Keyword.fetch!(opts, :otp_dir)
    sdk = sdk_name(target_id)

    MobDev.NativeBuild.with_temp_build_dir("link_check", fn dir ->
      with {:ok, unresolved} <- probe(sdk, target_id, archive, prebuilt, dir) do
        host = MapSet.union(beam_symbols(sdk, otp_dir), mob_core_symbols(opts[:mob_dir]))
        candidates = Enum.reject(unresolved, &MapSet.member?(host, &1))
        exported = sdk_exports(sdk_path(sdk), Enum.map(candidates, &tbd_name/1))

        case Enum.reject(candidates, &MapSet.member?(exported, tbd_name(&1))) do
          [] ->
            :ok

          dangling ->
            {:error, error_message(spec, target_id, dangling, referrers(sdk, archive, prebuilt))}
        end
      end
    end)
  end

  # The dylib link: no -dead_strip, unresolved symbols left for dyld
  # (`-undefined dynamic_lookup`) so the link always completes and nm can list
  # them. -force_load loads every member of the plugin's own archive; the
  # prebuilt archives contribute only what those members reach.
  defp probe(sdk, target_id, archive, prebuilt, dir) do
    dylib = Path.join(dir, "probe.dylib")

    args =
      ["-sdk", sdk, "clang++", "-arch", "arm64", min_flag(target_id), "-dynamiclib"] ++
        ["-Xlinker", "-force_load", "-Xlinker", archive | prebuilt] ++
        ["-Wl,-undefined,dynamic_lookup", "-o", dylib]

    case System.cmd("xcrun", args, stderr_to_stdout: true) do
      {_, 0} ->
        {nm, 0} = System.cmd("xcrun", ["-sdk", sdk, "nm", "-m", "-u", dylib])
        {:ok, parse_dynamic_lookups(nm)}

      {out, status} ->
        {:error,
         "linking #{archive} for the undefined-symbol check failed (exit #{status}):\n#{out}"}
    end
  end

  @doc """
  The symbols `nm -m -u` lists as left for dyld to look up (the ones the
  probe link could not resolve). Pure.
  """
  @spec parse_dynamic_lookups(String.t()) :: [String.t()]
  def parse_dynamic_lookups(nm_output) do
    for line <- String.split(nm_output, "\n"),
        [_, sym] <- [Regex.run(~r/external (\S+) \(dynamically looked up\)/, line)],
        do: sym
  end

  defp beam_symbols(sdk, otp_dir) do
    libs =
      Path.wildcard(Path.join(otp_dir, "erts-*/lib/*.a")) ++
        Path.wildcard(Path.join(otp_dir, "erts-*/lib/internal/*.a"))

    case libs do
      [] ->
        MapSet.new()

      libs ->
        {out, 0} = System.cmd("xcrun", ["-sdk", sdk, "nm", "-gUj" | libs])
        out |> String.split("\n", trim: true) |> MapSet.new()
    end
  end

  defp mob_core_symbols(nil), do: MapSet.new()

  defp mob_core_symbols(mob_dir) do
    mob_dir
    |> Path.join("ios/*.{m,mm,c}")
    |> Path.wildcard()
    |> Enum.flat_map(&(&1 |> File.read!() |> defined_symbols()))
    |> MapSet.new()
  end

  @doc """
  The Mach-O names of what a C / ObjC source defines with external linkage:
  top-level non-`static` functions and globals, and `@implementation`
  classes. A text scan, for mob core's sources (which import a Swift header
  the build generates, so they can't be compiled on their own here). Pure.
  """
  @spec defined_symbols(String.t()) :: [String.t()]
  def defined_symbols(source) do
    functions =
      Regex.scan(
        ~r/^(?!static\b|extern\b|typedef\b|return\b)[A-Za-z_][\w \t*]*?[\s*]([A-Za-z_]\w*)\s*\((?:[^;{}()]|\([^()]*\))*\)\s*\{/m,
        source,
        capture: :all_but_first
      )

    globals =
      Regex.scan(
        ~r/^(?!static\b|extern\b|typedef\b|return\b)[A-Za-z_][\w \t*]*?[\s*]([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=[^=]/m,
        source,
        capture: :all_but_first
      )

    classes =
      ~r/^@implementation\s+([A-Za-z_]\w*)/m
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.flat_map(fn [c] -> [["OBJC_CLASS_$_" <> c], ["OBJC_METACLASS_$_" <> c]] end)

    for [name] <- functions ++ globals ++ classes, do: "_" <> name
  end

  @doc """
  How a Mach-O symbol is spelled in an SDK `.tbd` stub: ObjC class, metaclass,
  exception-type and ivar symbols by their bare class (or `Class.ivar`) name,
  everything else as is. Pure.
  """
  @spec tbd_name(String.t()) :: String.t()
  def tbd_name(symbol) do
    Enum.find_value(@objc_prefixes, symbol, fn prefix ->
      if String.starts_with?(symbol, prefix), do: String.replace_prefix(symbol, prefix, "")
    end)
  end

  @doc """
  Which of `names` some `.tbd` under `sdk_path` exports, matched as whole
  words. Every library and framework the SDK ships has one.
  """
  @spec sdk_exports(Path.t(), [String.t()]) :: MapSet.t(String.t())
  def sdk_exports(_sdk_path, []), do: MapSet.new()

  def sdk_exports(sdk_path, names) do
    pattern = :binary.compile_pattern(Enum.uniq(names))

    # `**` doesn't follow symlinks; the SDK's own .tbd files are real files.
    sdk_path
    |> Path.join("**/*.tbd")
    |> Path.wildcard()
    |> Enum.reduce(MapSet.new(), fn tbd, found ->
      text = File.read!(tbd)

      for {pos, len} <- :binary.matches(text, pattern),
          word_at?(text, pos, len),
          into: found,
          do: binary_part(text, pos, len)
    end)
  end

  defp word_at?(text, pos, len) do
    not word_char?(text, pos - 1) and not word_char?(text, pos + len)
  end

  defp word_char?(text, i) when i < 0 or i >= byte_size(text), do: false
  defp word_char?(text, i), do: :binary.at(text, i) in @word_chars

  # symbol => the archive members that reference it, for the error message.
  defp referrers(sdk, archive, prebuilt) do
    {out, _} = System.cmd("xcrun", ["-sdk", sdk, "nm", "-A", "-u", archive | prebuilt])

    for line <- String.split(out, "\n", trim: true),
        [where, sym] <- [String.split(line, ": ", parts: 2)],
        reduce: %{} do
      acc -> Map.update(acc, String.trim(sym), [member(where)], &[member(where) | &1])
    end
  end

  defp member(where) do
    case String.split(where, ":") do
      [path, obj] -> "#{Path.basename(path)}(#{obj})"
      _ -> Path.basename(where)
    end
  end

  @doc """
  The build error for `dangling` (symbols nothing in the app defines), with
  the archive members referencing each from `referrers`. Pure.
  """
  @spec error_message(map(), atom(), [String.t()], %{String.t() => [String.t()]}) :: String.t()
  def error_message(spec, target_id, dangling, referrers) do
    lines =
      for sym <- Enum.sort(dangling) do
        case referrers |> Map.get(sym, []) |> Enum.uniq() |> Enum.sort() do
          [] -> "    #{sym}"
          from -> "    #{sym}  (referenced from #{Enum.join(from, ", ")})"
        end
      end

    """
    plugin #{spec.plugin}: lib#{spec.module}.a (#{target_id}) references symbols that \
    nothing in an iOS app defines (not the plugin's archives, the BEAM, mob or the iOS SDK):
    #{Enum.join(lines, "\n")}
    A dead-stripping link drops code it never reaches, so this can link today and \
    fail as soon as that code is reached or linked without -dead_strip (MOB-470). \
    Fix the plugin: add the sources that define these symbols to the manifest's \
    :sources, or remove the references.\
    """
  end

  defp sdk_name(:ios_sim), do: "iphonesimulator"
  defp sdk_name(:ios_device), do: "iphoneos"

  defp min_flag(target_id), do: MobDev.Plugin.CppArchive.ios_min_flag(target_id)

  defp sdk_path(sdk) do
    {out, 0} = System.cmd("xcrun", ["-sdk", sdk, "--show-sdk-path"])
    String.trim(out)
  end
end
