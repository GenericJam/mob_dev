defmodule MobDev.Plugin.PrivateKeyStore do
  @moduledoc """
  Author-side storage for the per-plugin Ed25519 private key.

  Keys live at `~/.mob/keys/<plugin_name>.priv` as a single line of
  base64-encoded raw 32-byte key (with a trailing newline). The file
  is chmod'd 0600. Plain text is intentional — plugin authors should
  be able to inspect and back up the key with standard tools.

  This module is **author-only**; hosts never need it. The host-side
  trust model (`TrustStore`) keys off the public key fingerprint
  recorded in `mob.exs`.
  """

  alias MobDev.Plugin.Crypto

  @key_dir_relative ".mob/keys"
  @key_extension ".priv"
  @secure_mode 0o600

  @typedoc "Errors `read_key/1` can return."
  @type read_error :: :missing | :malformed

  @doc """
  Absolute path to the priv key file for `plugin_name`.

  Always under `~/.mob/keys/`. Pure (no I/O) and used by both
  `read_key/1` and `write_key/2`.
  """
  @spec key_path(atom() | String.t()) :: Path.t()
  def key_path(plugin_name) do
    name = to_string(plugin_name)
    Path.join([key_dir(), name <> @key_extension])
  end

  @doc "Absolute path of the directory all priv keys live in."
  @spec key_dir() :: Path.t()
  def key_dir do
    Path.join(home_dir(), @key_dir_relative)
  end

  @doc """
  Reads the priv key for `plugin_name` and returns the raw 32-byte
  binary. Returns `{:error, :missing}` if the file is absent or
  `{:error, :malformed}` if the contents don't decode to a 32-byte key.
  """
  @spec read_key(atom() | String.t()) :: {:ok, Crypto.priv_key()} | {:error, read_error()}
  def read_key(plugin_name) do
    path = key_path(plugin_name)

    case File.read(path) do
      {:ok, contents} -> decode_priv_key(contents)
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp decode_priv_key(contents) do
    trimmed = String.trim(contents)

    case Base.decode64(trimmed) do
      {:ok, priv} when byte_size(priv) == 32 -> {:ok, priv}
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Writes the priv key for `plugin_name` to disk with mode 0600.

  Creates the key directory if needed. Overwrites any existing file —
  callers (`mix mob.plugin.keygen`) gate this on a confirmation /
  `--force` flag before invoking.
  """
  @spec write_key(atom() | String.t(), Crypto.priv_key()) :: :ok
  def write_key(plugin_name, priv_bin) when is_binary(priv_bin) do
    path = key_path(plugin_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Base.encode64(priv_bin) <> "\n")
    File.chmod!(path, @secure_mode)
    :ok
  end

  @doc "File mode applied to written keys (0o600 = owner read+write only)."
  @spec secure_mode() :: integer()
  def secure_mode, do: @secure_mode

  # Resolved per-call so tests can override via the `:mob_dev` Application
  # env (`:plugin_key_home`). Falls back to `System.user_home!/0`, which
  # is what end users hit. `HOME` env-var overrides are intentionally
  # not honoured — Erlang caches the user home at OTP boot and `HOME`
  # changes inside a running BEAM don't flow through.
  defp home_dir do
    case Application.get_env(:mob_dev, :plugin_key_home) do
      nil -> System.user_home!()
      override when is_binary(override) -> override
    end
  end
end
