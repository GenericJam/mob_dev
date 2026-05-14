# Static NIFs

Mob ships NIFs **statically linked** into the main app binary. This is
non-negotiable on mobile:

- **iOS App Store** rejects bundled `.dylib` files outright. A
  dlopen'd NIF can't pass review.
- **Android `RTLD_LOCAL`** hides the parent process's `enif_*`
  symbols from a child library loaded by `System.loadLibrary` or
  `dlopen`. A NIF that looks for `enif_make_atom` at load time
  doesn't find it.

Both platforms point at the same answer: link the NIF's init function
into the main binary alongside `libbeam.a`, and register it in a
**static NIF table** so `load_nif/2` resolves to the embedded code
instead of opening a shared library.

`mix mob.add_nif <name>` is the single entry point. The four backends
(`c`, `rustler`, `zigler`, `elixir-only`) all produce the same shape
of artifact for the linker — a `lib<name>.a` (or `<name>.o`, for C)
exporting `<name>_nif_init`. What differs is the language you write
the NIF body in and the toolchain that produces the archive.

This guide is the **contract per backend**: how each upstream library
normally works, and what Mob changes (or leaves alone) to make
on-device static linking work. The aim is that a user — or an agent
acting on their behalf — never has to read the build code to answer
"what does Mob do with my Rust crate?"

For app-level integration of Python specifically (wheel handling,
asset extraction, the host-dev fallback), see
[`python_embedding.md`](python_embedding.md) — this guide covers only
the NIF-layer story.

---

## Anatomy of a static NIF in Mob

Every backend ends up at the same three artifacts in the same three
places. The differences below are about *how each gets generated*,
not *what it is at link time*.

| Artifact | Where it lives | Who writes it |
|----------|---------------|---------------|
| Elixir stub module | `lib/<app>/nifs/<name>.ex` | `mob.add_nif` scaffolds; you fill in function signatures |
| Native source | `c_src/<name>.c`, `native/<name>/src/lib.rs`, or `~Z` block in the stub | depends on backend |
| Static archive | `lib<name>.a` (cross-compiled per arch) | `mob_dev` invokes the backend's toolchain |

The link-time dispatch table — `priv/generated/driver_tab_ios.zig`
and `priv/generated/driver_tab_android.zig` — declares
`<name>_nif_init` as `extern fn` and adds it to
`erts_static_nif_tab[]`, which the BEAM consults instead of `dlopen`
when the Elixir stub calls `:erlang.load_nif/2`. The table is
regenerated from `mob.exs`'s `:static_nifs` list by
`mix mob.regen_driver_tab` (which `mob.add_nif` composes
automatically, so you rarely call it directly).

[`MobDev.StaticNifs`](`MobDev.StaticNifs`) is the schema reference for
the manifest entries.

---

## C

### How `erl_nif` normally works

A C NIF is a `.c` file that includes `<erl_nif.h>`, defines a few
functions matching the `ErlNifFunc` table, and ends with the
`ERL_NIF_INIT` macro. The Erlang VM compiles it as a shared library,
the Elixir module's `:erlang.load_nif/2` dlopens that library, and
the BEAM looks up the init symbol — which is hardcoded as plain
`nif_init` in dynamic mode.

