defmodule MobDev.AdoptGuard do
  @moduledoc false
  # Pre-1.0 detect-and-refuse for `mix mob.adopt`. Adds `Igniter.add_issue/2`
  # entries when the target project doesn't match the blessed shape. The
  # caller is expected to skip the rest of its work when `igniter.issues`
  # is non-empty after `check/2` runs.

  alias Igniter.Project.Application, as: ProjectApplication
  alias Igniter.Project.Deps, as: ProjectDeps

  @doc """
  Returns `:live_view` when LV bridge mode is in effect (default) or
  `:thin` when `--no-live-view` was passed.
  """
  @spec mode_from(keyword()) :: :live_view | :thin
  def mode_from(opts) do
    if Keyword.get(opts, :live_view, true), do: :live_view, else: :thin
  end

  @doc """
  Runs the blessed-shape checks for `mode`. Returns the igniter with
  `add_issue/2` entries appended for any check that fails. Caller gates
  on `igniter.issues == []`.
  """
  @spec check(Igniter.t(), :live_view | :thin) :: Igniter.t()
  def check(igniter, mode) do
    igniter
    |> refuse_if_umbrella()
    |> require_phoenix_dep()
    |> maybe_check_live_view_shape(mode)
  end

  defp refuse_if_umbrella(igniter) do
    if umbrella?(igniter) do
      Igniter.add_issue(igniter, """
      mob.adopt does not support umbrella applications.
      Run it from inside one of the sub-app folders instead.
      """)
    else
      igniter
    end
  end

  # Stubbable via `Igniter.assign(:umbrella?, true|false)` for tests.
  defp umbrella?(igniter) do
    case igniter.assigns[:umbrella?] do
      nil -> Mix.Project.umbrella?()
      bool -> bool
    end
  end

  defp require_phoenix_dep(igniter) do
    if ProjectDeps.has_dep?(igniter, :phoenix) do
      igniter
    else
      Igniter.add_issue(igniter, """
      mob.adopt requires a Phoenix project (`:phoenix` in your mix.exs deps).
      For non-Phoenix Elixir apps, follow the manual install path documented
      at `mix help mob.adopt`.
      """)
    end
  end

  defp maybe_check_live_view_shape(igniter, :thin), do: igniter

  defp maybe_check_live_view_shape(igniter, :live_view) do
    igniter
    |> check_app_js()
    |> check_root_html()
    |> check_repo_shape()
  end

  # The LV-flavoured `mob_app.ex` calls `Application.ensure_all_started(:ecto_sqlite3)`
  # and runs `Ecto.Migrator.run(<App>.Repo, ...)` on-device. That assumes
  # the host has an Ecto Repo using the SQLite adapter (the `mix mob.new`
  # shape). Refuse loudly when the host doesn't match — silently emitting
  # a mob_app.ex that tries to migrate Postgres on a phone would crash at
  # boot.
  defp check_repo_shape(igniter) do
    cond do
      not has_any_ecto_repo?(igniter) ->
        Igniter.add_issue(igniter, """
        mob.adopt (LiveView mode) generates a `mob_app.ex` that boots Ecto
        and runs migrations on-device. Your project has no Ecto Repo
        (no `:ecto_sql` in deps).

        Options:
          - Add an Ecto Repo before adopting (e.g. start from a phx.new
            project with `--database sqlite3`).
          - Or use `--no-live-view` for the thin-client path — the phone
            opens a deployed Phoenix server; no on-device DB needed.
        """)

      has_non_sqlite_adapter?(igniter) and not has_sqlite_adapter?(igniter) ->
        Igniter.add_issue(igniter, """
        mob.adopt (LiveView mode) generates a `mob_app.ex` that migrates the
        host's `<App>.Repo` on-device — assumes SQLite. Your project looks
        like it uses Postgres / MySQL / MSSQL, which won't run on a phone.

        Options:
          - Use `--no-live-view` for the thin-client path (server hosts
            Phoenix + your existing DB; phone is just a WebView shell).
          - Switch the host Repo to SQLite (matches `mix mob.new --liveview`).
          - Wait for the upcoming `--with-local-repo` mode that generates a
            separate SQLite LocalRepo + target-aware Repo selection.
        """)

      true ->
        igniter
    end
  end

  defp has_any_ecto_repo?(igniter), do: ProjectDeps.has_dep?(igniter, :ecto_sql)
  defp has_sqlite_adapter?(igniter), do: ProjectDeps.has_dep?(igniter, :ecto_sqlite3)

  defp has_non_sqlite_adapter?(igniter) do
    Enum.any?([:postgrex, :myxql, :tds], &ProjectDeps.has_dep?(igniter, &1))
  end

  defp check_app_js(igniter) do
    path = "assets/js/app.js"

    cond do
      not Igniter.exists?(igniter, path) ->
        Igniter.add_issue(igniter, """
        mob.adopt (LiveView mode) requires #{path}. Not found.
        Use `--no-live-view` for thin-client mode (WebView opens a remote URL;
        no app.js patches needed).
        """)

      not stock_live_socket?(igniter, path) ->
        Igniter.add_issue(igniter, """
        mob.adopt (LiveView mode) requires a stock `new LiveSocket(...)` in #{path}.
        The current app.js shape is too customised for safe automated patching.
        Either restore the standard Phoenix shape or use `--no-live-view`.
        """)

      true ->
        igniter
    end
  end

  defp check_root_html(igniter) do
    web = "#{ProjectApplication.app_name(igniter)}_web"

    candidates = [
      "lib/#{web}/components/layouts/root.html.heex",
      "lib/#{web}/templates/layout/root.html.heex"
    ]

    case Enum.find(candidates, &Igniter.exists?(igniter, &1)) do
      nil ->
        Igniter.add_issue(igniter, """
        mob.adopt (LiveView mode) requires a root layout at one of:
          - lib/#{web}/components/layouts/root.html.heex
          - lib/#{web}/templates/layout/root.html.heex
        Neither was found. Use `--no-live-view` for thin-client mode.
        """)

      path ->
        if has_body_tag?(igniter, path) do
          igniter
        else
          Igniter.add_issue(igniter, """
          mob.adopt (LiveView mode) requires a `<body>` tag in #{path} for the
          bridge `<div>` injection. The current layout shape is too customised
          for safe automated patching.
          Either restore the standard layout or use `--no-live-view`.
          """)
        end
    end
  end

  defp stock_live_socket?(igniter, path) do
    case read_content(igniter, path) do
      {:ok, content} -> String.contains?(content, "new LiveSocket(")
      _ -> false
    end
  end

  defp has_body_tag?(igniter, path) do
    case read_content(igniter, path) do
      {:ok, content} -> Regex.match?(Regex.compile!("<body[^>]*>"), content)
      _ -> false
    end
  end

  defp read_content(igniter, path) do
    cond do
      igniter.assigns[:test_mode?] ->
        case igniter.assigns[:test_files][path] do
          nil -> {:error, :not_found}
          content -> {:ok, content}
        end

      File.regular?(path) ->
        File.read(path)

      true ->
        {:error, :not_found}
    end
  end
end
