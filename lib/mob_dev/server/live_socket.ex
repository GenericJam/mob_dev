defmodule MobDev.Server.LiveSocket do
  @moduledoc """
  The dashboard's LiveView socket. Refuses a connect whose session does not
  carry the current run's access token (see `MobDev.Server.Auth`).

  Phoenix loads `connect_info.session` only when the connect params carry a
  CSRF token that matches the session cookie, so a cross-site page cannot
  borrow the browser's cookie here.
  """

  use Phoenix.LiveView.Socket

  alias MobDev.Server.Auth

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    if Auth.authorized_session?(connect_info[:session]), do: {:ok, socket}, else: :error
  end

  # Same as the id/1 `use` delegates; restated because `@impl` on connect/3
  # makes the compiler want it on every callback.
  @impl Phoenix.Socket
  def id(socket), do: Phoenix.LiveView.Socket.id(socket)
end
