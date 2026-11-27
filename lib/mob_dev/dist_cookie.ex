defmodule MobDev.DistCookie do
  @moduledoc """
  The private distribution cookie for a project's development builds.

  One random 256-bit cookie per app (keyed by its bundle id), shared by iOS,
  Android and the Mac-side node, so concurrent `mob.connect` sessions attach
  without restarting the app under different credentials. It lives in an
  owner-only directory under `~/.mob/dist_cookies/`, reaches the app only at
  deploy/launch time, and is never printed. Deploy also writes it to
  `mob_dist_cookie` in the app's beams directory (`write_app_file!/2`), where
  the app reads it at boot, so a relaunch outside mob_dev keeps it.
  A hand-started node loads it with
  `Node.set_cookie(MobDev.DistCookie.for_project!())` from the project, which
  keeps it out of process arguments (`--cookie` would show it in `ps`).

  Apps built against a mob from before MOB-49 still answer to the public
  `:mob_secret`. mob_dev never presents it on its own (MOB-552): it would hand
  a public credential to whatever node answers. Such an app is reached only
  with an explicit `--cookie mob_secret`, which warns, until it is redeployed.
  Even then the private cookie stays the Mac node's own cookie and the one
  handed to apps; the public one is only ever a per-node cookie.
  """

  @cookie_bytes 32
  @cookie_pattern Regex.compile!("\\A[0-9a-f]{64}\\z")
  @legacy_cookie :mob_secret
  @app_file "mob_dist_cookie"

  @doc """
  Name of the cookie file in an app's beams directory. Android's `Mob.Dist`
  and iOS's `mob_beam.m` read `$MOB_BEAMS_DIR/mob_dist_cookie` at boot when
  the launch environment carries no cookie.
  """
  @spec app_file() :: String.t()
  def app_file, do: @app_file

  @doc """
  Writes `cookie` to `dir/mob_dist_cookie`, owner-only, and returns the path.

  For directories on this Mac that an app reads its BEAMs from: the iOS
  simulator runtime dir, or the staging dir a physical-iPhone deploy copies to
  the device. The cookie is written inside a fresh `0700` directory, made
  `0600`, then renamed over any previous file: nobody else can open it at any
  point (a descriptor opened on the parent before the `chmod` doesn't help,
  since lookups check the directory's current mode), and a booting app never
  sees half a file.
  """
  @spec write_app_file!(String.t(), atom()) :: String.t()
  def write_app_file!(dir, cookie) when is_binary(dir) and is_atom(cookie) do
    path = Path.join(dir, @app_file)

    private =
      Path.join(dir, ".#{@app_file}.#{System.pid()}.#{System.unique_integer([:positive])}")

    tmp = Path.join(private, @app_file)
    File.mkdir_p!(dir)

    try do
      File.mkdir!(private)
      File.chmod!(private, 0o700)
      File.write!(tmp, Atom.to_string(cookie) <> "\n", [:exclusive])
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path)
      path
    after
      File.rm_rf(private)
    end
  end

  @doc "Returns the private cookie for the current project, creating it on first use."
  @spec for_project!() :: atom()
  def for_project! do
    MobDev.Config.bundle_id()
    |> default_path()
    |> load_or_create!()
  end

  @doc """
  Cookies to try against a device node, in order.

  Without an explicit cookie (`--cookie`) the project's private cookie is the
  only candidate: the public legacy cookie is never tried implicitly. An
  explicit cookie is the only candidate, except the legacy one: that opts in
  to reaching apps built against a mob from before MOB-49, and comes after
  the private cookie, so up-to-date apps in the same session still connect on
  theirs.

  The first entry is the Mac-side node's default cookie and the one handed to
  restarted apps, so it is never the public legacy cookie: as a node's default
  it would admit any peer presenting it, under any name.
  """
  @spec candidates(atom() | String.t() | nil, (-> atom())) :: [atom(), ...]
  def candidates(explicit \\ nil, loader \\ &for_project!/0)
  def candidates(nil, loader), do: [loader.()]

  def candidates(explicit, loader) do
    case parse!(explicit) do
      @legacy_cookie -> [loader.(), @legacy_cookie]
      cookie -> [cookie]
    end
  end

  @doc """
  What to tell the user when no node accepted the cookie, given the
  `--cookie` option. Without one only the private cookie was tried, and an
  app built against a mob from before MOB-49 accepts just the legacy cookie,
  so the hint says how to move it or reach it as it is. An explicit cookie
  was the user's choice, so there is nothing to add.
  """
  @spec connect_failure_hint(atom() | String.t() | nil) :: String.t() | nil
  def connect_failure_hint(nil) do
    "An app that is running but did not answer may be built against a mob from before " <>
      "MOB-49: it accepts only the public cookie #{@legacy_cookie}, which mob_dev does not " <>
      "try on its own. Update its mob dependency and run `mix mob.deploy` (`--native` for " <>
      "iOS) to move it to this project's private cookie, or reach it as it is with " <>
      "`--cookie #{@legacy_cookie}`."
  end

  def connect_failure_hint(_explicit), do: nil

  @doc "Validates an explicit cookie given on the command line."
  @spec parse!(atom() | String.t()) :: atom()
  def parse!(cookie) when is_atom(cookie) and not is_nil(cookie), do: cookie

  def parse!(cookie) when is_binary(cookie) do
    cookie = String.trim(cookie)

    if byte_size(cookie) in 1..255 do
      String.to_atom(cookie)
    else
      Mix.raise("Distribution cookie must contain 1 to 255 bytes")
    end
  end

  @doc """
  Connects to `node`, trying each cookie in `cookies` in order.

  Returns `{:ok, cookie}` with the cookie that worked. An already connected
  node answers with the cookie it was connected under, untouched: OTP reports
  an existing connection as success without a handshake, so trying a
  candidate on it would prove nothing and overwrite the cookie that did
  authenticate. When no cookie works, the node's cookie is reset to the first
  candidate: a per-node cookie also authenticates *incoming* connections
  claiming that name, so the legacy cookie must not stay set for a node that
  did not need it. A node reached on the legacy cookie, which only an
  explicit `--cookie` supplies, gets a warning to redeploy it.
  """
  @spec connect(node(), [atom(), ...]) :: {:ok, atom()} | :error
  def connect(node, [first | _] = cookies) do
    if node in Node.list() do
      {:ok, :erlang.get_cookie(node)}
    else
      case Enum.find(cookies, &connect_with?(node, &1)) do
        nil ->
          Node.set_cookie(node, first)
          :error

        cookie ->
          if cookie == @legacy_cookie, do: warn_legacy(node)
          {:ok, cookie}
      end
    end
  end

  defp connect_with?(node, cookie) do
    Node.set_cookie(node, cookie)
    Node.connect(node) == true
  end

  defp warn_legacy(node) do
    key = {__MODULE__, :warned, node}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      IO.puts(
        :stderr,
        "\n#{IO.ANSI.yellow()}warning: #{node} accepted the public cookie " <>
          "#{@legacy_cookie}: it is running a mob from before MOB-49, and anyone who can " <>
          "reach its dist port can run code in it. Update the mob dependency and run " <>
          "`mix mob.deploy` (`--native` for iOS) without `--no-restart` to move it to this " <>
          "project's private cookie.#{IO.ANSI.reset()}"
      )
    end
  end

  @doc false
  @spec default_path(String.t()) :: String.t()
  def default_path(identifier) when is_binary(identifier) do
    digest =
      :crypto.hash(:sha256, identifier)
      |> Base.encode16(case: :lower)

    Path.join([System.user_home!(), ".mob", "dist_cookies", digest])
  end

  @doc false
  @spec load_or_create!(String.t()) :: atom()
  def load_or_create!(path) when is_binary(path) do
    case File.read(path) do
      {:ok, cookie} ->
        secure_and_parse!(path, cookie)

      {:error, :enoent} ->
        create_or_read!(path)

      {:error, reason} ->
        Mix.raise("Could not read private distribution cookie: #{:file.format_error(reason)}")
    end
  end

  # Written to a private temp file and published with a hard link, which is
  # atomic and fails if the name exists: a concurrent session either wins the
  # link or reads a complete cookie, never an empty file mid-write.
  defp create_or_read!(path) do
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    cookie = random_cookie()
    tmp = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(tmp, cookie <> "\n", [:exclusive])
      File.chmod!(tmp, 0o600)

      case :file.make_link(tmp, path) do
        :ok ->
          secure_and_parse!(path, cookie)

        {:error, :eexist} ->
          secure_and_parse!(path, File.read!(path))

        {:error, reason} ->
          Mix.raise("Could not create private distribution cookie: #{:file.format_error(reason)}")
      end
    after
      File.rm(tmp)
    end
  end

  defp secure_and_parse!(path, raw) do
    cookie = String.trim(raw)

    unless valid_cookie?(cookie) do
      Mix.raise(
        "Private distribution cookie at #{path} is invalid; " <>
          "remove it and rerun mix mob.connect to generate a replacement."
      )
    end

    File.chmod!(Path.dirname(path), 0o700)
    File.chmod!(path, 0o600)
    String.to_atom(cookie)
  end

  defp valid_cookie?(raw), do: Regex.match?(@cookie_pattern, String.trim(raw))

  defp random_cookie do
    @cookie_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
