defmodule MobDev.Plugin.Manifest do
  @moduledoc """
  Reads, validates, and classifies a plugin's `priv/mob_plugin.exs` manifest.

  The manifest is data, not code (see `MOB_PLUGINS.md`): a plain Elixir map
  describing what a plugin contributes. This module is the single place that
  turns that map into a validated, classified description — tier, hot-push
  status, activation — that `mix mob.plugins` reports and the compile-time
  merge will later consume.

  A tier-0 plugin has no manifest at all; `load/1` returns `{:ok, nil}` for
  that case, and `tier(nil)` is `0`.
  """

  @manifest_path "priv/mob_plugin.exs"

  # Spec versions this mob_dev understands. Bumped when MOB_PLUGINS.md makes a
  # breaking schema change; old plugins keep validating against old specs.
  @supported_spec_versions [1, 2]

  @native_sections [
    :nifs,
    :nifs_generator,
    :android,
    :ios,
    :permissions,
    :ui_components,
    :ui_components_generator
  ]
  @screen_sections [:screens, :screens_generator, :migrations, :assets]
  @subapp_sections [:lifecycle, :settings, :notifications]
  @visual_sections [:ui_components, :ui_components_generator]
  @tier1_sections [:nifs, :nifs_generator, :android, :ios, :permissions]
  # Sections whose Elixir half can still hot-push even when the plugin has
  # native code (the partial case).
  @pushable_sections [:screens, :screens_generator, :lifecycle, :migrations]

  @doc """
  Loads the manifest for a plugin checked out at `plugin_dir`.

  Returns `{:ok, nil}` when there is no `priv/mob_plugin.exs` (a tier-0
  plugin), `{:ok, map}` when one is present and evaluates to a map, or
  `{:error, reason}` when the file is unreadable or doesn't yield a map.
  Does not validate field contents — call `validate/1` for that.
  """
  @spec load(Path.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def load(plugin_dir) do
    path = Path.join(plugin_dir, @manifest_path)

    if File.exists?(path) do
      eval(path)
    else
      {:ok, nil}
    end
  end

  defp eval(path) do
    case Code.eval_file(path) do
      {map, _bindings} when is_map(map) ->
        {:ok, map}

      {other, _bindings} ->
        {:error, "#{path} must evaluate to a map, got: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "#{path} failed to evaluate: #{Exception.message(e)}"}
  end

  @doc """
  Validates a manifest map against the spec's required top-level fields.

  Returns `{:ok, manifest}` or `{:error, reasons}` with a list of every
  problem found (validation never stops at the first error). `nil` (no
  manifest) is valid — a tier-0 plugin has nothing to validate.
  """
  @spec validate(map() | nil) :: {:ok, map() | nil} | {:error, [String.t()]}
  def validate(nil), do: {:ok, nil}

  def validate(manifest) when is_map(manifest) do
    errors =
      []
      |> check_name(manifest)
      |> check_mob_version(manifest)
      |> check_spec_version(manifest)
      |> check_permissions(manifest)
      |> check_android_manifest_snippets(manifest)
      |> check_android_res_files(manifest)
      |> check_nifs(manifest)
      |> check_screens(manifest)
      |> check_screens_generator(manifest)
      |> check_migrations(manifest)
      |> check_assets(manifest)
      |> check_lifecycle(manifest)
      |> check_settings(manifest)
      |> check_notifications(manifest)
      |> check_ui_components(manifest)
      |> check_host_requirements(manifest)

    case errors do
      [] -> {:ok, manifest}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate(other),
    do:
      {:error, ["manifest must be a map (the priv/mob_plugin.exs data), got: #{inspect(other)}"]}

  defp check_name(errors, %{name: name}) when is_atom(name) and not is_nil(name), do: errors
  defp check_name(errors, _), do: [":name is required and must be an atom" | errors]

  defp check_mob_version(errors, %{mob_version: req}) when is_binary(req) do
    case Version.parse_requirement(req) do
      {:ok, _} -> errors
      :error -> [":mob_version #{inspect(req)} is not a valid version requirement" | errors]
    end
  end

  defp check_mob_version(errors, _),
    do: [
      ":mob_version is required and must be a version requirement string (e.g. \"~> 0.7\")"
      | errors
    ]

  defp check_spec_version(errors, %{plugin_spec_version: v}) when is_integer(v) do
    if v in @supported_spec_versions do
      errors
    else
      [
        "plugin_spec_version #{v} is not supported (this mob_dev knows #{inspect(@supported_spec_versions)})"
        | errors
      ]
    end
  end

  defp check_spec_version(errors, _),
    do: [":plugin_spec_version is required and must be an integer" | errors]

  # `:permissions` is optional. When present it must be a list of maps, each with
  # a `:capability` atom (the value `Mob.Permissions.request/2` accepts) and an
  # optional `:ios` map carrying a `:handler` string (the cdecl symbol the
  # plugin self-registers). Android needs nothing here — its provider is
  # auto-discovered by interface at bootstrap (see the permission-registry ADR).
  defp check_permissions(errors, %{permissions: perms}) when is_list(perms) do
    perms
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_permission_entry(acc, entry, i) end)
  end

  defp check_permissions(errors, %{permissions: other}),
    do: ["permissions must be a list, got: #{inspect(other)}" | errors]

  defp check_permissions(errors, _), do: errors

  defp check_permission_entry(errors, %{capability: cap} = entry, _i) when is_atom(cap) do
    case entry[:ios] do
      nil ->
        errors

      %{handler: h} when is_binary(h) ->
        errors

      %{} ->
        ["permissions entry #{inspect(cap)}: ios must declare a :handler string" | errors]

      other ->
        ["permissions entry #{inspect(cap)}: :ios must be a map, got: #{inspect(other)}" | errors]
    end
  end

  defp check_permission_entry(errors, %{} = entry, i),
    do: ["permissions entry ##{i} requires a :capability atom, got: #{inspect(entry)}" | errors]

  defp check_permission_entry(errors, other, i),
    do: ["permissions entry ##{i} must be a map, got: #{inspect(other)}" | errors]

  # `android.manifest_application_snippets` (optional) is a list of XML strings
  # spliced into the app manifest's `<application>` block (a `<service>`,
  # `<receiver>`, …). Each must be a non-empty string; content is the plugin
  # author's responsibility (the native build inserts verbatim).
  defp check_android_manifest_snippets(errors, manifest) do
    case get_in(manifest, [:android, :manifest_application_snippets]) do
      nil ->
        errors

      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: errors,
          else: [
            "android.manifest_application_snippets must be a list of non-empty XML strings"
            | errors
          ]

      other ->
        [
          "android.manifest_application_snippets must be a list of XML strings, got: #{inspect(other)}"
          | errors
        ]
    end
  end

  # `android.res_files` (optional) is a list of plugin-relative paths copied into
  # the app's `res/` tree. Each must be a non-empty string containing a `res`
  # path segment (the build derives the `res/<type>/<file>` destination from it)
  # and must NOT contain a `..` segment — otherwise the derived destination could
  # escape the app `res/` dir and `File.cp!` would write plugin bytes anywhere on
  # the build host (path traversal). The native build enforces containment again
  # at copy time as defense in depth.
  defp check_android_res_files(errors, manifest) do
    case get_in(manifest, [:android, :res_files]) do
      nil ->
        errors

      list when is_list(list) ->
        cond do
          not Enum.all?(list, &(is_binary(&1) and &1 != "")) ->
            ["android.res_files must be a list of non-empty path strings" | errors]

          Enum.any?(list, &(".." in Path.split(&1))) ->
            [
              "android.res_files paths must not contain a \"..\" segment " <>
                "(path traversal — the copy destination must stay under the app res/ dir)"
              | errors
            ]

          not Enum.all?(list, &("res" in Path.split(&1))) ->
            [
              "android.res_files paths must contain a \"res\" segment (e.g. " <>
                "priv/native/android/res/xml/foo.xml) so the build can place them"
              | errors
            ]

          true ->
            errors
        end

      other ->
        ["android.res_files must be a list of path strings, got: #{inspect(other)}" | errors]
    end
  end

  # `:nifs` is optional. When present, each entry's optional `:platform` (used by
  # cross-platform plugins that ship a separate iOS + Android source for the same
  # module) must be `:ios` or `:android`. For single-source C/ObjC/zig NIFs the
  # rest of the fields are validated at build / link time. `lang: :cpp_archive`
  # entries (a cross-compiled C++ static lib, e.g. an Nx backend) declare more —
  # `:sources` + `:nm_symbol` — so those are checked structurally here.
  defp check_nifs(errors, %{nifs: nifs}) when is_list(nifs) do
    nifs
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {nif, i}, acc -> check_nif_entry(acc, nif, i) end)
  end

  defp check_nifs(errors, %{nifs: other}),
    do: ["nifs must be a list, got: #{inspect(other)}" | errors]

  defp check_nifs(errors, _), do: errors

  defp check_nif_entry(errors, %{} = nif, i) do
    errors
    |> check_nif_platform(nif, i)
    |> check_nif_cpp_archive(nif, i)
  end

  defp check_nif_entry(errors, other, i),
    do: ["nifs entry ##{i} must be a map, got: #{inspect(other)}" | errors]

  defp check_nif_platform(errors, %{platform: p}, i) when p not in [:ios, :android],
    do: ["nifs entry ##{i}: :platform must be :ios or :android, got: #{inspect(p)}" | errors]

  defp check_nif_platform(errors, _nif, _i), do: errors

  # A `lang: :cpp_archive` entry is cross-compiled into a static `.a` and
  # static-linked into the app (see `MobDev.Plugin.CppArchive`). It needs more
  # than a single-source NIF: `:sources` (≥1 relative C++ paths) and
  # `:nm_symbol` (the ERL_NIF_INIT symbol the driver table references). The
  # toolchain-shaped fields (`:includes`, `:cxxflags*`) are optional and
  # resolved at build time.
  defp check_nif_cpp_archive(errors, %{lang: :cpp_archive} = nif, i) do
    errors
    |> check_archive_module(nif, i)
    |> check_archive_sources(nif, i)
    |> check_archive_symbol(nif, i)
    |> check_archive_symbol_matches_module(nif, i)
  end

  defp check_nif_cpp_archive(errors, _nif, _i), do: errors

  # The driver table builds the archive's libname and init symbol from
  # `:module` (`lib<module>.a`, `<module>_nif_init`), and `Merge.static_archives`
  # silently drops any entry whose `:module` isn't an atom. A missing/non-atom
  # `:module` therefore fails *open*: validation passes but the build either
  # drops the NIF (non-atom) or names it `libnil.a` (nil). Require a lowercase
  # NIF `:module` atom up front — mirrors the `:screens` `:module` check, but
  # also rejects aliased modules (`Foo.Bar`), which would yield a wrong-named
  # `libElixir.Foo.Bar.a`. NIF modules are bare lowercase atoms (`:nx_eigen_nif`).
  defp check_archive_module(errors, %{module: m}, _i)
       when is_atom(m) and not is_nil(m) and m not in [true, false] do
    if String.starts_with?(Atom.to_string(m), "Elixir."),
      do: [
        "nifs cpp_archive :module must be a lowercase NIF atom (e.g. :nx_eigen_nif), " <>
          "got an aliased module #{inspect(m)}"
        | errors
      ],
      else: errors
  end

  defp check_archive_module(errors, _nif, i),
    do: ["nifs entry ##{i}: lang: :cpp_archive requires a lowercase :module atom" | errors]

  defp check_archive_sources(errors, %{sources: s}, _i)
       when is_list(s) and s != [] do
    if Enum.all?(s, &archive_path_entry?/1),
      do: errors,
      else: [
        "nifs cpp_archive sources must be path strings or {:dep, name, subpath} tokens" | errors
      ]
  end

  defp check_archive_sources(errors, _nif, i),
    do: ["nifs entry ##{i}: lang: :cpp_archive requires a non-empty :sources list" | errors]

  # A cpp_archive :sources / :includes entry is either a plugin-relative path
  # string or a `{:dep, name, subpath}` token referencing a dep's tree (e.g.
  # NxEigen's NIF lives in the nx_eigen dep). Merge resolves both.
  defp archive_path_entry?(s) when is_binary(s), do: true
  defp archive_path_entry?({:dep, name, sub}) when is_atom(name) and is_binary(sub), do: true
  defp archive_path_entry?(_), do: false

  defp check_archive_symbol(errors, %{nm_symbol: sym}, _i) when is_binary(sym) and sym != "",
    do: errors

  defp check_archive_symbol(errors, _nif, i),
    do: ["nifs entry ##{i}: lang: :cpp_archive requires an :nm_symbol string" | errors]

  # The static-NIF driver table derives a cpp_archive's init function as
  # `<module>_nif_init` and resolves load_nif by the module name, so the
  # archive's actual `:nm_symbol` MUST equal `<module>_nif_init`. Mismatch is a
  # link-time "cannot locate symbol …_nif_init" that only shows up on-device
  # after a full native build (it bit the first real consumer: module
  # :nx_eigen_nif vs symbol nx_eigen_nif_init). Catch it at config time.
  defp check_archive_symbol_matches_module(errors, %{module: m, nm_symbol: sym}, i)
       when is_atom(m) and is_binary(sym) do
    expected = "#{m}_nif_init"

    if sym == expected,
      do: errors,
      else: [
        "nifs entry ##{i}: cpp_archive :nm_symbol #{inspect(sym)} must be " <>
          "#{inspect(expected)} (the driver table derives the init symbol as " <>
          "<module>_nif_init; set the module so they agree, or fix " <>
          "-DSTATIC_ERLANG_NIF_LIBNAME)"
        | errors
      ]
  end

  defp check_archive_symbol_matches_module(errors, _nif, _i), do: errors

  # ── Tier 3: screens / migrations / assets ─────────────────────────────────

  # `:screens` (static, tier 3) is a list of `%{module: Mod, default_route: "/p"}`.
  # Mutually exclusive with `:screens_generator` (enforced in check_screens_generator).
  defp check_screens(errors, %{screens: screens}) when is_list(screens) do
    screens
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_screen_entry(acc, entry, i) end)
  end

  defp check_screens(errors, %{screens: other}),
    do: ["screens must be a list, got: #{inspect(other)}" | errors]

  defp check_screens(errors, _), do: errors

  defp check_screen_entry(errors, %{module: m, default_route: r}, _i)
       when is_atom(m) and not is_nil(m) and is_binary(r),
       do: errors

  defp check_screen_entry(errors, %{} = entry, i),
    do: [
      "screens entry ##{i} requires a :module atom and a :default_route string, got: #{inspect(entry)}"
      | errors
    ]

  defp check_screen_entry(errors, other, i),
    do: ["screens entry ##{i} must be a map, got: #{inspect(other)}" | errors]

  # `:screens_generator` (spec-v2) is an `{Module, :function, args}` MFA run at
  # build time. Requires plugin_spec_version: 2 and is mutually exclusive with
  # static `:screens`.
  defp check_screens_generator(errors, %{screens_generator: gen} = m) do
    errors
    |> check_mfa(gen, :screens_generator)
    |> require_spec_v2(m, :screens_generator)
    |> reject_static_and_generated(m)
  end

  defp check_screens_generator(errors, _), do: errors

  defp reject_static_and_generated(errors, m) do
    if Map.has_key?(m, :screens) do
      [":screens and :screens_generator are mutually exclusive — declare one, not both" | errors]
    else
      errors
    end
  end

  defp require_spec_v2(errors, %{plugin_spec_version: v}, _section) when v >= 2, do: errors

  defp require_spec_v2(errors, _m, section),
    do: ["#{inspect(section)} requires plugin_spec_version: 2" | errors]

  # `:migrations` (tier 3) is `%{repo_namespace: "prefix_", migrations_dir: "path"}`.
  # The namespace prefixes migration/table names so vendors don't collide.
  defp check_migrations(errors, %{migrations: %{repo_namespace: ns, migrations_dir: dir}})
       when is_binary(ns) and is_binary(dir),
       do: errors

  defp check_migrations(errors, %{migrations: other}),
    do: [
      "migrations must be a map with :repo_namespace and :migrations_dir strings, got: #{inspect(other)}"
      | errors
    ]

  defp check_migrations(errors, _), do: errors

  # `:assets` (tier 3) is `%{fonts: [path], images: [path]}` (both keys optional).
  defp check_assets(errors, %{assets: %{} = assets}) do
    errors
    |> check_asset_paths(assets, :fonts)
    |> check_asset_paths(assets, :images)
  end

  defp check_assets(errors, %{assets: other}),
    do: [
      "assets must be a map with :fonts and/or :images path lists, got: #{inspect(other)}"
      | errors
    ]

  defp check_assets(errors, _), do: errors

  defp check_asset_paths(errors, assets, key) do
    case Map.get(assets, key) do
      nil ->
        errors

      paths when is_list(paths) ->
        if Enum.all?(paths, &is_binary/1), do: errors, else: bad_assets(errors, key)

      _ ->
        bad_assets(errors, key)
    end
  end

  defp bad_assets(errors, key),
    do: ["assets.#{key} must be a list of path strings" | errors]

  # ── Tier 4: lifecycle / settings / notifications ──────────────────────────

  # `:lifecycle` (tier 4) wires the plugin into the host's OTP lifecycle:
  # `on_start`/`on_resume`/`on_background` MFAs (optional) and `supervised`
  # child specs (optional). The host calls them; this only checks shape.
  defp check_lifecycle(errors, %{lifecycle: %{} = lc}) do
    errors
    |> check_optional_mfa(lc, :on_start)
    |> check_optional_mfa(lc, :on_resume)
    |> check_optional_mfa(lc, :on_background)
    |> check_supervised(lc)
  end

  defp check_lifecycle(errors, %{lifecycle: other}),
    do: ["lifecycle must be a map, got: #{inspect(other)}" | errors]

  defp check_lifecycle(errors, _), do: errors

  defp check_optional_mfa(errors, map, key) do
    case Map.get(map, key) do
      nil -> errors
      mfa -> check_mfa(errors, mfa, :"lifecycle.#{key}")
    end
  end

  defp check_supervised(errors, %{supervised: children}) when is_list(children), do: errors

  defp check_supervised(errors, %{supervised: other}),
    do: ["lifecycle.supervised must be a list of child specs, got: #{inspect(other)}" | errors]

  defp check_supervised(errors, _), do: errors

  # `:settings` (tier 4) is `%{schema: [%{key, type, default}], editor_screen: Mod}`.
  # Persisted per-plugin via Mob.State; `type` drives runtime validation.
  @setting_types [:boolean, :string, :integer]

  defp check_settings(errors, %{settings: %{} = settings}) do
    errors
    |> check_settings_schema(settings)
    |> check_editor_screen(settings)
  end

  defp check_settings(errors, %{settings: other}),
    do: ["settings must be a map with a :schema list, got: #{inspect(other)}" | errors]

  defp check_settings(errors, _), do: errors

  defp check_settings_schema(errors, %{schema: schema}) when is_list(schema) do
    schema
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_setting_entry(acc, entry, i) end)
  end

  defp check_settings_schema(errors, _),
    do: ["settings.schema is required and must be a list of %{key, type, default} maps" | errors]

  defp check_setting_entry(errors, %{key: k, type: t} = entry, i)
       when is_atom(k) and is_atom(t) do
    cond do
      t not in @setting_types ->
        [
          "settings entry ##{i}: :type must be one of #{inspect(@setting_types)}, got: #{inspect(t)}"
          | errors
        ]

      not Map.has_key?(entry, :default) ->
        ["settings entry ##{i} (#{inspect(k)}) requires a :default value" | errors]

      true ->
        errors
    end
  end

  defp check_setting_entry(errors, other, i),
    do: ["settings entry ##{i} requires :key and :type atoms, got: #{inspect(other)}" | errors]

  defp check_editor_screen(errors, %{editor_screen: m}) when is_atom(m) and not is_nil(m),
    do: errors

  defp check_editor_screen(errors, %{editor_screen: other}),
    do: [
      "settings.editor_screen must be a Mob.Screen module atom, got: #{inspect(other)}" | errors
    ]

  defp check_editor_screen(errors, _), do: errors

  # `:notifications` (tier 4) is `%{handlers: [%{match, handler}]}`. `match` is a
  # map (prefix-matched against the payload) or a 1-arity fun; `handler` is an MFA.
  defp check_notifications(errors, %{notifications: %{handlers: handlers}})
       when is_list(handlers) do
    handlers
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_notification_handler(acc, entry, i) end)
  end

  defp check_notifications(errors, %{notifications: other}),
    do: ["notifications must be a map with a :handlers list, got: #{inspect(other)}" | errors]

  defp check_notifications(errors, _), do: errors

  # `:ui_components` entries are either NATIVE-backed (ios/android view
  # registrations, tier 2's original form) or the pure-Elixir `expand:` form
  # ({Module, :function} composite expander — MOB_PLUGINS.md, now honored).
  # An entry must pick one; both/neither is an error.
  defp check_ui_components(errors, %{ui_components: comps}) when is_list(comps) do
    comps
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_ui_component(acc, entry, i) end)
  end

  defp check_ui_components(errors, %{ui_components: other}),
    do: ["ui_components must be a list, got: #{inspect(other)}" | errors]

  defp check_ui_components(errors, _), do: errors

  defp check_ui_component(errors, %{tag: t, atom: a} = entry, i)
       when is_binary(t) and is_atom(a) do
    native? = Map.has_key?(entry, :ios) or Map.has_key?(entry, :android)

    case {Map.get(entry, :expand), native?} do
      {nil, true} ->
        errors

      {{m, f}, false} when is_atom(m) and is_atom(f) ->
        errors

      {nil, false} ->
        [
          "ui_components entry ##{i} needs native backing (:ios/:android) or an " <>
            "expand: {Module, :function} composite expander"
          | errors
        ]

      {_, true} ->
        [
          "ui_components entry ##{i} mixes expand: with native backing — pick one " <>
            "(a composite that needs a native part should emit Mob.UI.native_view)"
          | errors
        ]

      {bad, false} ->
        [
          "ui_components entry ##{i} expand: must be {Module, :function}, got: #{inspect(bad)}"
          | errors
        ]
    end
  end

  defp check_ui_component(errors, entry, i),
    do: [
      "ui_components entry ##{i} requires a :tag string and an :atom, got: #{inspect(entry)}"
      | errors
    ]

  # `:host_requirements` is optional: human-readable host-app obligations the
  # plugin system can't automate (e.g. AndroidManifest fragments). The native
  # build prints them as warnings; here we only enforce the shape.
  defp check_host_requirements(errors, %{host_requirements: reqs}) when is_list(reqs) do
    Enum.reduce(reqs, errors, fn
      req, acc when is_binary(req) and req != "" ->
        acc

      req, acc ->
        ["host_requirements entries must be non-empty strings, got: #{inspect(req)}" | acc]
    end)
  end

  defp check_host_requirements(errors, %{host_requirements: other}),
    do: ["host_requirements must be a list of strings, got: #{inspect(other)}" | errors]

  defp check_host_requirements(errors, _), do: errors

  defp check_notification_handler(errors, %{match: match, handler: handler}, i) do
    errors
    |> check_match(match, i)
    |> check_handler_ref(handler, i)
  end

  defp check_notification_handler(errors, other, i),
    do: [
      "notifications handler ##{i} requires :match and :handler, got: #{inspect(other)}" | errors
    ]

  # A notification handler is invoked WITH the payload, so it's a
  # `{Module, :function, arity}` reference (arity is an integer), not an
  # args-MFA. The dispatcher calls `apply(m, f, [payload])`.
  defp check_handler_ref(errors, {m, f, arity}, _i)
       when is_atom(m) and is_atom(f) and is_integer(arity),
       do: errors

  defp check_handler_ref(errors, other, i),
    do: [
      "notifications handler ##{i}: :handler must be a {Module, :function, arity} tuple, got: #{inspect(other)}"
      | errors
    ]

  # `:match` is a map (prefix-matched against the payload) or a
  # `{Module, :function, arity}` predicate reference. Anonymous functions are
  # NOT allowed — the merged handler set is serialized into the host's runtime
  # plugin manifest (a terms file), and closures don't survive that.
  defp check_match(errors, match, _i) when is_map(match), do: errors

  defp check_match(errors, {m, f, arity}, _i)
       when is_atom(m) and is_atom(f) and is_integer(arity),
       do: errors

  defp check_match(errors, other, i),
    do: [
      "notifications handler ##{i}: :match must be a map or a {Module, :function, arity} predicate, got: #{inspect(other)}"
      | errors
    ]

  # Shared: validate an `{Module, :function, args}` MFA tuple.
  defp check_mfa(errors, {m, f, a}, _label) when is_atom(m) and is_atom(f) and is_list(a),
    do: errors

  defp check_mfa(errors, other, label),
    do: [
      "#{inspect(label)} must be an {Module, :function, args} tuple, got: #{inspect(other)}"
      | errors
    ]

  @doc """
  Classifies the plugin tier (0–4) from which capability sections are present.

  Highest matching section wins. `nil` (no manifest) is tier 0. A manifest
  with required fields but no capability sections is the tier-1 floor (the
  "minimum viable manifest").
  """
  @spec tier(map() | nil) :: 0..4
  def tier(nil), do: 0

  def tier(m) when is_map(m) do
    cond do
      has_any?(m, @subapp_sections) -> 4
      has_any?(m, @screen_sections) -> 3
      has_any?(m, @visual_sections) -> 2
      has_any?(m, @tier1_sections) -> 1
      true -> 1
    end
  end

  @doc """
  Whether the plugin's contributions can be hot-pushed without a native rebuild.

  Computed from populated sections, not from tier: `true` for pure-Elixir
  plugins, `false` for native-only ones (NIFs / components), and `:partial`
  when a plugin mixes native code with hot-pushable Elixir (screens, lifecycle).
  """
  @spec hot_pushable(map() | nil) :: true | false | :partial
  def hot_pushable(nil), do: true

  def hot_pushable(m) when is_map(m) do
    cond do
      not has_any_native?(m) -> true
      has_any?(m, @pushable_sections) -> :partial
      true -> false
    end
  end

  defp has_any?(map, keys), do: Enum.any?(keys, &Map.has_key?(map, &1))

  # :ui_components counts as native ONLY when an entry actually carries native
  # backing (:ios/:android). The expand: form (pure-Elixir composites) is
  # hot-pushable like any screen module.
  defp has_any_native?(m) do
    Enum.any?(@native_sections, fn
      :ui_components ->
        m |> Map.get(:ui_components, []) |> Enum.any?(&native_component?/1)

      key ->
        Map.has_key?(m, key)
    end)
  end

  defp native_component?(c) when is_map(c),
    do: Map.has_key?(c, :ios) or Map.has_key?(c, :android)

  defp native_component?(_), do: false
end
