defmodule MobDev.DistCookieTest do
  use ExUnit.Case, async: true

  alias MobDev.DistCookie

  setup do
    path = Path.join(System.tmp_dir!(), "mob-dist-cookie-#{System.unique_integer([:positive])}/c")
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    {:ok, path: path}
  end

  test "creates a strong cookie and reuses it for later sessions", %{path: path} do
    first = DistCookie.load_or_create!(path)
    second = DistCookie.load_or_create!(path)

    assert first == second
    assert Atom.to_string(first) =~ Regex.compile!("\\A[0-9a-f]{64}\\z")
    refute first == :mob_secret
  end

  test "keeps the cookie and containing directory owner-only", %{path: path} do
    DistCookie.load_or_create!(path)

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
  end

  test "repairs permissions when loading an existing cookie", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("a", 64))
    File.chmod!(Path.dirname(path), 0o755)
    File.chmod!(path, 0o644)

    assert DistCookie.load_or_create!(path) == String.to_atom(String.duplicate("a", 64))
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
  end

  test "different projects get different cookies", %{path: path} do
    other = Path.join(Path.dirname(path), "other")
    refute DistCookie.load_or_create!(path) == DistCookie.load_or_create!(other)
  end

  # Readers racing the first write must see a complete cookie, never an empty
  # file that reads as corrupt.
  test "concurrent first sessions converge on one cookie", %{path: path} do
    for _round <- 1..20 do
      File.rm_rf!(Path.dirname(path))

      cookies =
        1..16
        |> Task.async_stream(fn _ -> DistCookie.load_or_create!(path) end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.map(fn {:ok, cookie} -> cookie end)

      assert Enum.uniq(cookies) |> length() == 1
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end
  end

  test "rejects a corrupt cookie without exposing its contents", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not-a-valid-cookie")

    error = assert_raise Mix.Error, fn -> DistCookie.load_or_create!(path) end
    assert error.message =~ "is invalid"
    refute error.message =~ "not-a-valid-cookie"
  end

  test "derives an opaque stable path from the bundle id" do
    path = DistCookie.default_path("com.example.private")

    assert Path.dirname(path) |> String.ends_with?("/.mob/dist_cookies")
    refute path =~ "com.example.private"
    assert Path.basename(path) =~ Regex.compile!("\\A[0-9a-f]{64}\\z")
  end

  describe "candidates/2" do
    test "private cookie first, then the legacy public one" do
      assert DistCookie.candidates(nil, fn -> :private end) == [:private, :mob_secret]
    end

    test "an explicit cookie is the only candidate" do
      never = fn -> flunk("must not load the managed cookie") end

      assert DistCookie.candidates(" chosen ", never) == [:chosen]
      assert DistCookie.candidates(:chosen, never) == [:chosen]
      assert_raise Mix.Error, ~r/1 to 255 bytes/, fn -> DistCookie.candidates("  ", never) end
    end
  end
end

defmodule MobDev.DistCookieConnectTest do
  # Starts this VM's distribution and real peer nodes.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias MobDev.DistCookie

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    was_alive = Node.alive?()

    unless was_alive do
      name = :"dist_cookie_test_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = Node.start(name, :longnames)
    end

    on_exit(fn -> unless was_alive, do: Node.stop() end)
  end

  defp start_peer(cookie) do
    name = :"dc_peer_#{System.unique_integer([:positive])}"

    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        # The rejected handshakes are the point; keep their reports out of the run.
        args: [
          ~c"-setcookie",
          Atom.to_charlist(cookie),
          ~c"-kernel",
          ~c"logger_level",
          ~c"critical"
        ]
      })

    on_exit(fn -> :peer.stop(peer) end)
    node
  end

  test "a node with the private cookie connects on it, without a warning" do
    node = start_peer(:private_cookie_a)

    output =
      capture_io(:stderr, fn ->
        assert DistCookie.connect(node, [:private_cookie_a, :mob_secret]) ==
                 {:ok, :private_cookie_a}
      end)

    assert node in Node.list()
    assert output == ""
  end

  test "an app on the legacy cookie still connects, with a warning to redeploy" do
    node = start_peer(:mob_secret)

    output =
      capture_io(:stderr, fn ->
        assert DistCookie.connect(node, [:private_cookie_b, :mob_secret]) == {:ok, :mob_secret}
      end)

    assert node in Node.list()
    assert output =~ "mob_secret"
    assert output =~ "mix mob.deploy"
  end

  test "an explicit cookie gets no legacy fallback" do
    node = start_peer(:mob_secret)
    assert DistCookie.connect(node, [:explicit_cookie]) == :error
    refute node in Node.list()
  end

  # A per-node cookie also authenticates connections *from* that node name, so
  # leaving the public one set would let anyone claiming the name in.
  test "a failed attempt leaves the node on the private cookie, not the legacy one" do
    node = start_peer(:some_other_cookie)

    assert DistCookie.connect(node, [:private_cookie_c, :mob_secret]) == :error
    assert :erlang.get_cookie(node) == :private_cookie_c
  end

  # OTP reports an existing connection as success without a handshake, so a
  # second call must not re-try the private cookie and overwrite the legacy one
  # the node really accepted (reconnects would then fail).
  test "an already connected legacy node keeps the cookie it accepted" do
    node = start_peer(:mob_secret)
    candidates = [:private_cookie_d, :mob_secret]

    capture_io(:stderr, fn ->
      assert DistCookie.connect(node, candidates) == {:ok, :mob_secret}
    end)

    assert DistCookie.connect(node, candidates) == {:ok, :mob_secret}
    assert :erlang.get_cookie(node) == :mob_secret
  end
end
