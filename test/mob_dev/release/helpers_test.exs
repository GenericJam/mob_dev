defmodule MobDev.Release.HelpersTest do
  use ExUnit.Case, async: false
  # async: false because some tests poke env vars + cwd. The cost of one
  # serial test module is small; the safety of not racing other modules
  # on shared env state is worth it.

  alias MobDev.Release.Helpers

  # ── parse_git_hash (pure) ──────────────────────────────────────────────

  describe "parse_git_hash/1" do
    test "trims trailing newline and returns 8-char hash" do
      assert Helpers.parse_git_hash("abcdef12\n") == {:ok, "abcdef12"}
    end

    test "trims surrounding whitespace" do
      assert Helpers.parse_git_hash("  abcdef12\n\n") == {:ok, "abcdef12"}
    end

    test "rejects 7-char (git's pre-pinned default — exactly the drift we want to catch)" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_git_hash("abcdef1\n")
    end

    test "rejects 10-char (git's modern collision-grown default)" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_git_hash("abcdef1234\n")
    end

    test "rejects non-hex content" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_git_hash("not-a-hash\n")
    end

    test "rejects empty input" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_git_hash("")
    end
  end

  # ── parse_erts_version (pure) ──────────────────────────────────────────

  describe "parse_erts_version/1" do
    test "extracts version from canonical erts/vsn.mk content" do
      content = """
      # ERTS version. Bumped when erlang/otp gets a new ERTS.
      VSN = 17.0
      """

      assert Helpers.parse_erts_version(content) == {:ok, "17.0"}
    end

    test "tolerates tabs around the `=`" do
      assert Helpers.parse_erts_version("VSN\t=\t16.3\n") == {:ok, "16.3"}
    end

    test "tolerates leading whitespace on the line" do
      assert Helpers.parse_erts_version("    VSN = 17.0\n") == {:ok, "17.0"}
    end

    test "extracts only the first match if multiple appear" do
      # Defensive — vsn.mk historically only had one VSN line, but if
      # OTP ever adds e.g. SUBVSN we want to pick the canonical one.
      assert Helpers.parse_erts_version("VSN = 17.0\nSUBVSN = 0.1\n") == {:ok, "17.0"}
    end

    test "returns parse_failed when no VSN= line is present" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_erts_version("# no version here\n")
    end

    test "returns parse_failed for empty content" do
      assert {:error, {:parse_failed, _}} = Helpers.parse_erts_version("")
    end
  end

  # ── git_hash (side-effecting; uses a tmpdir git repo) ─────────────────

  describe "git_hash/1 with a real git fixture" do
    setup do
      tmp = mk_tmpdir("git_hash")

      # Sanitize the ambient git environment. When the suite runs from inside a
      # git hook (e.g. `.githooks/pre-push`), git exports GIT_DIR / GIT_WORK_TREE
      # / GIT_INDEX_FILE / … into the environment; the fixture's git commands
      # would inherit them and operate on the *outer* repo instead of `tmp`
      # (`git add` matches nothing → `git commit` exits non-zero → setup crashes).
      # nil removes the var for the child process. The stable author/committer
      # identity keeps the commit reproducible within a run (we assert the hash
      # is 8-char hex, not a pinned value).
      git_env = [
        {"GIT_DIR", nil},
        {"GIT_WORK_TREE", nil},
        {"GIT_INDEX_FILE", nil},
        {"GIT_OBJECT_DIRECTORY", nil},
        {"GIT_COMMON_DIR", nil},
        {"GIT_PREFIX", nil},
        {"GIT_AUTHOR_NAME", "test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ]

      File.mkdir_p!(tmp)
      {_, 0} = System.cmd("git", ["init", "--quiet", "-b", "main", tmp], env: git_env)
      File.write!(Path.join(tmp, "vsn.mk"), "VSN = 17.0\n")
      {_, 0} = System.cmd("git", ["-C", tmp, "add", "vsn.mk"], env: git_env)

      {_, 0} =
        System.cmd("git", ["-C", tmp, "commit", "-m", "init", "--no-gpg-sign", "--quiet"],
          env: git_env
        )

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "returns an 8-char hex hash for a valid checkout", %{tmp: tmp} do
      assert {:ok, hash} = Helpers.git_hash(tmp)
      assert String.length(hash) == 8
      assert Regex.match?(~r/^[0-9a-f]{8}$/, hash)
    end

    test "returns precondition_failed when path is not a git repo" do
      tmp = mk_tmpdir("git_hash_notgit")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, {:precondition_failed, msg}} = Helpers.git_hash(tmp)
      assert msg =~ "not a git checkout"
    end
  end

  # ── erts_version (side-effecting; uses a tmpdir fixture) ──────────────

  describe "erts_version/1 with a real erts/vsn.mk fixture" do
    test "reads VSN from a real vsn.mk on disk" do
      tmp = mk_tmpdir("erts_vsn")
      File.mkdir_p!(Path.join(tmp, "erts"))
      File.write!(Path.join([tmp, "erts", "vsn.mk"]), "VSN = 17.0\n")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert Helpers.erts_version(tmp) == {:ok, "17.0"}
    end

    test "returns fs_failed when vsn.mk is missing" do
      tmp = mk_tmpdir("erts_vsn_missing")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, {:fs_failed, %{reason: :enoent}}} = Helpers.erts_version(tmp)
    end

    test "returns parse_failed when vsn.mk content is malformed" do
      tmp = mk_tmpdir("erts_vsn_malformed")
      File.mkdir_p!(Path.join(tmp, "erts"))
      File.write!(Path.join([tmp, "erts", "vsn.mk"]), "no version line here\n")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, {:parse_failed, _}} = Helpers.erts_version(tmp)
    end
  end

  # ── elixir_lib_dir (calls into BEAM internals; unmocked) ──────────────

  describe "elixir_lib_dir/0" do
    test "returns a path whose elixir/ ebin lives at the expected place" do
      assert {:ok, parent} = Helpers.elixir_lib_dir()
      assert File.dir?(Path.join([parent, "elixir", "ebin"]))
    end
  end

  # ── bundle_elixir_stdlib (filesystem fixture) ─────────────────────────

  describe "bundle_elixir_stdlib/2" do
    setup do
      stage = mk_tmpdir("stage")
      lib = mk_tmpdir("elixir_lib")

      # Build a fake host-elixir lib layout: elixir/ebin, logger/ebin,
      # eex/ebin, each with a stub .beam file we can verify got copied.
      for app <- ~w(elixir logger eex) do
        ebin = Path.join([lib, app, "ebin"])
        File.mkdir_p!(ebin)
        File.write!(Path.join(ebin, "#{app}.beam"), "FAKE-BEAM-#{app}")
      end

      on_exit(fn ->
        File.rm_rf!(stage)
        File.rm_rf!(lib)
      end)

      %{stage: stage, lib: lib}
    end

    test "copies elixir + logger + eex ebins into stage/lib/<app>/ebin", %{stage: stage, lib: lib} do
      assert {:ok, dirs} = Helpers.bundle_elixir_stdlib(stage, lib)

      assert length(dirs) == 3

      for app <- ~w(elixir logger eex) do
        dst = Path.join([stage, "lib", app, "ebin"])
        assert File.dir?(dst), "expected #{dst} to exist"
        beam = Path.join(dst, "#{app}.beam")
        assert File.read!(beam) == "FAKE-BEAM-#{app}"
      end
    end

    test "returns fs_failed if elixir lib dir doesn't exist" do
      assert {:error, {:fs_failed, %{reason: :enoent}}} =
               Helpers.bundle_elixir_stdlib("/tmp/whatever", "/tmp/nonexistent_lib_xyz")
    end

    test "returns fs_failed if an expected sub-app is missing", %{stage: stage, lib: lib} do
      # Remove logger from the lib — bundle should fail loudly with the
      # missing path identified.
      File.rm_rf!(Path.join(lib, "logger"))

      assert {:error, {:fs_failed, %{path: path, reason: :enoent}}} =
               Helpers.bundle_elixir_stdlib(stage, lib)

      assert path =~ "logger"
    end
  end

  # ── default_otp_src / default_out_dir (env-aware) ─────────────────────

  describe "default_otp_src/0" do
    test "respects OTP_SRC env var when set" do
      System.put_env("OTP_SRC", "/custom/otp/path")

      try do
        assert Helpers.default_otp_src() == "/custom/otp/path"
      after
        System.delete_env("OTP_SRC")
      end
    end

    test "falls back to ~/code/otp when OTP_SRC is unset" do
      System.delete_env("OTP_SRC")
      expected = Path.join(System.user_home!(), "code/otp")
      assert Helpers.default_otp_src() == expected
    end
  end

  describe "default_out_dir/0" do
    test "respects OUT_DIR env var when set" do
      System.put_env("OUT_DIR", "/some/out")

      try do
        assert Helpers.default_out_dir() == "/some/out"
      after
        System.delete_env("OUT_DIR")
      end
    end

    test "falls back to /tmp when unset" do
      System.delete_env("OUT_DIR")
      assert Helpers.default_out_dir() == "/tmp"
    end
  end

  # ── resolve_release_env (composite) ───────────────────────────────────

  describe "resolve_release_env/1" do
    setup do
      tmp = mk_tmpdir("resolve")
      File.mkdir_p!(Path.join(tmp, "erts"))
      File.write!(Path.join([tmp, "erts", "vsn.mk"]), "VSN = 17.0\n")

      # Pre-supply HASH so we don't depend on a real git repo here.
      System.put_env("HASH", "deadbeef")

      on_exit(fn ->
        File.rm_rf!(tmp)
        System.delete_env("HASH")
        System.delete_env("OTP_SRC")
        System.delete_env("OUT_DIR")
        System.delete_env("ERTS_VSN")
      end)

      %{tmp: tmp}
    end

    test "honours explicit opts over env over defaults", %{tmp: tmp} do
      assert {:ok, env} =
               Helpers.resolve_release_env(
                 otp_src: tmp,
                 hash: "feedface",
                 erts_vsn: "17.99",
                 out_dir: "/some/out"
               )

      assert env.otp_src == tmp
      assert env.hash == "feedface"
      assert env.erts_vsn == "17.99"
      assert env.out_dir == "/some/out"
      # elixir_lib is resolved from `:code.lib_dir(:elixir)`; we don't
      # pin the absolute path (varies per machine) but we do verify
      # it's a real directory containing elixir/ebin — the contract
      # downstream tarball_*.sh depends on.
      assert File.dir?(Path.join([env.elixir_lib, "elixir", "ebin"]))
    end

    test "falls back to env vars when opts are unset", %{tmp: tmp} do
      System.put_env("OTP_SRC", tmp)
      System.put_env("ERTS_VSN", "16.3")
      System.put_env("OUT_DIR", "/some/other/out")

      assert {:ok, env} = Helpers.resolve_release_env()
      assert env.otp_src == tmp
      assert env.hash == "deadbeef"
      assert env.erts_vsn == "16.3"
      assert env.out_dir == "/some/other/out"
    end

    test "propagates the first error encountered" do
      System.delete_env("HASH")
      # Point at a directory with no git + no erts/vsn.mk — git_hash
      # should fail first.
      tmp = mk_tmpdir("resolve_fail")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, {:precondition_failed, msg}} = Helpers.resolve_release_env(otp_src: tmp)
      assert msg =~ "not a git checkout"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp mk_tmpdir(label) do
    Path.join(System.tmp_dir!(), "mob_dev_release_#{label}_#{System.unique_integer([:positive])}")
  end
end
