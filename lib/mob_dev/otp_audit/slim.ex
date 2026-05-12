defmodule MobDev.OtpAudit.Slim do
  @moduledoc """
  In-place strip pass for the per-app OTP bundle, called by
  `MobDev.NativeBuild` when `MOB_SLIM=1`. Was an inline ~100-line
  `defp` in `native_build.ex`; extracted here so it's testable and
  has a place for per-app override hooks to live.

  ## What gets stripped

  Six phases run in fixed order against `<app_bundle>/otp`:

    1. `apple_binaries` — `.so` / `.a` and `priv/bin/*` (Apple-policy
       parity: no standalone executables in the bundle)
    2. `prefix_libs` — every `lib/<name>-*` whose `<name>` is in the
       computed strip set (see `compute_strip_set/1`)
    3. `foreign_apps` — `lib/{toy_,test_,mob_test,scratch_}*` (other
       projects' code that snuck into a shared OTP cache)
    4. `dedup_versions` — when the same lib appears at multiple
       versions, keep only the highest
    5. `src_and_headers` — every `src/` and `include/` directory
    6. `beam_chunks` — `:beam_lib.strip_release/1` drops Debug/Doc
       chunks from every `.beam`

  Steps are intentionally idempotent so repeat runs are safe.

  ## Strip set composition

  The default strip set is the hardcoded baseline (`hardcoded_prefixes/0`)
  — a curated list of OTP libs mobile apps never need (megaco, snmp,
  diameter, …). Per-app overrides in `mob.exs` adjust the set:

      config :mob_dev,
        slim: [
          drop_libs: ["foo_dep"],   # force-strip these too
          keep_libs: ["mnesia"]     # don't strip these even if baseline says so
        ]

  `drop_libs` and `keep_libs` accept plain `<name>` strings — the
  same shape `MobDev.OtpAudit`'s report uses, so users can copy
  basenames directly out of `mix mob.audit_otp` output.

  ## What this does NOT do (yet)

  Audit-driven auto-expansion of the strip set is a follow-up. The
  static audit can't see NIF dispatch (`:erlang.load_nif`) and would
  classify `exqlite` and friends as strippable. Auto-union is
  blocked on tighter foreign-app detection and the trace-driven
  confidence work in `MobDev.OtpTrace`.
  """

  @hardcoded_prefixes ~w(
    megaco runtime_tools erl_interface os_mon wx et eunit
    observer debugger diameter edoc tools snmp dialyzer
    syntax_tools parsetools xmerl reltool inets ftp tftp
    common_test mnesia eldap odbc
    compiler ssh
  )

  @foreign_app_prefixes ~w(toy_ test_ mob_test scratch_)

  @type step_info :: %{
          label: String.t(),
          before_kb: non_neg_integer(),
          after_kb: non_neg_integer()
        }

  @type slim_result :: %{
          steps: [step_info()],
          final_kb: non_neg_integer(),
          strip_set: [String.t()]
        }

  @doc """
  Hardcoded baseline of OTP libs mobile apps never need. Source of
  truth for what `mix mob.deploy --slim` strips by default.
  """
  @spec hardcoded_prefixes() :: [String.t()]
  def hardcoded_prefixes, do: @hardcoded_prefixes

  @doc """
  Compute the final strip set: `hardcoded_prefixes ∪ drop_libs \\ keep_libs`.
  Returns a sorted, deduplicated list.

  Recognized opts:
    * `:keep_libs` — `[String.t()]`, force-keep (subtracts from set)
    * `:drop_libs` — `[String.t()]`, force-drop (adds to set)
  """
  @spec compute_strip_set(keyword()) :: [String.t()]
  def compute_strip_set(opts \\ []) do
    keep = opts |> Keyword.get(:keep_libs, []) |> MapSet.new()
    drop = opts |> Keyword.get(:drop_libs, []) |> MapSet.new()

    @hardcoded_prefixes
    |> MapSet.new()
    |> MapSet.union(drop)
    |> MapSet.difference(keep)
    |> Enum.sort()
  end

  @doc """
  Apply the strip pass to an OTP bundle in place.

  Recognized opts:
    * `:keep_libs`, `:drop_libs` — see `compute_strip_set/1`.
    * `:strip_set` — short-circuit override. When set, `keep_libs` and
      `drop_libs` are ignored. Primarily for tests.
    * `:on_step` — optional callback `fn(step_info) -> any()` invoked
      after each phase. Caller uses it for build-log output.

  Returns `{:ok, slim_result()}`. The bundle is mutated in place; if a
  phase fails, the bundle is in a partially-stripped state (matches the
  pre-extraction behaviour, which had no rollback either).
  """
  @spec slim_bundle(Path.t(), keyword()) :: {:ok, slim_result()}
  def slim_bundle(otp_bundle, opts \\ []) do
    strip_set = opts[:strip_set] || compute_strip_set(opts)
    on_step = opts[:on_step] || fn _ -> :ok end
    erts_vsn = detect_erts_vsn(otp_bundle) || ""

    steps =
      phases()
      |> Enum.map(fn {label, fun} ->
        before_kb = bundle_size_kb(otp_bundle)
        fun.(otp_bundle, strip_set, erts_vsn)
        after_kb = bundle_size_kb(otp_bundle)
        step = %{label: label, before_kb: before_kb, after_kb: after_kb}
        on_step.(step)
        step
      end)

    {:ok,
     %{
       steps: steps,
       final_kb: bundle_size_kb(otp_bundle),
       strip_set: strip_set
     }}
  end

  # ── Phase table ────────────────────────────────────────────────────────

  defp phases do
    [
      {"apple_binaries", &strip_apple_binaries/3},
      {"prefix_libs", &strip_prefix_libs/3},
      {"foreign_apps", &strip_foreign_apps/3},
      {"dedup_versions", &strip_dedup_versions/3},
      {"src_and_headers", &strip_src_and_headers/3},
      {"beam_chunks", &strip_beam_chunks/3}
    ]
  end

  # ── Phase implementations ──────────────────────────────────────────────

  defp strip_apple_binaries(otp_bundle, _strip_set, erts_vsn) do
    # Apple-policy parity: no .so/.a in the bundle, no standalone
    # executables. NIFs are statically linked into the main binary
    # via STATIC_ERLANG_NIF.
    Enum.each(Path.wildcard("#{otp_bundle}/**/*.so"), &File.rm!/1)
    Enum.each(Path.wildcard("#{otp_bundle}/**/*.a"), &File.rm!/1)

    "#{otp_bundle}/**/priv/bin/*"
    |> Path.wildcard()
    |> Enum.each(fn p -> if File.regular?(p), do: File.rm!(p) end)

    if erts_vsn != "" do
      erts_bin = Path.join([otp_bundle, erts_vsn, "bin"])

      if File.dir?(erts_bin) do
        erts_bin
        |> File.ls!()
        |> Enum.map(&Path.join(erts_bin, &1))
        |> Enum.each(fn p -> if File.regular?(p), do: File.rm!(p) end)
      end
    end
  end

  defp strip_prefix_libs(otp_bundle, strip_set, _erts_vsn) do
    for prefix <- strip_set do
      "#{otp_bundle}/lib/#{prefix}-*"
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf!/1)
    end
  end

  defp strip_foreign_apps(otp_bundle, _strip_set, _erts_vsn) do
    # Cache hygiene — apps from other projects that ended up in a
    # shared OTP cache. The heuristic here is intentionally narrow
    # (matches naming conventions used inside this repo); tighter
    # cross-reference with the project's deps lives in a follow-up.
    for prefix <- @foreign_app_prefixes do
      "#{otp_bundle}/lib/#{prefix}*-*"
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf!/1)
    end
  end

  defp strip_dedup_versions(otp_bundle, _strip_set, _erts_vsn) do
    lib_dir = Path.join(otp_bundle, "lib")

    if File.dir?(lib_dir) do
      lib_dir
      |> File.ls!()
      |> Enum.map(&Path.join(lib_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.group_by(fn dir ->
        dir |> Path.basename() |> String.replace(~r/-[\d.]+$/, "")
      end)
      |> Enum.each(fn {_name, dirs} ->
        if length(dirs) > 1 do
          latest = Enum.max_by(dirs, &Path.basename/1)
          dirs |> Enum.reject(&(&1 == latest)) |> Enum.each(&File.rm_rf!/1)
        end
      end)
    end
  end

  defp strip_src_and_headers(otp_bundle, _strip_set, _erts_vsn) do
    for name <- ~w(src include) do
      "#{otp_bundle}/**/#{name}"
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.each(&File.rm_rf!/1)
    end
  end

  defp strip_beam_chunks(otp_bundle, _strip_set, _erts_vsn) do
    # :beam_lib.strip_release/1 walks every `.beam` under the dir and
    # drops Debug/Doc/Dbgi chunks. Same trick `mix release` uses for
    # production builds.
    case :beam_lib.strip_release(String.to_charlist(otp_bundle)) do
      {:ok, _} -> :ok
      # Best-effort — a single corrupt .beam shouldn't fail the whole
      # build. The eager-load verifier (`mix mob.verify_strip`) is the
      # backstop that catches bundles too aggressively stripped.
      {:error, :beam_lib, _reason} -> :ok
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  @doc false
  @spec detect_erts_vsn(Path.t()) :: String.t() | nil
  def detect_erts_vsn(otp_bundle) do
    case Path.wildcard(Path.join(otp_bundle, "erts-*")) do
      [path | _] -> Path.basename(path)
      [] -> nil
    end
  end

  defp bundle_size_kb(dir) do
    case System.cmd("du", ["-sk", dir], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> List.first() |> String.to_integer()
      _ -> 0
    end
  end
end
