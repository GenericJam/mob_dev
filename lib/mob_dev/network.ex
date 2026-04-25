defmodule MobDev.Network do
  @moduledoc "Network utilities for mob_dev."

  @doc """
  Returns the first LAN IPv4 address found on this machine, or nil.
  Skips loopback. Matches 10.x, 192.168.x, and 172.16-31.x ranges.
  """
  @spec lan_ip() :: :inet.ip4_address() | nil
  def lan_ip do
    case :inet.getif() do
      {:ok, ifaces} ->
        ifaces
        |> Enum.map(fn {ip, _broadcast, _mask} -> ip end)
        |> first_lan_ip()

      _ ->
        nil
    end
  end

  @doc "Returns the first LAN IP from a list of IP tuples, or nil."
  @spec first_lan_ip([:inet.ip4_address()]) :: :inet.ip4_address() | nil
  def first_lan_ip(ips), do: Enum.find(ips, &lan_ip?/1)

  @doc "Returns true if the IP tuple is a private LAN address (non-loopback)."
  @spec lan_ip?(:inet.ip_address()) :: boolean()
  def lan_ip?({127, _, _, _}), do: false
  def lan_ip?({10, _, _, _}), do: true
  def lan_ip?({172, b, _, _}), do: b >= 16 and b <= 31
  def lan_ip?({192, 168, _, _}), do: true
  def lan_ip?(_), do: false
end
