defmodule MobDev.NodeUtil do
  @moduledoc false

  # Tiny helpers for parsing Erlang node atoms (`name@host`).

  @doc """
  Return the host portion of a node atom, or nil for nil/short names.

      iex> MobDev.NodeUtil.host_from_node(:"mob@10.0.0.1")
      "10.0.0.1"

      iex> MobDev.NodeUtil.host_from_node(:mob)
      nil

      iex> MobDev.NodeUtil.host_from_node(nil)
      nil
  """
  @spec host_from_node(atom() | nil) :: String.t() | nil
  def host_from_node(nil), do: nil

  def host_from_node(node) when is_atom(node) do
    case node |> Atom.to_string() |> String.split("@", parts: 2) do
      [_, host] -> host
      _ -> nil
    end
  end

  @doc """
  Starts distribution on the host so mob_dev can reach device nodes, and
  returns the local node name.

  An explicit `name` is used as given; failing to start under it is an error
  (`--name` is the documented way to run sessions side by side). With no
  explicit name the default `<base>@127.0.0.1` is tried first, and when another
  process on this Mac already holds it (a second `mix mob.connect`, a deploy
  running beside an IEx session, another agent) a per-OS-process name
  `<base>_<os pid>@127.0.0.1` is used instead. Device nodes accept any peer
  name, so the fallback changes nothing but the name. A node that is already
  distributed keeps its name and cookie (per-node cookies are set at connect).
  """
  @spec start_host_dist(node() | nil, atom(), String.t()) :: {:ok, node()} | {:error, term()}
  def start_host_dist(name, cookie, base \\ "mob_dev") do
    cond do
      Node.alive?() ->
        {:ok, node()}

      name != nil ->
        start(name, cookie)

      true ->
        with {:error, _} <- start(:"#{base}@127.0.0.1", cookie),
             do: start(:"#{base}_#{System.pid()}@127.0.0.1", cookie)
    end
  end

  defp start(name, cookie) do
    case Node.start(name, :longnames) do
      {:ok, _pid} ->
        Node.set_cookie(cookie)
        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
