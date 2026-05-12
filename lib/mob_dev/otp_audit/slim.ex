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

  ## Audit-driven expansion + the always-keep guardrail

  When the caller passes `:audit_input` (typically via mob.exs
  `slim: [audit: true, trace_json: "..."]`), the strip set grows
  by:

    * `audit.foreign_app_names` (allow-list-validated cache cruft)
    * `strippable_libs ∩ trace_strippable_libs` (both signals agree)
    * `trace_strippable_libs \\ strippable_libs` (trace-only — libs
      the static graph reaches but the trace says are never called)

  The last category is the powerful one and the dangerous one. A
  60-second trace window can easily miss libs that ARE used but
  only at boot (`sasl`) or only in code paths the user didn't
  drive during the window (`crypto`, `public_key`, `asn1`, `ssl`
  when no TLS happens). Auto-stripping those would break apps.

  The `always_keep_libs/0` set is the safety guardrail: those libs
  are NEVER added to the strip set by audit-driven expansion, no
  matter what the trace says. The hardcoded baseline still strips
  what it strips, and `:drop_libs` still works as the user-explicit
  escape hatch — but the trace can't accidentally take down crypto
  or sasl.

  Override patterns from `mob.exs`:

      config :mob_dev,
        slim: [
          # Force-keep — user override beats everything else.
          # Use this if audit-driven strip is taking out a lib you
          # actually need at runtime.
          keep_libs: ["some_lib"],

          # Force-strip — user override beats the audit. Use this
          # to expand beyond what the trace alone would mark.
          drop_libs: ["my_unused_dep"]
        ]

  Precedence (in order from least to most authoritative): hardcoded
  baseline → audit-derived expansion (minus always_keep_libs) →
  `:drop_libs` → `:keep_libs`. The user's `:keep_libs` is always
  the last word.
  """

  @hardcoded_prefixes ~w(
    megaco runtime_tools erl_interface os_mon wx et eunit
    observer debugger diameter edoc tools snmp dialyzer
    syntax_tools parsetools xmerl reltool inets ftp tftp
    common_test mnesia eldap odbc
    compiler ssh
  )

  # Libs that the audit-driven expansion is forbidden from
  # adding to the strip set, even when both static and trace
  # agree the lib is unused. Rationale: a finite-duration trace
  # can miss code paths that boot the BEAM (sasl), respond to
  # rare events (crypto/ssl/asn1/public_key in TLS handshakes),
  # or load lazily (logger handlers). Better to ship a slightly
  # fatter bundle than to ship one that crashes at startup.
  #
  # The user's `:drop_libs` can override this if they're sure
  # (drop_libs is added AFTER the audit expansion in the merge).
  # That's the intentional escape hatch — opinionated default
  # with a user-explicit override.
  @always_keep_libs ~w(
    kernel stdlib erts elixir logger
    sasl
    crypto public_key asn1 ssl
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
  Libs that audit-driven expansion is forbidden from auto-stripping.
  Source of truth for the safety guardrail — see moduledoc.
  Users can still force-strip these via `:drop_libs` in `mob.exs`.
  """
  @spec always_keep_libs() :: [String.t()]
  def always_keep_libs, do: @always_keep_libs

  @doc """
  Compute the final strip set. Returns a sorted, deduplicated list.

  ## Composition (low to high precedence)

    1. `hardcoded_prefixes/0` — baseline.
    2. `:audit_input` expansion (when given), minus `always_keep_libs/0`
       (the safety guardrail).
    3. `:drop_libs` — user-explicit force-strip.
    4. `:keep_libs` — user-explicit force-keep. Wins over everything.

  ## Recognized opts

    * `:keep_libs` — `[String.t()]`, force-keep (subtracts from set).
      Highest precedence — overrides every other source.
    * `:drop_libs` — `[String.t()]`, force-strip (adds to set).
      Higher precedence than the guardrail: a user can `:drop_libs`
      a lib that's in `always_keep_libs/0` if they really mean it.
    * `:audit_input` — `MobDev.OtpAudit.report/0` to expand the strip
      set with audit-derived libs:
        - `report.foreign_app_names` always unions in (allow-list-
          validated by OtpAudit's `:project_deps`).
        - When the audit was run with `:trace_input`:
          - `strippable_libs ∩ trace_strippable_libs` unions in
            (both signals agree → high confidence).
          - `trace_strippable_libs \\ strippable_libs` unions in
            (trace-only — the megaco/snmp/diameter unblocking signal).
        - `strippable_libs` alone is NOT unioned without trace
          (NIF dispatch like `exqlite` is statically invisible).
        - The expansion is then filtered through
          `always_keep_libs/0` so trace lies (e.g. trace window
          missed sasl boot or crypto's lazy TLS calls) can't break
          production.
  """
  @spec compute_strip_set(keyword()) :: [String.t()]
  def compute_strip_set(opts \\ []) do
    keep = opts |> Keyword.get(:keep_libs, []) |> MapSet.new()
    drop = opts |> Keyword.get(:drop_libs, []) |> MapSet.new()
    audit_expansion = audit_expansion(opts[:audit_input])

    @hardcoded_prefixes
    |> MapSet.new()
    |> MapSet.union(audit_expansion)
    |> MapSet.union(drop)
    |> MapSet.difference(keep)
    |> Enum.sort()
  end

  # Builds the set of additional strippable lib names from an audit
  # report. Returns an empty MapSet when no audit was given.
  defp audit_expansion(nil), do: MapSet.new()

  defp audit_expansion(audit_input) do
    foreign = MapSet.new(audit_input.foreign_app_names || [])
    static = MapSet.new(audit_input.strippable_libs || [])

    expansion =
      case audit_input.trace_strippable_libs do
        nil ->
          # No trace data — only the (allow-list-validated) foreign apps
          # are safe to add. Static-only `strippable_libs` is risky
          # without trace (NIF dispatch invisible to the import graph).
          foreign

        trace ->
          trace_set = MapSet.new(trace)
          # Both signals agree the lib is dead → safest.
          confirmed = MapSet.intersection(static, trace_set)
          # Trace says never called even though static reaches it → the
          # high-value signal that unlocks megaco / snmp / etc.
          trace_only = MapSet.difference(trace_set, static)

          foreign
          |> MapSet.union(confirmed)
          |> MapSet.union(trace_only)
      end

    # Safety guardrail: a finite trace window can miss boot-time or
    # event-driven calls (sasl boots before tracing starts; crypto/ssl/
    # public_key/asn1 only fire during TLS or signing). Auto-stripping
    # any of those because the trace didn't see them would crash apps.
    # The user can still force-strip via `:drop_libs` — but the default
    # behaviour is opinionated: protect production from a too-narrow
    # trace.
    MapSet.difference(expansion, MapSet.new(@always_keep_libs))
  end

  @doc """
  Apply the strip pass to an OTP bundle in place.

  Recognized opts:
    * `:keep_libs`, `:drop_libs`, `:audit_input` — see
      `compute_strip_set/1`.
    * `:strip_set` — short-circuit override. When set, every other
      opt that would feed into the computation is ignored. Primarily
      for tests.
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
