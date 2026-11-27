defmodule MobDev.DownloadTest do
  use ExUnit.Case, async: true

  alias MobDev.Download

  @sha_of_hello "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

  describe "verify_sha256/2" do
    @tag :tmp_dir
    test "keeps a file whose hash matches the pin", %{tmp_dir: tmp} do
      path = Path.join(tmp, "asset.tar.gz")
      File.write!(path, "hello")

      assert :ok = Download.verify_sha256(path, @sha_of_hello)
      assert File.read!(path) == "hello"
    end

    @tag :tmp_dir
    test "rejects and deletes a file whose hash does not match, naming both hashes",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "asset.tar.gz")
      File.write!(path, "hello, tampered")
      {:ok, actual} = Download.sha256_file(path)

      assert {:error, msg} = Download.verify_sha256(path, @sha_of_hello)
      assert msg =~ @sha_of_hello
      assert msg =~ actual
      refute File.exists?(path)
    end

    @tag :tmp_dir
    test "a missing file is an error, not a pass", %{tmp_dir: tmp} do
      assert {:error, _} = Download.verify_sha256(Path.join(tmp, "nope"), @sha_of_hello)
    end
  end

  describe "pin/1" do
    test "returns the pinned sha256 for a known asset URL" do
      [url | _] = Map.keys(MobDev.Download.Pins.all())
      assert {:ok, sha} = Download.pin(url)
      assert sha =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "refuses an unpinned URL before anything is fetched" do
      assert {:error, msg} = Download.pin("https://example.invalid/unpinned.tar.gz")
      assert msg =~ "no pinned sha256"
    end
  end

  describe "fetch_verified/3" do
    @tag :tmp_dir
    test "a fetched file with the wrong hash is removed and reported", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src.bin")
      File.write!(src, "not what was pinned")
      dest = Path.join(tmp, "dest.bin")

      assert {:error, msg} = Download.fetch_verified("file://" <> src, dest, @sha_of_hello)
      assert msg =~ @sha_of_hello
      refute File.exists?(dest)
    end

    @tag :tmp_dir
    test "a fetched file with the pinned hash is kept", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src.bin")
      File.write!(src, "hello")
      dest = Path.join(tmp, "dest.bin")

      assert :ok = Download.fetch_verified("file://" <> src, dest, @sha_of_hello)
      assert File.read!(dest) == "hello"
    end
  end

  describe "verified?/2 + mark_verified/2" do
    @tag :tmp_dir
    test "a directory is trusted only after it was marked with the same sha", %{tmp_dir: tmp} do
      refute Download.verified?(tmp, @sha_of_hello)

      assert :ok = Download.mark_verified(tmp, @sha_of_hello)
      assert Download.verified?(tmp, @sha_of_hello)
      refute Download.verified?(tmp, String.duplicate("0", 64))
    end

    test "nil never verifies" do
      refute Download.verified?(System.tmp_dir!(), nil)
    end
  end

  describe "untar/3 — well-formed archives" do
    @tag :tmp_dir
    test "extracts regular files and in-tree symlinks", %{tmp_dir: tmp} do
      tarball =
        tar(tmp, [
          {:file, "top/lib/a.txt", "a"},
          {:symlink, "top/lib/link", "a.txt"},
          {:symlink, "top/up", "lib/a.txt"}
        ])

      dest = mkdir(tmp, "out")
      assert :ok = Download.untar(tarball, dest)
      assert File.read!(Path.join(dest, "top/lib/a.txt")) == "a"
      assert File.read!(Path.join(dest, "top/lib/link")) == "a"
    end

    @tag :tmp_dir
    test "strip_components drops the top-level directory", %{tmp_dir: tmp} do
      tarball = tar(tmp, [{:file, "top/erts-1/x", "x"}, {:file, "stray", "dropped by strip"}])
      dest = mkdir(tmp, "out")

      assert :ok = Download.untar(tarball, dest, strip_components: 1)
      assert File.read!(Path.join(dest, "erts-1/x")) == "x"
      refute File.exists?(Path.join(dest, "stray"))
    end
  end

  describe "untar/3 — unsafe archives are refused" do
    @tag :tmp_dir
    test "an entry with a ../ segment", %{tmp_dir: tmp} do
      tarball = tar(tmp, [{:file, "top/ok", "ok"}, {:file, "top/../../escaped", "x"}])
      dest = mkdir(tmp, "a/b/out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "has a .. segment"
      refute File.exists?(Path.join(tmp, "a/escaped"))

      refute File.exists?(Path.join(dest, "top/ok")),
             "nothing is extracted from a refused archive"
    end

    @tag :tmp_dir
    test "an absolute entry", %{tmp_dir: tmp} do
      target = Path.join(tmp, "abs-target")
      tarball = tar(tmp, [{:file, target, "x"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "absolute"
      refute File.exists?(target)
    end

    @tag :tmp_dir
    test "a relative symlink that climbs out of the destination", %{tmp_dir: tmp} do
      tarball = tar(tmp, [{:symlink, "top/evil", "../../secret"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "top/evil"
      refute File.exists?(Path.join(dest, "top/evil")) or symlink?(Path.join(dest, "top/evil"))
    end

    @tag :tmp_dir
    test "a symlink that escapes only once the top directory is stripped", %{tmp_dir: tmp} do
      # Inside the archive root, `top/sibling -> ../outside` stays in bounds;
      # after --strip-components=1 it points at dest's parent.
      tarball = tar(tmp, [{:file, "top/a", "a"}, {:symlink, "top/sibling", "../outside"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest, strip_components: 1)
      assert msg =~ "sibling"
      refute symlink?(Path.join(dest, "sibling"))
    end

    @tag :tmp_dir
    test "an absolute symlink", %{tmp_dir: tmp} do
      tarball = tar(tmp, [{:symlink, "top/passwd", "/etc/passwd"}])
      dest = mkdir(tmp, "out")

      assert {:error, _} = Download.untar(tarball, dest)
      refute symlink?(Path.join(dest, "top/passwd"))
    end

    @tag :tmp_dir
    test "a symlink chain that escapes through an earlier in-tree link", %{tmp_dir: tmp} do
      # `top/d/up -> ..` is in bounds (resolves to top/); `top/w -> d/up/../..`
      # looks in bounds lexically but resolves through `up` to dest's parent.
      tarball =
        tar(tmp, [
          {:file, "top/d/f", "f"},
          {:symlink, "top/d/up", ".."},
          {:symlink, "top/w", "d/up/../.."}
        ])

      dest = mkdir(tmp, "out")
      assert {:error, msg} = Download.untar(tarball, dest, strip_components: 1)
      assert msg =~ "w"
    end

    @tag :tmp_dir
    test "an entry written through a symlinked directory", %{tmp_dir: tmp} do
      tarball =
        tar(tmp, [
          {:symlink, "top/d", "."},
          {:file, "top/d/f", "through the link"}
        ])

      dest = mkdir(tmp, "out")
      assert {:error, msg} = Download.untar(tarball, dest)
      # Refused by the member-list check before tar runs, not by whatever the
      # platform's tar happens to do with it.
      assert msg =~ "is stored beneath a symlink"
      refute File.exists?(Path.join(dest, "top/f"))
    end

    @tag :tmp_dir
    test "a member that lands beneath a symlink only once the top directory is stripped",
         %{tmp_dir: tmp} do
      # `a/link` and `b/link/f` are unrelated in the archive; both become
      # `link…` after --strip-components=1.
      tarball = tar(tmp, [{:symlink, "a/link", "."}, {:file, "b/link/f", "through the link"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest, strip_components: 1)
      assert msg =~ "is stored beneath a symlink"
    end

    @tag :tmp_dir
    test "a member beneath a symlink when only one of them has a ./ prefix", %{tmp_dir: tmp} do
      # tar counts `./` as a component: with --strip-components=1 both land at
      # `a/link…`, though the unstripped names sit at different depths.
      tarball = tar(tmp, [{:symlink, "./a/link", "."}, {:file, "b/a/link/x", "x"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest, strip_components: 1)
      assert msg =~ "is stored beneath a symlink"
    end

    @tag :tmp_dir
    test "a member beneath a symlink if a tar ignores the ./ prefix when stripping",
         %{tmp_dir: tmp} do
      # Read without counting `./`, `./x/link/f` lands at `link/f`, beneath
      # `b/link`; both readings are checked.
      tarball = tar(tmp, [{:symlink, "b/link", "."}, {:file, "./x/link/f", "x"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest, strip_components: 1)
      assert msg =~ "is stored beneath a symlink"
    end

    @tag :tmp_dir
    test "a member beneath a symlink that differs only in case", %{tmp_dir: tmp} do
      tarball = tar(tmp, [{:symlink, "top/Link", "."}, {:file, "top/link/f", "through the link"}])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "is stored beneath a symlink"
    end

    @tag :tmp_dir
    test "an escaping symlink inside a directory shipped without read permission",
         %{tmp_dir: tmp} do
      tarball =
        raw_tar(tmp, [
          {"top/", ?5, 0o755, ""},
          {"top/hidden/", ?5, 0o311, ""},
          {"top/hidden/evil", ?2, 0o777, "/etc"}
        ])

      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "evil"
      refute symlink?(Path.join(dest, "top/hidden/evil"))
      File.chmod(Path.join(dest, "top/hidden"), 0o755)
    end

    @tag :tmp_dir
    test "a hard link entry", %{tmp_dir: tmp} do
      src = mkdir(tmp, "src")
      File.write!(Path.join(src, "a"), "a")
      File.ln!(Path.join(src, "a"), Path.join(src, "b"))
      tarball = Path.join(tmp, "hard.tar.gz")
      {_, 0} = System.cmd("tar", ["czf", tarball, "-C", src, "a", "b"])
      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.untar(tarball, dest)
      assert msg =~ "link"
    end
  end

  describe "unzip/2" do
    @tag :tmp_dir
    test "extracts a well-formed zip", %{tmp_dir: tmp} do
      zip = zip(tmp, [{~c"jni/arm64-v8a/lib.so", "so"}])
      dest = mkdir(tmp, "out")

      assert :ok = Download.unzip(zip, dest)
      assert File.read!(Path.join(dest, "jni/arm64-v8a/lib.so")) == "so"
    end

    @tag :tmp_dir
    test "refuses an entry with a ../ segment", %{tmp_dir: tmp} do
      zip = zip(tmp, [{~c"ok", "ok"}, {~c"../../escaped", "x"}])
      dest = mkdir(tmp, "a/b/out")

      assert {:error, msg} = Download.unzip(zip, dest)
      assert msg =~ "has a .. segment"
      refute File.exists?(Path.join(tmp, "a/escaped"))
      refute File.exists?(Path.join(dest, "ok"))
    end

    @tag :tmp_dir
    test "refuses an absolute entry", %{tmp_dir: tmp} do
      # :zip.create strips a leading "/", so store a same-length placeholder
      # name and rewrite it in both the local and central headers.
      zip = zip(tmp, [{~c"_tmp_mob553_abs", "x"}])

      File.write!(
        zip,
        :binary.replace(File.read!(zip), "_tmp_mob553_abs", "/tmp/mob553_abs", [:global])
      )

      dest = mkdir(tmp, "out")

      assert {:error, msg} = Download.unzip(zip, dest)
      assert msg =~ "absolute"
      refute File.exists?("/tmp/mob553_abs")
    end
  end

  describe "check_symlinks/1" do
    @tag :tmp_dir
    test "a directory it cannot list is an error, not an empty directory", %{tmp_dir: tmp} do
      hidden = mkdir(tmp, "root/hidden")
      File.ln_s!("/etc", Path.join(hidden, "evil"))
      File.chmod!(hidden, 0o311)

      try do
        assert {:error, msg} = Download.check_symlinks(Path.join(tmp, "root"))
        assert msg =~ "could not inspect"
      after
        File.chmod(hidden, 0o755)
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp mkdir(tmp, rel) do
    dir = Path.join(tmp, rel)
    File.mkdir_p!(dir)
    dir
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  # Builds a .tar.gz whose member names are exactly `name` (no sanitising),
  # so unsafe names reach the extractor exactly as stored.
  defp tar(tmp, entries) do
    scratch = mkdir(tmp, "scratch-#{System.unique_integer([:positive])}")
    tarball = Path.join(tmp, "t-#{System.unique_integer([:positive])}.tar.gz")
    {:ok, fd} = :erl_tar.open(String.to_charlist(tarball), [:write, :compressed])

    entries
    |> Enum.with_index()
    |> Enum.each(fn {entry, i} ->
      src = Path.join(scratch, "e#{i}")

      name =
        case entry do
          {:file, name, body} ->
            File.write!(src, body)
            name

          {:symlink, name, target} ->
            File.ln_s!(target, src)
            name
        end

      :ok = :erl_tar.add(fd, String.to_charlist(src), String.to_charlist(name), [])
    end)

    :ok = :erl_tar.close(fd)
    tarball
  end

  # A .tar.gz built header by header, for member modes and types erl_tar
  # can't be told to write. Entries are `{name, typeflag, mode, linkname}`.
  defp raw_tar(tmp, entries) do
    body =
      Enum.map(entries, fn {name, type, mode, link} ->
        header =
          [
            pad(name, 100),
            octal(mode, 8),
            octal(0, 8),
            octal(0, 8),
            octal(0, 12),
            octal(0, 12),
            "        ",
            <<type>>,
            pad(link, 100),
            "ustar\0",
            "00",
            pad("", 247)
          ]
          |> IO.iodata_to_binary()

        sum = header |> :binary.bin_to_list() |> Enum.sum()
        <<pre::binary-size(148), _::binary-size(8), post::binary>> = header
        pre <> octal(sum, 7) <> " " <> post
      end)

    path = Path.join(tmp, "raw-#{System.unique_integer([:positive])}.tar.gz")
    File.write!(path, :zlib.gzip(IO.iodata_to_binary([body, :binary.copy(<<0>>, 1024)])))
    path
  end

  defp pad(s, n), do: s <> :binary.copy(<<0>>, n - byte_size(s))

  defp octal(n, width) do
    digits = Integer.to_string(n, 8)
    String.duplicate("0", width - 1 - byte_size(digits)) <> digits <> <<0>>
  end

  defp zip(tmp, entries) do
    path = Path.join(tmp, "z-#{System.unique_integer([:positive])}.zip")
    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end
end
