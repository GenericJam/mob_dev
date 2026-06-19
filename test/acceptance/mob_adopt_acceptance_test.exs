defmodule MobAdoptAcceptanceTest do
  @moduledoc """
  End-to-end + Phoenix drift check.

  Generates a real `mix phx.new` project, verifies Phoenix's output
  still matches the shape `mob.adopt` patches, adds `:igniter` and a
  `path:` dep on this mob_dev checkout to the project's deps, runs
  `mix mob.adopt --yes`, asserts the resulting tree, then runs
  `mix compile` to catch downstream drift.

  Tagged `@tag :acceptance` and excluded from the default test suite. Run with:

      mix test --only acceptance

  ## Requirements (this is a real shell-out E2E — it needs the toolchain)

  - `phx_new` archive on the system (`mix archive.install hex phx_new`).
    Skipped if `mix help phx.new` exits non-zero.
  - Network access for `mix deps.get` (fetches Phoenix + this project's
    transitive deps), unless everything is already cached.
  - `MOB_NEW_DIR` (or `~/code/mob_new`) pointing at a mob_new checkout —
    `mob.adopt`'s native trees render from mob_new's
    `priv/templates/mob.new/`. Skipped if not found.
  - Set `MOB_DIR` / `MOB_DEV_DIR` to use local `path:` deps for `:mob`
    and `:mob_dev`; otherwise `:mob` is fetched from Hex (`:mob_dev` is
    always the local checkout under test).

  Unlike the mob_new original (where adopt shipped in the globally
  installed mob_new archive), adopt now ships in mob_dev — a regular
  dep — so the generated project gets mob_dev wired in as a `path:` dep
  pointing at the checkout under test, and runs `mix mob.adopt` from
  there.
  """
  use ExUnit.Case, async: false

  @moduletag :acceptance
  @moduletag timeout: 600_000

  # The mob_dev checkout under test — the project gets a path: dep on
  # this so `mix mob.adopt` runs the code we just changed.
  @mob_dev_root Path.expand("../..", __DIR__)

  setup_all do
    cond do
      not phx_new_available?() ->
        {:skip, "phx.new not installed — run `mix archive.install hex phx_new`"}

      mob_new_checkout() == nil ->
        {:skip,
         "mob_new checkout not found — set MOB_NEW_DIR or clone to ~/code/mob_new " <>
           "(mob.adopt renders native trees from mob_new's priv/templates/mob.new/)"}

      true ->
        :ok
    end
  end

  setup do
    tmp = System.tmp_dir!() |> Path.join("mob_acceptance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "LV mode against a phx.new --database sqlite3 project produces a usable mob app", %{
    tmp: tmp
  } do
    app_dir = Path.join(tmp, "test_mob_app")

    # SQLite-shaped Phoenix project — adopt's LV mob_app.ex assumes the
    # host Repo is SQLite. `mix phx.new --database sqlite3` is the only
    # blessed shape today.
    {output, code} =
      System.cmd(
        "mix",
        [
          "phx.new",
          "test_mob_app",
          "--no-install",
          "--database",
          "sqlite3",
          "--no-mailer",
          "--no-dashboard"
        ],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert code == 0, "mix phx.new failed:\n#{output}"

    # Drift check
    assert_phoenix_shape_stable!(app_dir)

    # phx.new doesn't include :igniter or :mob_dev
    patch_mix_exs_add_mob_deps!(app_dir)

    {output, code} = System.cmd("mix", ["deps.get"], cd: app_dir, stderr_to_stdout: true)
    assert code == 0, "deps.get (initial, with :igniter + :mob_dev) failed:\n#{output}"

    # Run mob.adopt
    local_args = if mob_local_checkout?(), do: ["--local"], else: []

    {output, code} =
      System.cmd(
        "mix",
        ["mob.adopt", "--yes"] ++ local_args,
        cd: app_dir,
        stderr_to_stdout: true,
        env: adopt_env()
      )

    assert code == 0, "mob.adopt failed:\n#{output}"

    # Adopt-output assertions.
    mix_exs = File.read!(Path.join(app_dir, "mix.exs"))
    assert mix_exs =~ ":mob", "mob.adopt didn't add :mob to mix.exs"
    assert mix_exs =~ ":mob_dev", "mob.adopt didn't add :mob_dev to mix.exs"

    for relative <- [
          "lib/test_mob_app/mob_screen.ex",
          "lib/test_mob_app/mob_app.ex",
          "src/test_mob_app.erl",
          "mob.exs",
          "android/build.gradle",
          "ios/Info.plist"
        ] do
      assert File.exists?(Path.join(app_dir, relative)),
             "mob.adopt didn't emit #{relative}"
    end

    # Compile check.
    {output, code} = System.cmd("mix", ["deps.get"], cd: app_dir, stderr_to_stdout: true)
    assert code == 0, "deps.get failed after adopt:\n#{output}"

    {output, code} = System.cmd("mix", ["compile"], cd: app_dir, stderr_to_stdout: true)

    assert code == 0,
           "DRIFT: mix compile failed after mob.adopt — adopt's generated " <>
             "code likely references a Phoenix or Mob module that has moved.\n\n" <>
             output

    # Runtime smoke check — `mix compile` only catches missing modules at
    # the syntactic level (`Ecto.Migrator.run(SomeUndefined.Repo, ...)`
    # compiles to a runtime call against an atom). `Application.ensure_all_started`
    # actually validates that every declared application is installed and
    # loadable. Catches the "adopt forgot to add :ecto_sqlite3" class of bug
    # the @moduledoc explicitly warns about.
    {output, code} =
      System.cmd(
        "mix",
        ["run", "--no-start", "-e", "{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)"],
        cd: app_dir,
        stderr_to_stdout: true
      )

    assert code == 0,
           "Runtime smoke check failed — `:ecto_sqlite3` is not installed/loadable. " <>
             "adopt.deps should have added it for the LV-flavoured mob_app.ex.\n\n" <>
             output
  end

  test "thin-client mode (--no-live-view) against a --no-ecto phx.new project works",
       %{tmp: tmp} do
    app_dir = Path.join(tmp, "test_thin_app")

    # No-ecto Phoenix project — thin-client mode has no Repo dependency.
    {output, code} =
      System.cmd(
        "mix",
        [
          "phx.new",
          "test_thin_app",
          "--no-install",
          "--no-ecto",
          "--no-mailer",
          "--no-dashboard"
        ],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert code == 0, "mix phx.new failed:\n#{output}"

    patch_mix_exs_add_mob_deps!(app_dir)

    {output, code} = System.cmd("mix", ["deps.get"], cd: app_dir, stderr_to_stdout: true)
    assert code == 0, "deps.get failed:\n#{output}"

    local_args = if mob_local_checkout?(), do: ["--local"], else: []

    {output, code} =
      System.cmd(
        "mix",
        ["mob.adopt", "--yes", "--no-live-view", "--host-url", "https://example.fly.dev/"] ++
          local_args,
        cd: app_dir,
        stderr_to_stdout: true,
        env: adopt_env()
      )

    assert code == 0, "mob.adopt --no-live-view failed:\n#{output}"

    # Thin mode generates the same set of files as LV mode, minus the
    # bridge patches (which no-op without LV). mob_app.ex should be the
    # thin variant (`use Mob.App`, no `ensure_all_started(:test_thin_app)`).
    mob_app = File.read!(Path.join(app_dir, "lib/test_thin_app/mob_app.ex"))
    assert mob_app =~ "use Mob.App"
    refute mob_app =~ "{:ok, _} = Application.ensure_all_started(:test_thin_app)"
    refute mob_app =~ "Ecto.Migrator.run"

    # config/config.exs should have host_url for the WebView.
    config = File.read!(Path.join(app_dir, "config/config.exs"))
    assert config =~ ~s(host_url: "https://example.fly.dev/")

    # Compile + boot smoke check.
    {output, code} = System.cmd("mix", ["deps.get"], cd: app_dir, stderr_to_stdout: true)
    assert code == 0, "deps.get failed after adopt:\n#{output}"

    {output, code} = System.cmd("mix", ["compile"], cd: app_dir, stderr_to_stdout: true)
    assert code == 0, "compile failed:\n#{output}"
  end

  defp assert_phoenix_shape_stable!(app_dir) do
    app_js_path = Path.join(app_dir, "assets/js/app.js")

    assert File.exists?(app_js_path),
           "DRIFT: assets/js/app.js not at the expected path. Phoenix may have " <>
             "moved the JS entry point — mob.adopt's MobHook patcher targets " <>
             "that exact location."

    app_js = File.read!(app_js_path)

    assert app_js =~ "new LiveSocket(",
           "DRIFT: assets/js/app.js no longer contains `new LiveSocket(`. " <>
             "mob.adopt's MobHook patcher targets that exact substring. " <>
             "Either Phoenix changed conventions (check phx.new's release notes) " <>
             "or this acceptance test needs updating."

    root_candidates = [
      "lib/test_mob_app_web/components/layouts/root.html.heex",
      "lib/test_mob_app_web/templates/layout/root.html.heex"
    ]

    root_relative = Enum.find(root_candidates, &File.exists?(Path.join(app_dir, &1)))

    assert root_relative,
           "DRIFT: root.html.heex not at any of:\n  - " <>
             Enum.join(root_candidates, "\n  - ") <>
             "\nmob.adopt's bridge `<div>` injection targets these paths."

    root = File.read!(Path.join(app_dir, root_relative))

    assert root =~ ~r/<body[^>]*>/,
           "DRIFT: #{root_relative} no longer contains a `<body>` tag. " <>
             "mob.adopt injects the bridge `<div>` right after `<body>`."
  end

  defp phx_new_available? do
    match?({_, 0}, System.cmd("mix", ["help", "phx.new"], stderr_to_stdout: true))
  end

  # `--local` resolves :mob (and :mob_dev) from MOB_DIR / MOB_DEV_DIR.
  # Without it, :mob comes from Hex but :mob_dev is still the local
  # checkout under test (always a path: dep — see patch_mix_exs_add_mob_deps!).
  defp mob_local_checkout? do
    with mob_dir when is_binary(mob_dir) <- System.get_env("MOB_DIR"),
         mob_dev_dir when is_binary(mob_dev_dir) <- System.get_env("MOB_DEV_DIR"),
         true <- File.dir?(mob_dir),
         true <- File.dir?(mob_dev_dir) do
      true
    else
      _ -> false
    end
  end

  defp mob_new_checkout do
    [System.get_env("MOB_NEW_DIR"), Path.expand("~/code/mob_new")]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(fn dir -> File.dir?(Path.join(dir, "priv/templates/mob.new")) end)
  end

  # mob.adopt needs MOB_NEW_DIR set so its template resolver finds
  # mob_new (the home-dir fallback expands to the running user's home,
  # not necessarily where mob_new lives).
  defp adopt_env do
    [{"MOB_NEW_DIR", mob_new_checkout()}]
  end

  # phx.new emits neither :igniter nor :mob_dev. adopt ships in mob_dev,
  # so the generated project needs a path: dep on the checkout under test
  # to run the code we're testing.
  defp patch_mix_exs_add_mob_deps!(app_dir) do
    path = Path.join(app_dir, "mix.exs")
    content = File.read!(path)

    deps_snippet =
      ~s(\\1\n      {:igniter, "~> 0.7", only: [:dev, :test]},) <>
        ~s(\n      {:mob_dev, path: "#{@mob_dev_root}", only: :dev, runtime: false},)

    patched =
      Regex.replace(
        ~r/(defp deps do\s*\[)/,
        content,
        deps_snippet,
        global: false
      )

    assert patched != content,
           "DRIFT: could not patch mix.exs to add :igniter + :mob_dev. The " <>
             "`defp deps do [` shape may have changed in phx.new."

    File.write!(path, patched)
  end
end
