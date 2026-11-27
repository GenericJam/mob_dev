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

  describe "write_app_file!/2" do
    @managed String.to_atom(String.duplicate("0123456789abcdef", 4))

    test "writes the cookie the app reads at boot, owner-only", %{path: path} do
      dir = Path.join(Path.dirname(path), "beams")
      written = DistCookie.write_app_file!(dir, @managed)

      assert written == Path.join(dir, "mob_dist_cookie")
      assert File.read!(written) == Atom.to_string(@managed) <> "\n"
      assert File.stat!(written).mode |> Bitwise.band(0o777) == 0o600
      assert File.ls!(dir) == ["mob_dist_cookie"]
    end

    test "replaces an older, readable file and makes it owner-only", %{path: path} do
      dir = Path.dirname(path)
      old = Path.join(dir, "mob_dist_cookie")
      File.mkdir_p!(dir)
      File.write!(old, String.duplicate("f", 64))
      File.chmod!(old, 0o644)

      DistCookie.write_app_file!(dir, @managed)

      assert File.read!(old) == Atom.to_string(@managed) <> "\n"
      assert File.stat!(old).mode |> Bitwise.band(0o777) == 0o600
    end
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
          ordered: false,
          # Wait for every task, not a wall clock: under machine load 5 s
          # (the default) timed this out with nothing wrong (MOB-339).
          timeout: :infinity
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
    # MOB-552: the public legacy cookie is never presented implicitly.
    test "without an explicit cookie, the private cookie is the only candidate" do
      assert DistCookie.candidates(nil, fn -> :private end) == [:private]
    end

    test "an explicit cookie is the only candidate" do
      never = fn -> flunk("must not load the managed cookie") end

      assert DistCookie.candidates(" chosen ", never) == [:chosen]
      assert DistCookie.candidates(:chosen, never) == [:chosen]
      assert_raise Mix.Error, ~r/1 to 255 bytes/, fn -> DistCookie.candidates("  ", never) end
    end

    # The first candidate becomes the Mac node's default cookie and the cookie
    # handed to restarted apps; the public one must never be either.
    test "an explicit legacy cookie is honoured, after the private one" do
      assert DistCookie.candidates("mob_secret", fn -> :private end) == [:private, :mob_secret]
      assert DistCookie.candidates(:mob_secret, fn -> :private end) == [:private, :mob_secret]
    end
  end

  describe "connect_failure_hint/1" do
    test "without an explicit cookie, says how to reach a legacy app" do
      hint = DistCookie.connect_failure_hint(nil)

      assert hint =~ "private cookie"
      assert hint =~ "--cookie mob_secret"
      assert hint =~ "mix mob.deploy"
    end

    test "an explicit cookie gets no hint: the user chose it" do
      assert DistCookie.connect_failure_hint("custom") == nil
      assert DistCookie.connect_failure_hint("mob_secret") == nil
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
        assert DistCookie.connect(node, [:private_cookie_a]) == {:ok, :private_cookie_a}
      end)

    assert node in Node.list()
    assert output == ""
  end

  # MOB-552: without `--cookie`, mob_dev never presents the public cookie.
  test "an app on the legacy cookie is not reached without an explicit cookie" do
    node = start_peer(:mob_secret)
    candidates = DistCookie.candidates(nil, fn -> :private_cookie_b end)

    assert DistCookie.connect(node, candidates) == :error
    refute node in Node.list()
    assert :erlang.get_cookie(node) == :private_cookie_b
  end

  test "an explicit --cookie mob_secret reaches a legacy app, with a warning to redeploy" do
    node = start_peer(:mob_secret)
    candidates = DistCookie.candidates("mob_secret", fn -> :private_cookie_f end)

    output =
      capture_io(:stderr, fn ->
        assert DistCookie.connect(node, candidates) == {:ok, :mob_secret}
      end)

    assert node in Node.list()
    assert output =~ "mob_secret"
    assert output =~ "mix mob.deploy"
  end

  test "with --cookie mob_secret, an up-to-date app still connects on its private cookie" do
    node = start_peer(:private_cookie_g)
    candidates = DistCookie.candidates("mob_secret", fn -> :private_cookie_g end)

    output =
      capture_io(:stderr, fn ->
        assert DistCookie.connect(node, candidates) == {:ok, :private_cookie_g}
      end)

    assert output == ""
  end

  # A per-node cookie also authenticates connections *from* that node name, so
  # leaving the public one set would let anyone claiming the name in.
  test "a failed attempt leaves the node on the private cookie, not the legacy one" do
    node = start_peer(:some_other_cookie)

    assert DistCookie.connect(node, [:private_cookie_c, :mob_secret]) == :error
    assert :erlang.get_cookie(node) == :private_cookie_c
  end

  # OTP reports an existing connection as success without a handshake, so a
  # later call must not overwrite the cookie the node really accepted
  # (reconnects would then fail).
  test "an already connected node keeps the cookie it accepted" do
    node = start_peer(:mob_secret)

    capture_io(:stderr, fn ->
      assert DistCookie.connect(node, [:mob_secret]) == {:ok, :mob_secret}
    end)

    assert DistCookie.connect(node, [:private_cookie_d]) == {:ok, :mob_secret}
    assert :erlang.get_cookie(node) == :mob_secret
  end

  # MOB-552: the iOS battery bench presents only the cookie it launched the
  # app with, never the public legacy one.
  test "the iOS battery bench does not reach a legacy app" do
    node = start_peer(:mob_secret)

    assert Mix.Tasks.Mob.BatteryBenchIos.dist_connect(node, :private_cookie_e) == :error
    refute node in Node.list()
  end
end