Upstream reference: [the `erl_nif` man page](https://www.erlang.org/doc/apps/erts/erl_nif.html)
and the [User's Guide tutorial](https://www.erlang.org/doc/system/nif.html).

### How Mob handles it

Mob compiles the same `.c` source as a regular `.o` file and links it
straight into the app binary alongside `libbeam.a`. Two compile-time
flags switch `<erl_nif.h>` from "dlopen mode" into "static mode":

- `-DSTATIC_ERLANG_NIF` — selects the static-link dispatch path inside
  `erl_nif.h`. Without it the `ERL_NIF_INIT` macro emits the dynamic
  `nif_init` symbol, which collides across multiple NIFs.
- `-DSTATIC_ERLANG_NIF_LIBNAME=<name>` — overrides the init symbol
  to `<name>_nif_init`. The static table declares it by that exact
  name, so they have to match. Without the override, the macro
  mangles to `Elixir.<...>_nif_init`, which isn't a valid C
  identifier and fails to compile.

That's all. The C code itself is identical to a portable NIF — no
Mob-specific includes, no special prologue. You can prototype a NIF
against any vanilla BEAM via `mix compile` then drop it into Mob
unchanged.

Scaffold:

```bash
mix mob.add_nif audio_engine --type c
```

Drops `c_src/audio_engine.c` with the macro pre-wired, generates the
Elixir stub, appends `%{module: :audio_engine, archs: [:all]}` to
`mob.exs`'s `:static_nifs`, and re-runs `mob.regen_driver_tab`.

---

## Rust via Rustler

### How Rustler normally works

A standard Rustler project has a Cargo crate (typically at
`native/<crate>/`) declared with `crate-type = ["cdylib"]`. Cargo
builds a `.so` containing `#[rustler::nif]`-annotated functions
registered via the `rustler::init!(...)` macro. The Elixir side calls
`use Rustler, otp_app: :app, crate: "name"`, which:

1. Invokes Cargo at compile time
2. Copies the produced `.so` to `priv/native/<crate>.so`
3. Wires `:erlang.load_nif/2` to that path so the BEAM dlopens it

Upstream reference: [the Rustler crate](https://docs.rs/rustler/) and
the [Rustler GitHub README](https://github.com/rusterlium/rustler).

### How Mob handles it

Three differences from the standard flow. None of them touch the Rust
source code.

**1. Dual `crate-type`.** Mob's scaffolded Cargo.toml has:

```toml
crate-type = ["staticlib", "cdylib"]
```

The `cdylib` keeps host-dev's `mix compile` working — same
dlopen-the-`.so` path Rustler users know. The `staticlib` is what
mob_dev's cross-compile actually consumes: `cargo rustc --crate-type
staticlib --target <arch>` produces a `lib<name>.a` that's linked
into the main app binary on-device.

**2. Symbol convention requires rustler 0.37+.** Rustler 0.37 changed
the static-NIF init symbol to derive from `CARGO_CRATE_NAME` as
`<crate>_nif_init`. Earlier versions hardcoded plain `nif_init`,
which would collide if you had multiple Rust NIFs in one app (linker
errors on duplicate symbols). Mob's `driver_tab` declares each NIF
by `<crate>_nif_init`, so the pin to 0.37 is load-bearing — don't
silently downgrade it.

**3. Android dlsym workaround (transient).** Rustler 0.37's
`nif_filler` uses `dlopen(NULL)` to locate `enif_*` symbols at NIF
init. On Bionic that handle resolves to a namespace which doesn't
include the app's own `.so` siblings, even when they're marked
`RTLD_GLOBAL`. Every NIF init panics with `undefined symbol:
enif_priv_data`.

The scaffolded Cargo.toml carries a `[patch.crates-io]` block
pointing at [GenericJam/rustler:genericjam-android-rtld-default](https://github.com/GenericJam/rustler/tree/genericjam-android-rtld-default),
which patches the Android branch to do `dladdr` + `dlopen(self,
RTLD_NOLOAD)` for an explicit self-handle. iOS/macOS/Linux paths in
the fork are unchanged. Tracker: [mob#7](https://github.com/GenericJam/mob/issues/7).
Drop the patch block (and bump the version pin) once upstream
rustler merges the fix.

### What stays standard

Everything in the Rust source. You can:

- Put as many `.rs` files in `native/<name>/src/` as you want, organized
  via standard `mod foo;` / `mod bar;` declarations.
- Add any Cargo dependency to `[dependencies]` — `serde`, `tokio`,
  `bytes`, anything. Cargo handles resolution and linking.
- Write unit tests with `cargo test` and run them on the host like
  any other crate.
- Use Rustler's full surface — `Term`, `Atom`, `Encoder`/`Decoder`,
  `ResourceArc`, `NifTuple`, etc. — without modification.

### Multiple Rust NIFs per app

Each `mob.exs :static_nifs` entry whose name matches a
`native/<name>/Cargo.toml` is cross-compiled to its own
`lib<name>.a` and linked. No workspace required. `nif_combo` ships
three NIFs (`greet_c` + `greet_rust` + `greet_zig`) in one app as
the canonical example.

If you want Cargo workspaces for shared deps across multiple Rust
NIFs, the scaffold doesn't generate one but Cargo's
workspace-detection is transparent to `cargo rustc --manifest-path
native/<name>/Cargo.toml`. Add a `native/Cargo.toml` workspace
yourself and Cargo wires it up.

Scaffold:

```bash
mix mob.add_nif audio_engine --type rustler
```

---

## Zig via Zigler

### How Zigler normally works

[Zigler](https://hex.pm/packages/zigler) lets you embed Zig directly
in an Elixir module via the `~Z` sigil, compiles it through Zig's
build system at `mix compile` time, and exposes each `pub fn` as a
NIF function on the module. Standard usage produces a dynamically
loaded `.so` — same dlopen-at-load model as Rustler's default.

Upstream reference: [the Zigler hex docs](https://hexdocs.pm/zigler/)
and the [Zigler GitHub README](https://github.com/E-xyza/zigler).

### How Mob handles it

Mob uses a fork of Zigler pinned via the scaffolded `mix.exs`:

```elixir
{:zigler, github: "GenericJam/zigler", branch: "zig-016-port"}
```

Two reasons the fork exists, both invisible to Zig source code:

**1. macOS 26 (Sequoia/Tahoe) compatibility.** Upstream Zigler pins
Zig 0.15.x, whose bundled `compiler_rt` references
`__availability_version_check` and friends that aren't present in
the macOS 26 SDK. Compiles fail with a cascade of POSIX
symbol-undefined errors on developer machines that have upgraded
past the SDK boundary. The fork ports `priv/beam/` to Zig 0.16.0,
which works against the macOS 26 SDK.

**2. Static-NIF init symbol collision.** Zigler 0.16's emitted NIF
init function was a bare `nif_init` (same name Rustler ≤0.36 used).
When you statically link a Zig NIF alongside any other NIF in
mob's `driver_tab`, the linker merges them into one symbol and
silently corrupts per-module dispatch. The fork honors a
`-Dnif_init_alias=<name>_nif_init` flag so each Zig NIF gets a
unique exported init symbol, matching what `driver_tab` declares.

Once upstream Zigler ships Zig 0.16 support natively and accepts a
per-NIF init alias, the fork dissolves. Track upstream issue #578 and
PR #579.

The `mob.add_nif --type zigler` scaffold also runs `mix zig.get`
afterward so Zigler's `executable_path` lookup finds the cached Zig
0.16.0 before falling through to `PATH` (which on most mob
developer machines points at Zig 0.17-dev — wrong stdlib for the
port).

### What stays standard

The Zig source itself. Any `pub fn` becomes a NIF; Zigler's
type-mapping table works as documented upstream; resource types,
beam.send, etc. all behave identically to non-Mob Zigler projects.

Scaffold:

```bash
mix mob.add_nif audio_engine --type zigler
```

---

## Python via Pythonx

Python is a different beast from C/Rust/Zig — it's not a single NIF
crate you compile, it's a whole interpreter that ships inside the
app. The static-link mechanics still apply (the **Pythonx** NIF is
statically linked, just like any other Rust NIF), but the Python
runtime + standard library + C extensions need to come from
somewhere, and there's no upstream that ships *one* binary
distribution covering iOS and Android.

### How Pythonx normally works

[Pythonx](https://hex.pm/packages/pythonx) embeds CPython into the
BEAM via a NIF (written in Rust, using
[PyO3](https://github.com/PyO3/pyo3)). On a developer machine, it
fetches CPython through [`uv`](https://github.com/astral-sh/uv) on
first run, installs it under a project-local cache, and `dlopen`s
`libpython` from there. `Pythonx.eval/2` runs Python code in that
in-process interpreter.

Upstream reference: [Pythonx hex docs](https://hexdocs.pm/pythonx/)
and the [Pythonx GitHub README](https://github.com/livebook-dev/pythonx).

### How Mob handles it

**The Pythonx NIF itself** is treated like any other Rust NIF —
cross-compiled to `libpythonx.a`, linked into the main binary,
registered in `driver_tab`. Same static-link story as Rustler above.

**The Python runtime** is the part that differs. There's no
`uv install` on iOS or Android (no shell, no PATH, sandboxed
filesystem), and Pythonx's normal fetch flow can't run on-device. Mob
ships a pre-built CPython distribution for each platform, bundled
into the app artifact and extracted on first launch.

Both platforms target **Python 3.13** so user code is portable. The
sources differ because no single upstream ships both:

**iOS — [BeeWare's Python-Apple-support](https://github.com/beeware/Python-Apple-support).**

- Version pinned to `3.13-b13` (BeeWare's release tag — Python
  3.13 plus their `b13` build revision).
- Distribution shape: an `Python.xcframework` containing the
  arch slices for iOS device + iOS simulator, plus the stdlib
  and standard C extensions (`_ssl`, `_ctypes`, `_hashlib`, etc.).
- Tarball URL pattern: `https://github.com/beeware/Python-Apple-support/releases/download/3.13-b13/Python-3.13-iOS-support.b13.tar.gz`
- Implementation: [`MobDev.PythonAppleSupport`](`MobDev.PythonAppleSupport`)
  in mob_dev. Cached at `~/.mob/cache/python-apple-support-<version>/`.

**Android — [Chaquopy](https://chaquo.com/chaquopy/)'s target distribution.**

- Version pinned to `3.13.9-0` (Chaquopy's `<python>.<patch>-<chaquopy-rev>`
  versioning — Python 3.13.9 plus Chaquopy revision 0).
- Distribution shape: per-ABI zips (arm64-v8a + x86_64) containing
  `libpython3.13.so` plus `libcrypto_python.so`, `libssl_python.so`,
  `libsqlite3_python.so`, the lib-dynload C extensions, and a
  separate stdlib zip.
- Maven Central URL pattern: `https://repo1.maven.org/maven2/com/chaquo/python/target/...`
- License: Apache 2.0 (as of 2025).
- Implementation: [`MobDev.PythonAndroidSupport`](`MobDev.PythonAndroidSupport`)
  in mob_dev. Cached at `~/.mob/cache/python-android-support-<version>/`.

**Why two sources?** BeeWare's `Python-Android-support` (the natural
sibling of `Python-Apple-support`) hasn't shipped a release since
Python 3.10. Chaquopy is currently the only actively-maintained
source of pre-built CPython binaries for Android 3.11+. We use it
for the binaries only — Chaquopy's Java↔Python bridge is bypassed
entirely; Pythonx talks to `libpython3.13.so` through the same FFI
contract on both platforms.

**What this means in practice:**

- Your Python code runs against CPython 3.13 on both platforms. The
  stdlib is BeeWare's pure-Python copy on iOS and Chaquopy's pure-
  Python copy on Android — both come straight from python.org's
  3.13 source tree, so they're functionally identical for stdlib
  surface.
- Standard C extensions (`_ssl`, `socket`, `_hashlib`, …) are
  present on both. Build flags differ slightly between BeeWare and
  Chaquopy, so a determined user could find a corner case where
  e.g. SSL cipher suites differ — but for nearly all code, the
  platforms are interchangeable.
- Patch versions can drift mildly. Today iOS is on Python 3.13.x
  (BeeWare b13's underlying CPython tag) and Android is on Python
  3.13.9 (Chaquopy's pin). Both move together in lockstep with our
  manual end-to-end validation when either upstream cuts a new
  release.
- **Third-party wheels are out of scope.** See
  [`python_embedding.md`](python_embedding.md) for the "build your
  own wheel" guidance per platform.

### What stays standard

Pythonx itself is unchanged. `Pythonx.eval/2`, `Pythonx.encode/1`,
`Pythonx.decode/1`, the `Pythonx.Object` resource — all behave
identically to a host-dev project. Your Python code never sees
that the interpreter came from a different upstream.

Scaffold:

```bash
mix mob.enable pythonx     # not `mob.add_nif` — Pythonx is an enable, not a generic NIF
```

For the app-integration story (when Pythonx initializes, where
extracted files live, how to ship third-party wheels, host-dev
fallback), see [`python_embedding.md`](python_embedding.md).

---

## Multiple NIFs per app, generally

`mob.exs`'s `:static_nifs` is a list. Each entry follows the schema:

```elixir
%{module: :nif_name, archs: [:all]}        # link on all targets
%{module: :nif_name, archs: [:ios]}        # link only on iOS targets
%{module: :nif_name, archs: [:android_arm64]}  # narrow to one Android ABI
```

See [`MobDev.StaticNifs`](`MobDev.StaticNifs`) for the full schema,
arch atoms, and the per-arch `_nif_init` symbol-name mapping. The
order in the list determines link order, which matters if NIFs have
inter-symbol dependencies (rare) but is otherwise cosmetic.

`mob.add_nif` always appends with `archs: [:all]` and assumes you'll
narrow that manually if needed. Hand-editing `mob.exs` and re-running
`mix mob.regen_driver_tab` is the supported way to adjust arch
guards after the fact.

---

## Inspecting what got linked

After `mix mob.deploy --native` finishes:

```bash
# iOS sim binary, list every static NIF init exported
nm -gU ios/MobApp.app/MobApp | grep _nif_init

# Android arm64 .so, same
llvm-readelf --dyn-syms android/app/build/intermediates/stripped_native_libs/debug/out/lib/arm64-v8a/lib<app>.so | grep _nif_init
```

Each `:static_nifs` entry should appear exactly once. A missing
symbol means the link step didn't see the archive (check
`-Dproject_rust_libs` in the zig invocation); a duplicate means
two scaffolds collided (rename one).

---

## When the upstream lands its own fix

The three transient items above will each have a clean exit:

| Backend | Workaround | Drop when |
|---------|-----------|-----------|
| Rustler | `[patch.crates-io]` block in scaffold's Cargo.toml | upstream rustler ships the dladdr+dlopen(NOLOAD) fix for Android (tracker: [mob#7](https://github.com/GenericJam/mob/issues/7)) |
| Zigler  | `github: "GenericJam/zigler", branch: "zig-016-port"` pin | upstream Zigler ships Zig 0.16 support AND honors a per-NIF `nif_init_alias` flag (tracker: upstream #578 / #579) |
| Python (Android) | Chaquopy as the source | BeeWare's `Python-Android-support` returns to active maintenance with a 3.11+ release |

Until then these stay where they are — the scaffold writes them out
loudly, with comments pointing at this guide.
