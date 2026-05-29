defmodule MobDev.Plugin.TrustStore do
  @moduledoc """
  Reads + writes the `config :mob, :trusted_plugins, %{...}` entry in `mob.exs`.

  Trust is per-host: each host project records which plugin fingerprints
  it trusts in its own `mob.exs`. There is no central registry; the
  initial trust is established once via `mix mob.plugin.trust <name>`.

  The on-disk shape is:

      config :mob, :trusted_plugins, %{
        mob_foo: "ed25519:abc...=",
        mob_bar: "ed25519:def...="
      }

  Mutations (`add_trust/2`, `remove_trust/1`) work line-by-line over
  the existing `mob.exs` so unrelated config and user comments are
  preserved. `mob.exs` is the source of truth — `load_trusted_plugins/0`
  reads it via `Config.Reader.read!` exactly like the activation
  reader in `MobDev.Plugin.activated_names/0`.
  """

  alias MobDev.Plugin.Crypto

  @config_file "mob.exs"

  @typedoc "Map of plugin name to `\"ed25519:<base64>\"` fingerprint."
  @type trust_map :: %{atom() => String.t()}

  @doc """
  Reads `config :mob, :trusted_plugins` from `mob.exs` in the cwd.

  Returns an empty map when the key is unset or the file is missing.
  Pure: this function uses `Config.Reader.read!`, the same approach
  used to read `config :mob, :plugins` (the activation list).
  """
  @spec load_trusted_plugins() :: trust_map()
  def load_trusted_plugins do
    load_trusted_plugins(File.cwd!())
  end

  @doc "Variant of `load_trusted_plugins/0` that reads from `project_dir`."
  @spec load_trusted_plugins(Path.t()) :: trust_map()
  def load_trusted_plugins(project_dir) do
    path = Path.join(project_dir, @config_file)

    if File.exists?(path) do
      path
      |> Config.Reader.read!()
      |> Keyword.get(:mob, [])
      |> Keyword.get(:trusted_plugins, %{})
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  @doc """
  Returns `true` if the stored fingerprint for `name` matches `pub_bin`.

  A plugin with no trust entry is not trusted. A plugin with a stored
  fingerprint different from `Crypto.fingerprint(pub_bin)` is not
  trusted (key rotation event — caller is expected to surface this
  separately).
  """
  @spec trusted?(atom(), Crypto.pub_key()) :: boolean()
  def trusted?(name, pub_bin) when is_atom(name) and is_binary(pub_bin) do
    trusted?(name, pub_bin, load_trusted_plugins())
  end

  @doc "Variant of `trusted?/2` that takes the trust map as input (pure)."
  @spec trusted?(atom(), Crypto.pub_key(), trust_map()) :: boolean()
  def trusted?(name, pub_bin, trust_map)
      when is_atom(name) and is_binary(pub_bin) and is_map(trust_map) do
    case Map.fetch(trust_map, name) do
      {:ok, fingerprint} -> fingerprint == Crypto.fingerprint(pub_bin)
      :error -> false
    end
  end

  @doc """
  Writes `name => Crypto.fingerprint(pub_bin)` into `mob.exs`.

  Preserves unrelated config and user comments by editing the file
  line-by-line rather than regenerating it. Idempotent: writing the
  same fingerprint a second time is a no-op. Replaces an existing
  entry on key rotation. Adds the `config :mob, :trusted_plugins, …`
  line at the end of the file when no entry exists yet.
  """
  @spec add_trust(atom(), Crypto.pub_key()) :: :ok | {:error, term()}
  def add_trust(name, pub_bin) when is_atom(name) and is_binary(pub_bin) do
    add_trust(name, pub_bin, File.cwd!())
  end

  @doc "Variant of `add_trust/2` that targets `project_dir`."
  @spec add_trust(atom(), Crypto.pub_key(), Path.t()) :: :ok | {:error, term()}
  def add_trust(name, pub_bin, project_dir)
      when is_atom(name) and is_binary(pub_bin) and is_binary(project_dir) do
    fingerprint = Crypto.fingerprint(pub_bin)
    update_trust_entry(project_dir, fn map -> Map.put(map, name, fingerprint) end)
  end

  @doc "Removes the trust entry for `name` from `mob.exs`."
  @spec remove_trust(atom()) :: :ok
  def remove_trust(name) when is_atom(name) do
    remove_trust(name, File.cwd!())
  end

  @doc "Variant of `remove_trust/1` that targets `project_dir`."
  @spec remove_trust(atom(), Path.t()) :: :ok
  def remove_trust(name, project_dir) when is_atom(name) and is_binary(project_dir) do
    case update_trust_entry(project_dir, fn map -> Map.delete(map, name) end) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # ── mob.exs editing ────────────────────────────────────────────────────────

  defp update_trust_entry(project_dir, transform) do
    path = Path.join(project_dir, @config_file)

    case File.read(path) do
      {:ok, source} ->
        current = load_trusted_plugins(project_dir)
        new_map = transform.(current)
        updated = replace_or_append_trust_line(source, new_map)
        File.write!(path, updated)
        :ok

      {:error, :enoent} ->
        new_map = transform.(%{})

        # No mob.exs yet — create the minimal one (header + use Config + the
        # trusted_plugins entry). Same pattern used by mob_new templates.
        contents =
          "import Config\n\nconfig :mob, :trusted_plugins, " <> inspect_trust_map(new_map) <> "\n"

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # If the file already declares `config :mob, :trusted_plugins, ...` (any
  # arity, possibly multi-line) we replace the whole stanza; otherwise we
  # append a fresh line. The map shape is pretty-printed via `inspect/2`
  # with sorted keys for stable diffs.
  defp replace_or_append_trust_line(source, new_map) do
    new_line = "config :mob, :trusted_plugins, " <> inspect_trust_map(new_map)

    cond do
      Regex.match?(trust_stanza_pattern(), source) ->
        Regex.replace(trust_stanza_pattern(), source, fn _ -> new_line end, global: false)

      String.ends_with?(source, "\n") ->
        source <> new_line <> "\n"

      true ->
        source <> "\n" <> new_line <> "\n"
    end
  end

  # Matches `config :mob, :trusted_plugins, <term>` where <term> can be a
  # map literal possibly spanning multiple lines. We use a greedy match up
  # to the closing `}` and rely on the writer always serialising the value
  # as a `%{...}` literal (see inspect_trust_map/1) so this stays stable.
  defp trust_stanza_pattern do
    ~r/config\s+:mob\s*,\s*:trusted_plugins\s*,\s*%\{[^}]*\}/s
  end

  defp inspect_trust_map(map) do
    sorted = map |> Map.to_list() |> Enum.sort()
    inspect(Map.new(sorted), pretty: false, limit: :infinity)
  end
end
