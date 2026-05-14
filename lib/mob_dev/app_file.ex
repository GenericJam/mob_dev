defmodule MobDev.AppFile do
  @moduledoc false

  # Helpers for parsing OTP .app files (the Erlang term file every
  # compiled app ships in `<app>-<vsn>/ebin/<app>.app`).

  @doc """
  Extract the `vsn` value from an .app file's contents.

      iex> MobDev.AppFile.vsn_from_content(~s|{application,foo,[{vsn,"1.2.3"}]}|)
      "1.2.3"

      iex> MobDev.AppFile.vsn_from_content("not an app file")
      nil
  """
  @spec vsn_from_content(String.t()) :: String.t() | nil
  def vsn_from_content(content) when is_binary(content) do
    case Regex.run(Regex.compile!("\\{vsn,\"([^\"]+)\"\\}"), content) do
      [_, vsn] -> vsn
      _ -> nil
    end
  end

  @doc """
  Read an .app file from disk and return its vsn, or nil if the file
  doesn't exist or doesn't parse.
  """
  @spec vsn_from_path(Path.t()) :: String.t() | nil
  def vsn_from_path(path) do
    case File.read(path) do
      {:ok, content} -> vsn_from_content(content)
      _ -> nil
    end
  end

  @doc """
  Resolve the installed version of a hex dep. Prefers `mix.lock` (most
  reliable, survives across envs); falls back to the compiled .app file
  under `_build/dev/lib/<dep>/ebin/<dep>.app`. Returns nil if neither
  source resolves.
  """
  @spec dep_version(String.t() | atom()) :: String.t() | nil
  def dep_version(dep) when is_atom(dep), do: dep_version(Atom.to_string(dep))

  def dep_version(dep) when is_binary(dep) do
    case lock_version(dep) do
      nil -> wildcard_app_version(dep)
      vsn -> vsn
    end
  end

  defp lock_version(dep) do
    with {:ok, lock} <- File.read("mix.lock"),
         pattern <- Regex.compile!("\"#{Regex.escape(dep)}\"[^\"]*\"(\\d+\\.\\d+\\.\\d+)\""),
         [_, vsn] <- Regex.run(pattern, lock) do
      vsn
    else
      _ -> nil
    end
  end

  defp wildcard_app_version(dep) do
    case Path.wildcard("_build/dev/lib/#{dep}/ebin/#{dep}.app") do
      [app_file | _] -> vsn_from_path(app_file)
      _ -> nil
    end
  end
end
