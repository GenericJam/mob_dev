defmodule MobDev.Server.AuthTest do
  # Starts the named dashboard processes and writes :mob_dev app env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Phoenix.ConnTest
  import Plug.Conn

  alias MobDev.Server.{Auth, DashboardLive, LiveSocket}
  alias Mix.Tasks.Mob.Server, as: ServerTask

  @endpoint MobDev.Server.Endpoint
  @port 4999
  @lan_ip {192, 168, 1, 5}
  @log_message "MOB551 sentinel log line"

  defmodule FakeDevicePoller do
    use GenServer

    def start_link(devices),
      do: GenServer.start_link(__MODULE__, devices, name: MobDev.Server.DevicePoller)

    @impl GenServer
    def init(devices), do: {:ok, devices}

    @impl GenServer
    def handle_call(:get_devices, _from, devices), do: {:reply, devices, devices}
  end

  describe "secrets" do
    test "every run gets a different secret_key_base, never the old constant" do
      first = ServerTask.endpoint_config(@port, @lan_ip, false)[:secret_key_base]
      second = ServerTask.endpoint_config(@port, @lan_ip, false)[:secret_key_base]

      assert first != second
      assert byte_size(first) >= 64

      refute first ==
               String.duplicate("mob_dev_secret_key_base_not_for_production_", 2)
    end

    test "every run gets a different access token" do
      refute Auth.generate_token() == Auth.generate_token()
      assert byte_size(Auth.generate_token()) >= 32
    end

    test "url_with_token/2 carries the token as a query parameter" do
      assert Auth.url_with_token("http://192.168.1.5:4040", "abc") ==
               "http://192.168.1.5:4040/?token=abc"
    end
  end

  describe "valid?/2" do
    test "accepts only the exact expected token" do
      assert Auth.valid?("tok", "tok")
      refute Auth.valid?("tok2", "tok")
      refute Auth.valid?("", "tok")
      refute Auth.valid?(nil, "tok")
      refute Auth.valid?(["tok"], "tok")
    end

    test "matches nothing when no token is configured" do
      refute Auth.valid?("", "")
      refute Auth.valid?(nil, nil)
      refute Auth.valid?("tok", nil)
    end
  end

  describe "endpoint_config/3" do
    test "binds every interface for the phone QR flow and allows the LAN origin" do
      config = ServerTask.endpoint_config(@port, @lan_ip, false)

      assert config[:http][:ip] == {0, 0, 0, 0}

      assert config[:check_origin] == [
               "http://localhost:4999",
               "http://127.0.0.1:4999",
               "http://192.168.1.5:4999"
             ]
    end

    test "--local binds loopback and allows only loopback origins" do
      config = ServerTask.endpoint_config(@port, nil, true)

      assert config[:http][:ip] == {127, 0, 0, 1}
      assert config[:check_origin] == ["http://localhost:4999", "http://127.0.0.1:4999"]
    end
  end

  describe "HTTP and socket access" do
    setup do
      token = Auth.generate_token()
      previous_endpoint = Application.get_env(:mob_dev, @endpoint)
      previous_token = Application.get_env(:mob_dev, :dashboard_token)

      Application.put_env(:mob_dev, :dashboard_token, token)

      Application.put_env(
        :mob_dev,
        @endpoint,
        Keyword.put(ServerTask.endpoint_config(@port, @lan_ip, false), :server, false)
      )

      on_exit(fn ->
        restore_env(@endpoint, previous_endpoint)
        restore_env(:dashboard_token, previous_token)
      end)

      start_supervised!({Phoenix.PubSub, name: MobDev.PubSub})
      start_supervised!(MobDev.Server.LogBuffer)
      start_supervised!(MobDev.Server.ElixirLogBuffer)
      start_supervised!(MobDev.Server.WatchWorker)
      start_supervised!({FakeDevicePoller, []})
      start_supervised!(@endpoint)

      MobDev.Server.LogBuffer.push(%{
        id: 1,
        serial: "emulator-5554",
        level: "I",
        tag: "Mob",
        message: @log_message,
        raw: @log_message,
        mob: true,
        ts: "12:00:00"
      })

      %{token: token}
    end

    test "a request without the token is refused and shows no logs" do
      conn = get(build_conn(), "/")

      assert conn.status == 401
      refute conn.resp_body =~ @log_message
    end

    test "a wrong token is refused", %{token: token} do
      conn = get(build_conn(), "/?token=" <> token <> "x")

      assert conn.status == 401
      refute conn.resp_body =~ @log_message
    end

    test "static assets need the token too" do
      assert get(build_conn(), "/assets/phoenix/phoenix.min.js").status == 401
    end

    test "the token sets a session cookie and redirects off the token URL", %{token: token} do
      conn = get(build_conn(), "/assets/phoenix/phoenix.min.js?token=" <> token)

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/"]
      assert Map.keys(conn.resp_cookies) == ["_mob_dev_session_4999"]

      conn = get(recycle(conn), "/")

      assert conn.status == 200
      assert conn.resp_body =~ @log_message
    end

    test "a session from another run's token is refused", %{token: token} do
      conn = get(build_conn(), "/?token=" <> token)
      Application.put_env(:mob_dev, :dashboard_token, Auth.generate_token())

      assert get(recycle(conn), "/").status == 401
    end

    test "the LiveView socket refuses a connect without the run's token", %{token: token} do
      socket = %Phoenix.Socket{endpoint: @endpoint}

      assert :error = LiveSocket.connect(%{}, socket, %{session: nil})
      assert :error = LiveSocket.connect(%{}, socket, %{session: %{}})
      assert :error = LiveSocket.connect(%{}, socket, %{session: Auth.session("nope")})
      assert :error = LiveSocket.connect(%{}, socket, %{session: %{"mob_dev_auth" => token}})

      assert {:ok, %Phoenix.Socket{}} =
               LiveSocket.connect(%{}, socket, %{session: Auth.session(token)})
    end

    test "the session holds a digest, not the token", %{token: token} do
      refute inspect(Auth.session(token)) =~ token
    end

    test "the endpoint mounts the checking socket at /live" do
      assert {"/live", LiveSocket, _opts} =
               Enum.find(@endpoint.__sockets__(), &(elem(&1, 0) == "/live"))
    end

    test "the LiveView socket refuses a foreign origin" do
      check = fn origin ->
        build_conn()
        |> put_req_header("origin", origin)
        |> Phoenix.Socket.Transport.check_origin(LiveSocket, @endpoint, [])
      end

      assert check.("http://evil.example").status == 403
      assert check.("http://localhost:4040").status == 403
      refute check.("http://localhost:4999").halted
      refute check.("http://192.168.1.5:4999").halted
    end
  end

  describe "deploy event" do
    setup do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          devices: [%{serial: "emulator-5554", platform: :android}],
          deploying: %{},
          deploy_output: %{}
        }
      }

      %{socket: socket}
    end

    test "deploy_mode/1 accepts only the modes the dashboard offers" do
      assert DashboardLive.deploy_mode("update") == {:ok, :update}
      assert DashboardLive.deploy_mode("first_deploy") == {:ok, :first_deploy}
      assert DashboardLive.deploy_mode("Update") == :error
      assert DashboardLive.deploy_mode(nil) == :error
    end

    test "an unknown mode starts no deploy and creates no atom", %{socket: socket} do
      mode = "mob551_mode_#{System.unique_integer([:positive])}"
      params = %{"serial" => "emulator-5554", "mode" => mode}

      assert {:noreply, ^socket} = DashboardLive.handle_event("deploy", params, socket)
      assert_raise ArgumentError, fn -> String.to_existing_atom(mode) end
    end

    test "an unknown device starts no deploy", %{socket: socket} do
      params = %{"serial" => "no-such-device", "mode" => "update"}

      assert {:noreply, ^socket} = DashboardLive.handle_event("deploy", params, socket)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mob_dev, key)
  defp restore_env(key, value), do: Application.put_env(:mob_dev, key, value)
end
