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
end
