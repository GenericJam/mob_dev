defmodule MobDev.Release.ErrorsTest do
  use ExUnit.Case, async: true

  alias MobDev.Release.Errors

  describe "constructors" do
    test "precondition/1 builds a precondition_failed tag" do
      assert Errors.precondition("OTP_SRC missing") ==
               {:error, {:precondition_failed, "OTP_SRC missing"}}
    end

    test "cmd_failed/3 packages cmd + exit + output" do
      assert {:error, {:cmd_failed, %{cmd: ["clang", "-c"], exit: 1, output: "oops\n"}}} =
               Errors.cmd_failed(["clang", "-c"], 1, "oops\n")
    end

    test "cmd_failed/3 truncates oversize output" do
      huge = String.duplicate("x", 10_000)
      {:error, {:cmd_failed, %{output: truncated}}} = Errors.cmd_failed(["foo"], 1, huge)

      assert byte_size(truncated) < byte_size(huge)
      assert truncated =~ "truncated, full output was 10000 bytes"
    end

    test "parse_failed/2 captures input + expected" do
      assert {:error, {:parse_failed, %{input: "VSN=", expected: "VSN = <version>"}}} =
               Errors.parse_failed("VSN=", "VSN = <version>")
    end

    test "fs_failed/2 captures path + posix atom" do
      assert {:error, {:fs_failed, %{path: "/tmp/nope", reason: :enoent}}} =
               Errors.fs_failed("/tmp/nope", :enoent)
    end

    test "infra_unreachable/1 wraps an opaque detail" do
      assert Errors.infra_unreachable(503) == {:error, {:infra_unreachable, 503}}
    end

    test "auth_required/1 carries a hint" do
      assert Errors.auth_required("run gh auth login") ==
               {:error, {:auth_required, "run gh auth login"}}
    end
  end

  describe "format/1 produces actionable strings" do
    # The point of the format/1 contract is "the caller can paste this
    # into Mix.raise/1 and the developer knows what to do next." These
    # tests pin that contract.

    test "precondition_failed prefixes with 'precondition failed —'" do
      assert Errors.format({:error, {:precondition_failed, "no NDK"}}) ==
               "precondition failed — no NDK"
    end

    test "cmd_failed includes the argv + exit + output" do
      err = Errors.cmd_failed(["clang", "-c", "x.c"], 1, "fatal: 'x.c' missing\n")
      out = Errors.format(err)

      assert out =~ "command failed (exit 1)"
      assert out =~ "clang -c x.c"
      assert out =~ "fatal: 'x.c' missing"
    end

    test "parse_failed names the expected shape" do
      err = Errors.parse_failed("VSN=", "a line of the form `VSN = <version>`")
      out = Errors.format(err)

      assert out =~ "parse failed"
      assert out =~ "VSN = <version>"
    end

    test "fs_failed includes the posix reason verbatim" do
      err = Errors.fs_failed("/tmp/nope", :eacces)
      assert Errors.format(err) == "filesystem error at /tmp/nope: eacces"
    end

    test "infra_unreachable inspects the detail (HTTP code / transport tuple / etc)" do
      out = Errors.format(Errors.infra_unreachable({:http, 503, "Service Unavailable"}))

      assert out =~ "external infrastructure unreachable"
      assert out =~ "503"
    end

    test "auth_required prefixes with 'authentication required —'" do
      assert Errors.format(Errors.auth_required("run gh auth login")) ==
               "authentication required — run gh auth login"
    end
  end

  describe "pattern matching at the call site" do
    # The whole point of tagged categories is so the Mix task can do a
    # `case` over the category and produce different remediation
    # advice. Lock down that the categories actually pattern-match.

    test "categories are atoms, suitable for `case` matching" do
      errors = [
        Errors.precondition("x"),
        Errors.cmd_failed(["x"], 1, ""),
        Errors.parse_failed("x", "y"),
        Errors.fs_failed("/x", :enoent),
        Errors.infra_unreachable(:ok),
        Errors.auth_required("x")
      ]

      categories =
        for {:error, {cat, _}} <- errors do
          cat
        end

      assert categories ==
               [
                 :precondition_failed,
                 :cmd_failed,
                 :parse_failed,
                 :fs_failed,
                 :infra_unreachable,
                 :auth_required
               ]
    end
  end
end
