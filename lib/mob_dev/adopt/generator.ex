defmodule MobDev.Adopt.Generator do
  @moduledoc """
  EEx-template assigns, native-tree template/static roots, dep
  resolution, and Pythonx wiring for `mix mob.adopt`.

  Duplicated from `MobNew.ProjectGenerator` (mob_new, the project
  generator archive). Only the transitive closure `mix mob.adopt`
  exercises was copied — the full `mix mob.new` generation pipeline
  (`generate/3`, `liveview_generate/3`, the `mix phx.new` shell-out,
  the config/router patchers) stays in mob_new. Phase 5 of
  `build_system_migration.md` reunifies the two copies behind a single
  Igniter-based path; until then both repos carry their own copy
  (mob_new can't depend on mob_dev — it's a self-contained Mix archive;
  see `ArchiveSelfContainedTest`).

  ## Native templates come from the installed mob_new archive

  The Android/iOS native trees `mob.adopt` emits are rendered from
  mob_new's `priv/templates/mob.new/` and `priv/static/mob.new/`. Those
  template files belong to the generator and are deliberately NOT
  duplicated here. By design, `mix mob.adopt --android/--ios` requires the
  mob_new archive installed (`mix archive.install hex mob_new`) in addition
  to mob_dev as a project dep — mob_new stays the single source of native
  templates, so the two can't drift. Mix puts an installed archive on the
  code path, so `:code.priv_dir(:mob_new)` resolves its bundled priv at
  runtime — the same way mob_new's own `mix mob.new` loads them.
  `templates_root/1` / `static_root/1` prefer that, then fall back to a
  local checkout via `$MOB_NEW_DIR` / `~/code/mob_new` for development. See
  `decisions/2026-06-19-mob-adopt-lives-in-mob_dev.md`.

  ## Compile-time regex

  Compiles regexes at runtime via `Regex.compile!/1`, never `~r//`
  literals (OTP 28.0 dropped `:re.import/1`). See mob `AGENTS.md` rule #9.
  """

  alias MobDev.NdkVersion

  @doc false
  @spec templates_root(keyword()) :: String.t()
  def templates_root(opts), do: priv_root(opts) |> Path.join("templates/mob.new")

  @doc false
  @spec static_root(keyword()) :: String.t()
  def static_root(opts), do: priv_root(opts) |> Path.join("static/mob.new")

  # The native templates ship in mob_new, not mob_dev. Resolve mob_new's
  # priv dir: prefer the installed mob_new archive (on Mix's code path, so
  # `:code.priv_dir(:mob_new)` finds its bundled priv), then a local
  # checkout via `$MOB_NEW_DIR` / `~/code/mob_new` for development.
  defp priv_root(_opts) do
    case mob_new_priv_from_code() do
      nil -> mob_new_priv_from_checkout() || raise_no_templates()
      dir -> dir
    end
  end

  defp mob_new_priv_from_code do
    case :code.priv_dir(:mob_new) do
      {:error, _} -> nil
      path -> if templates_present?(to_string(path)), do: to_string(path)
    end
  end

  defp mob_new_priv_from_checkout do
    [System.get_env("MOB_NEW_DIR"), Path.expand("~/code/mob_new")]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&priv_if_templates_exist/1)
  end

  defp priv_if_templates_exist(dir) do
    priv = Path.join(dir, "priv")
    if templates_present?(priv), do: priv
  end

  defp templates_present?(priv), do: File.dir?(Path.join(priv, "templates/mob.new"))

  defp raise_no_templates do
    Mix.raise("""
    mob.adopt could not find mob_new's native templates.

    The Android/iOS native trees are rendered from mob_new's bundled
    priv/templates/mob.new/. Install the mob_new archive so it is on
    Mix's code path:

        mix archive.install hex mob_new

    (For local mob_new development instead, set MOB_NEW_DIR to your
    checkout, or clone mob_new to ~/code/mob_new.)
    """)
  end

  # Reverse-DNS prefix for the generated bundle id. Honors MOB_BUNDLE_PREFIX
  # (typical value: "com.acme" or "net.you"); defaults to "com.example", the
  # universal "must change before shipping" placeholder. Never defaults to
  # "com.mob" — Apple and Google enforce reverse-DNS ownership at App Store
  # / Play Store submission.
  @spec bundle_prefix() :: String.t()
  def bundle_prefix do
    case System.get_env("MOB_BUNDLE_PREFIX") do
      nil -> "com.example"
      "" -> "com.example"
      raw -> String.trim(raw)
    end
  end

  @doc """
  Returns the EEx template assigns map for `app_name`.

  Options:
  - `:local` — when `true`, generates `path:` deps pointing to local mob/mob_dev
    repos instead of hex version constraints. Paths are resolved from the
    `MOB_DIR` and `MOB_DEV_DIR` environment variables, falling back to
    `../mob` and `../mob_dev` relative to the generated project location.
  """
  @spec assigns(String.t(), keyword()) :: map()
  def assigns(app_name, opts \\ []) do
    module_name = Macro.camelize(app_name)
    display_name = module_name
    bundle_prefix = bundle_prefix()
    bundle_id = "#{bundle_prefix}.#{app_name}"
    java_package = bundle_id
    lib_name = String.replace(app_name, "_", "")
    java_path = String.replace(bundle_id, ".", "/")

    # JNI method name segment: dots→underscores, then underscores→_1
    # e.g. "com.mob.test_app" → "com_mob_test_1app"
    jni_package =
      java_package
      |> String.replace("_", "_1")
      |> String.replace(".", "_")

    {mob_dep, mob_dev_dep, mob_exs_mob_dir, mob_exs_elixir_lib} = resolve_deps(opts)

    %{
      app_name: app_name,
      module_name: module_name,
      display_name: display_name,
      bundle_id: bundle_id,
      java_package: java_package,
      jni_package: jni_package,
      lib_name: lib_name,
      java_path: java_path,
      mob_dep: mob_dep,
      mob_dev_dep: mob_dev_dep,
      mob_exs_mob_dir: mob_exs_mob_dir,
      mob_exs_elixir_lib: mob_exs_elixir_lib,
      ndk_version: NdkVersion.recommended(),
      python: Keyword.get(opts, :python, false),
      blank: Keyword.get(opts, :blank, false)
    }
  end

  @doc """
  Patches a generated project to enable Pythonx (embedded CPython,
  iOS + Android).

  Two patches:
    * `mix.exs` — adds `{:pythonx, "~> 0.4"}` to deps.
    * `lib/<app>/python_paths.ex` — pure detection module that reads
      `:code.root_dir/0` for iOS and `MOB_PYTHON_HOME` / `MOB_PYTHON_DL`
      env vars (set by Android's `MainActivity`) for Android.

  Mirrors `mix mob.enable pythonx`. Idempotent — safe to run twice.
  """
  @spec apply_python_patches(String.t(), String.t()) :: :ok
  def apply_python_patches(project_dir, app_name) do
    add_pythonx_dep(project_dir)
    write_python_paths_module(project_dir, app_name)
    :ok
  end

  defp add_pythonx_dep(project_dir) do
    path = Path.join(project_dir, "mix.exs")

    case File.read(path) do
      {:ok, content} ->
        cond do
          String.contains?(content, ":pythonx") ->
            :ok

          Regex.match?(Regex.compile!(~S{defp\s+deps\s+do\s*\[}), content) ->
            patched =
              Regex.replace(
                Regex.compile!(~S{(defp\s+deps\s+do\s*\[)}),
                content,
                ~s(\\1\n      {:pythonx, "~> 0.4"},),
                global: false
              )

            File.write!(path, patched)

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp write_python_paths_module(project_dir, app_name) do
    module_name = Macro.camelize(app_name)
    dir = Path.join([project_dir, "lib", app_name])
    File.mkdir_p!(dir)
    path = Path.join(dir, "python_paths.ex")

    unless File.exists?(path) do
      File.write!(path, python_paths_module_source(module_name))
    end
  end

  defp python_paths_module_source(module_name) do
    """
    defmodule #{module_name}.PythonPaths do
      @moduledoc \"\"\"
      Detects bundled CPython at runtime and reports the paths needed
      for `Pythonx.init/4` (dl_path, home_path, stdlib_path).

      Pure detection logic — see your app's `App` module for how the
      result is fed into `Pythonx.init/4` at boot.

      ## Per-platform layout

        * **iOS**: `mix mob.deploy --native` bundles `Python.framework`,
          stdlib, and lib-dynload at `<App>.app/otp/python/`. Detection
          reads `:code.root_dir/0` and inspects that subtree.

        * **Android**: `mix mob.deploy --native` bundles libpython.so
          into the APK's `jniLibs/<abi>/` (auto-extracted by the
          installer to `applicationInfo.nativeLibraryDir`) and stdlib
          + lib-dynload into `assets/python/` (extracted to
          `filesDir/python/` by `MainActivity.onCreate` on first
          launch). MainActivity exports the resolved paths via
          `MOB_PYTHON_DL` and `MOB_PYTHON_HOME` env vars before
          starting the BEAM.

      ## Returns

        * `:desktop` — no platform bundle found; the caller should
          drive `Pythonx.Uv.fetch + init` manually.
        * `{:ios, paths}` / `{:android, paths}` — bundle present; pass
          into `Pythonx.init/4`.
        * `{:partial, missing}` — bundle is incomplete; surface to
          the user.
      \"\"\"

      @type python_paths :: %{
              dl_path: String.t(),
              home_path: String.t(),
              stdlib_path: String.t()
            }

      @type detection ::
              :desktop
              | {:ios, python_paths()}
              | {:android, python_paths()}
              | {:partial, [atom()]}

      @python_version "python3.13"

      @spec detect(String.t()) :: detection()
      def detect(otp_root) when is_binary(otp_root) do
        cond do
          android_paths() != nil ->
            paths = android_paths()

            case missing(paths) do
              [] -> {:android, paths}
              missing -> {:partial, missing}
            end

          File.dir?(Path.join(otp_root, "python")) ->
            paths = build_ios_paths(otp_root)

            case missing(paths) do
              [] -> {:ios, paths}
              missing -> {:partial, missing}
            end

          true ->
            :desktop
        end
      end

      @spec build_ios_paths(String.t()) :: python_paths()
      def build_ios_paths(otp_root) when is_binary(otp_root) do
        python_dir = Path.join(otp_root, "python")

        %{
          dl_path: Path.join([python_dir, "Python.framework", "Python"]),
          home_path: python_dir,
          stdlib_path: Path.join([python_dir, "lib", @python_version])
        }
      end

      @spec build_android_paths() :: python_paths() | nil
      def build_android_paths do
        case {System.get_env("MOB_PYTHON_DL"), System.get_env("MOB_PYTHON_HOME")} do
          {dl, home} when is_binary(dl) and is_binary(home) ->
            %{
              dl_path: dl,
              home_path: home,
              stdlib_path: Path.join([home, "lib", @python_version])
            }

          _ ->
            nil
        end
      end

      defp android_paths, do: build_android_paths()

      @spec missing(python_paths()) :: [atom()]
      def missing(%{dl_path: dl, home_path: home, stdlib_path: stdlib}) do
        [
          {:dl_path, File.exists?(dl)},
          {:home_path, File.dir?(home)},
          {:stdlib_path, File.dir?(stdlib)}
        ]
        |> Enum.reject(fn {_, present?} -> present? end)
        |> Enum.map(&elem(&1, 0))
      end
    end
    """
  end

  @doc false
  @spec extract_secret_key_base(String.t()) :: String.t() | nil
  def extract_secret_key_base(project_dir) do
    dev_exs = Path.join([project_dir, "config", "dev.exs"])

    if File.exists?(dev_exs) do
      content = File.read!(dev_exs)

      case Regex.run(Regex.compile!("secret_key_base:\\s*\"([^\"]{40,})\""), content) do
        [_, key] -> key
        _ -> nil
      end
    end
  end

  @doc false
  @spec generate_secret_key_base() :: String.t()
  def generate_secret_key_base do
    :crypto.strong_rand_bytes(48) |> Base.encode64(padding: false)
  end

  @doc false
  @spec generate_signing_salt() :: String.t()
  def generate_signing_salt do
    :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
  end

  # ── Dep resolution ────────────────────────────────────────────────────────────

  @doc false
  @spec resolve_deps(keyword()) :: {String.t(), String.t(), String.t(), String.t()}
  def resolve_deps(opts) do
    if opts[:local] do
      mob_dir = resolve_local_path("MOB_DIR", "mob")
      mob_dev_dir = resolve_local_path("MOB_DEV_DIR", "mob_dev")
      elixir_lib = :code.lib_dir(:elixir) |> to_string() |> Path.dirname() |> Path.expand()

      # override: true so the local checkout satisfies the `mob ~> 0.7`
      # requirement that the Hex showcase plugins (mob_camera, mob_themes, …)
      # declare — Mix won't otherwise use a path dep to resolve a Hex
      # sub-dependency requirement.
      mob_dep = ~s({:mob,     path: "#{mob_dir}", override: true})
      mob_dev_dep = ~s({:mob_dev, path: "#{mob_dev_dir}", only: :dev, runtime: false})
      mob_exs_mob_dir = inspect(mob_dir)
      mob_exs_elixir_lib = inspect(elixir_lib)

      {mob_dep, mob_dev_dep, mob_exs_mob_dir, mob_exs_elixir_lib}
    else
      mob_dep = ~s({:mob,     "~> 0.7"})
      mob_dev_dep = ~s({:mob_dev, "~> 0.6", only: :dev, runtime: false})
      mob_exs_mob_dir = "Path.join(File.cwd!(), \"deps/mob\")"

      # Default to the running Elixir's actual lib dir — `:code.lib_dir(:elixir)`
      # returns ".../lib/elixir", so `Path.dirname/1` yields the parent that
      # holds elixir/, logger/, eex/, etc. that build.sh's stdlib copy needs.
      mob_exs_elixir_lib =
        "System.get_env(\"MOB_ELIXIR_LIB\", :code.lib_dir(:elixir) |> to_string() |> Path.dirname())"

      {mob_dep, mob_dev_dep, mob_exs_mob_dir, mob_exs_elixir_lib}
    end
  end

  @doc false
  @spec resolve_local_path(String.t(), String.t()) :: String.t()
  def resolve_local_path(env_var, sibling_name) do
    cond do
      path = System.get_env(env_var) ->
        Path.expand(path)

      File.dir?(sibling = Path.expand("./#{sibling_name}")) ->
        sibling

      File.dir?(sibling = Path.expand("../#{sibling_name}")) ->
        sibling

      true ->
        Mix.raise("""
        Could not find local #{sibling_name} directory.
        Set #{env_var} env var or ensure #{sibling_name} exists alongside your project:
          export #{env_var}=/path/to/#{sibling_name}
        """)
    end
  end

  @doc false
  # Replace `app_name` placeholder in directory segments and strip .eex extension.
  @spec expand_path(String.t(), map()) :: String.t()
  def expand_path(rel, assigns) do
    rel
    # Dotfile templates can't ship in the archive (mix archive.build's
    # wildcard drops dotfiles), so they live under non-dot names and are
    # renamed here — the escape hatch the @dotfiles comment documents.
    |> String.replace("dot_credo.exs", ".credo.exs")
    |> String.replace("app_name", assigns.app_name)
    |> String.replace("java/", "java/#{assigns.java_path}/")
    |> strip_eex()
  end

  defp strip_eex(path) do
    if String.ends_with?(path, ".eex"),
      do: String.slice(path, 0..-5//1),
      else: path
  end
end
