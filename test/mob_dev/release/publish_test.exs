defmodule MobDev.Release.PublishTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.Release.Publish

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  # ── classify/1 — the contract that protects users from "exit 1" ───────

  describe "classify/1" do
    test "GitHub 'release not found' → :not_found (must trigger create)" do
      assert Publish.classify("release not found") == :not_found
      assert Publish.classify("RELEASE NOT FOUND") == :not_found
      assert Publish.classify("HTTP 404: release not found (api.github.com/...)") == :not_found
    end

    test "401 Bad credentials → :auth" do
      assert Publish.classify("HTTP 401: Bad credentials (api.github.com)") == :auth
    end

    test "403 → :auth" do
      assert Publish.classify("HTTP 403: Resource not accessible") == :auth
    end

    test "'gh auth login' suggestion in stderr → :auth" do
      assert Publish.classify("To get started with GitHub CLI, please run: gh auth login") ==
               :auth
    end

    test "HTTP 5xx → :infra (GitHub outage, not our problem)" do
      assert Publish.classify("HTTP 503: Service Unavailable") == :infra
      assert Publish.classify("HTTP 502: Bad Gateway") == :infra
      assert Publish.classify("HTTP 500: Internal Server Error") == :infra
    end

    test "network errors → :infra" do
      assert Publish.classify("dial tcp: lookup api.github.com: no such host") == :infra
      assert Publish.classify("connection refused") == :infra
      assert Publish.classify("i/o timeout") == :infra
      assert Publish.classify("network is unreachable") == :infra
    end

    test "unclassified output → :other (caller falls back to :cmd_failed)" do
      assert Publish.classify("some unrelated garbage") == :other
      assert Publish.classify("") == :other
    end

    test "precedence: not_found beats auth/infra hits in the same string" do
      # Defensive — gh has been known to print multiple lines.
      assert Publish.classify("release not found\nHTTP 401") == :not_found
    end
  end

  # ── tag_for/1, discover_assets/3 — pure-ish surface ─────────────────────

  describe "tag_for/1" do
    test "prepends otp- prefix" do
      assert Publish.tag_for("abc12345") == "otp-abc12345"
    end
  end

  describe "candidate_basenames/0 / default_repo/0" do
    test "four canonical basenames in canonical order" do
      assert Publish.candidate_basenames() == [
               "otp-android",
               "otp-android-arm32",
               "otp-ios-sim",
               "otp-ios-device"
             ]
    end

    test "default repo is GenericJam/mob" do
      assert Publish.default_repo() == "GenericJam/mob"
    end
  end

  describe "discover_assets/3" do
    test "returns only filenames the shell reports as files (preserves order)" do
      stub(MobDev.Release.ShellMock, :file?, fn path ->
        String.ends_with?(path, "otp-ios-sim-abc12345.tar.gz") or
          String.ends_with?(path, "otp-ios-device-abc12345.tar.gz")
      end)

      result = Publish.discover_assets(MobDev.Release.ShellMock, "/tmp", "abc12345")

      assert result == [
               "otp-ios-sim-abc12345.tar.gz",
               "otp-ios-device-abc12345.tar.gz"
             ]
    end

    test "returns empty list when nothing exists" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> false end)

      assert Publish.discover_assets(MobDev.Release.ShellMock, "/tmp", "abc12345") == []
    end
  end

  # ── publish/1 happy paths ──────────────────────────────────────────────

  describe "publish/1 — release already exists, no overlapping assets" do
    test "view exists + list returns unrelated + upload + verify; no create, no delete" do
      with_call_recorder()
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) ->
            {:ok, "some-other-asset.txt\n"}

          gh_view?(argv) ->
            {:ok, "title: OTP pre-built runtime abc12345\n"}

          gh_upload?(argv) ->
            {:ok, "uploaded\n"}

          true ->
            flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:ok, info} = Publish.publish(hash: "abc12345", out_dir: "/tmp")
      assert info.tag == "otp-abc12345"
      assert info.repo == "GenericJam/mob"

      calls = calls_made()
      assert Enum.any?(calls, &gh_upload?/1)
      refute Enum.any?(calls, &match?(["gh", "release", "create" | _], &1))
      refute Enum.any?(calls, &match?(["gh", "release", "delete-asset" | _], &1))
    end
  end

  describe "publish/1 — release does not exist" do
    test "view 404 → create → list (empty) → upload → verify" do
      with_call_recorder()
      all_present()

      # Track view-without-json count so the first one returns 404
      # (existence probe) and subsequent ones (list-assets) succeed.
      :ets.insert(:pub_calls, {:view_count, 0})

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) ->
            {:ok, ""}

          gh_view?(argv) ->
            n = :ets.update_counter(:pub_calls, :view_count, {2, 1})

            if n == 1 do
              {:error, {:cmd_failed, %{cmd: argv, exit: 1, output: "release not found"}}}
            else
              {:ok, "exists now\n"}
            end

          match?(["gh", "release", "create", "otp-abc12345" | _], argv) ->
            assert "--title" in argv
            assert "--notes" in argv

            assert Enum.any?(argv, &(is_binary(&1) and String.contains?(&1, "abc12345"))),
                   "title or notes should include the hash"

            {:ok, "https://github.com/.../releases/tag/otp-abc12345\n"}

          gh_upload?(argv) ->
            {:ok, "uploaded\n"}

          true ->
            flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:ok, info} = Publish.publish(hash: "abc12345", out_dir: "/tmp")
      assert info.tag == "otp-abc12345"

      assert Enum.any?(calls_made(), &match?(["gh", "release", "create" | _], &1)),
             "expected a gh release create call"
    end
  end

  describe "publish/1 — overlapping assets are deleted first" do
    test "each overlapping basename triggers a delete-asset call" do
      with_call_recorder()
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) ->
            {:ok, "otp-android-abc12345.tar.gz\notp-ios-sim-abc12345.tar.gz\n"}

          gh_view?(argv) ->
            {:ok, "title: existing\n"}

          match?(["gh", "release", "delete-asset" | _], argv) ->
            {:ok, ""}

          gh_upload?(argv) ->
            {:ok, "uploaded\n"}

          true ->
            flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:ok, _info} = Publish.publish(hash: "abc12345", out_dir: "/tmp")

      deletes =
        calls_made()
        |> Enum.filter(&match?(["gh", "release", "delete-asset" | _], &1))

      assert length(deletes) == 2

      assert Enum.any?(deletes, fn argv -> "otp-android-abc12345.tar.gz" in argv end)
      assert Enum.any?(deletes, fn argv -> "otp-ios-sim-abc12345.tar.gz" in argv end)
    end
  end

  describe "publish/1 — non-default repo" do
    test ":repo opt propagates to every gh call" do
      with_call_recorder()
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) -> {:ok, ""}
          gh_view?(argv) -> {:ok, "title: x\n"}
          gh_upload?(argv) -> {:ok, ""}
          true -> flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:ok, info} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp", repo: "myfork/mob")

      assert info.repo == "myfork/mob"

      assert Enum.all?(calls_made(), fn argv -> "myfork/mob" in argv end),
             "every gh call should carry --repo myfork/mob"
    end
  end

  # ── publish/1 preconditions ────────────────────────────────────────────

  describe "publish/1 — preconditions" do
    test "no tarballs in out_dir → precondition_failed with hint" do
      stub(MobDev.Release.ShellMock, :file?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp")

      assert msg =~ "no tarballs found"
      assert msg =~ "abc12345"
      assert msg =~ "mix mob.release.tarball"
    end

    test "explicit --assets with one missing file → precondition_failed lists missing" do
      stub(MobDev.Release.ShellMock, :file?, fn path ->
        String.ends_with?(path, "otp-android-abc12345.tar.gz")
      end)

      assert {:error, {:precondition_failed, msg}} =
               Publish.publish(
                 hash: "abc12345",
                 out_dir: "/tmp",
                 assets: ["otp-android", "otp-ios-sim"]
               )

      assert msg =~ "missing tarballs"
      assert msg =~ "otp-ios-sim-abc12345.tar.gz"
      refute msg =~ "/tmp/otp-android-abc12345.tar.gz"
    end

    test "explicit --assets accepts a full filename (skip basename normalization)" do
      with_call_recorder()

      stub(MobDev.Release.ShellMock, :file?, fn path ->
        String.ends_with?(path, "weird-name.tar.gz")
      end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) -> {:ok, ""}
          gh_view?(argv) -> {:ok, "title: x\n"}
          gh_upload?(argv) -> {:ok, ""}
          true -> flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:ok, _} =
               Publish.publish(
                 hash: "abc12345",
                 out_dir: "/tmp",
                 assets: ["weird-name.tar.gz"]
               )

      upload =
        Enum.find(calls_made(), &match?(["gh", "release", "upload" | _], &1))

      assert is_list(upload), "expected a gh release upload call to have been recorded"
      assert Enum.any?(upload, &String.ends_with?(&1, "weird-name.tar.gz"))
      refute Enum.any?(upload, &String.contains?(&1, "weird-name.tar.gz-abc12345.tar.gz"))
    end
  end

  # ── publish/1 — the headline error categories ──────────────────────────

  describe "publish/1 — gh failure classification" do
    test "401 from gh view → :auth_required with renewal hint" do
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          gh_list_assets?(argv) ->
            flunk("should not have reached list_assets: #{inspect(argv)}")

          gh_view?(argv) ->
            {:error,
             {:cmd_failed,
              %{cmd: argv, exit: 1, output: "HTTP 401: Bad credentials (api.github.com)"}}}

          true ->
            flunk("should not have reached: #{inspect(argv)}")
        end
      end)

      assert {:error, {:auth_required, hint}} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp")

      assert hint =~ "gh auth login"
    end

    test "503 from gh view → :infra_unreachable carrying the offending line" do
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          gh_list_assets?(argv) ->
            flunk("should not have reached list_assets: #{inspect(argv)}")

          gh_view?(argv) ->
            {:error,
             {:cmd_failed,
              %{cmd: argv, exit: 1, output: "HTTP 503: Service Unavailable\nretry later"}}}

          true ->
            flunk("should not have reached: #{inspect(argv)}")
        end
      end)

      assert {:error, {:infra_unreachable, detail}} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp")

      assert detail =~ "503"
    end

    test "auth failure during gh upload is reclassified (not raw cmd_failed)" do
      with_call_recorder()
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        record_call(argv)

        cond do
          gh_list_assets?(argv) ->
            {:ok, ""}

          gh_view?(argv) ->
            {:ok, "ok\n"}

          gh_upload?(argv) ->
            {:error, {:cmd_failed, %{cmd: argv, exit: 1, output: "HTTP 401: token expired"}}}

          true ->
            flunk("unexpected gh call: #{inspect(argv)}")
        end
      end)

      assert {:error, {:auth_required, _hint}} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp")
    end

    test "unclassified gh failure falls through to :cmd_failed" do
      all_present()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          gh_list_assets?(argv) ->
            flunk("unexpected: #{inspect(argv)}")

          gh_view?(argv) ->
            {:error,
             {:cmd_failed,
              %{
                cmd: argv,
                exit: 1,
                output: "weird internal go error nothing about auth or network"
              }}}

          true ->
            flunk("unexpected: #{inspect(argv)}")
        end
      end)

      assert {:error, {:cmd_failed, _}} =
               Publish.publish(hash: "abc12345", out_dir: "/tmp")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp all_present do
    stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
  end

  # Order matters: gh_list_assets? must be tested BEFORE gh_view?
  # since the list-assets call IS a `gh release view ... --json assets`.
  defp gh_view?(argv), do: match?(["gh", "release", "view", _tag | _rest], argv)

  defp gh_list_assets?(argv) do
    match?(["gh", "release", "view" | _], argv) and "--json" in argv and "assets" in argv
  end

  defp gh_upload?(argv), do: match?(["gh", "release", "upload" | _], argv)

  defp with_call_recorder do
    case :ets.whereis(:pub_calls) do
      :undefined -> :ets.new(:pub_calls, [:public, :named_table, :ordered_set])
      _ -> :ets.delete_all_objects(:pub_calls)
    end
  end

  defp record_call(argv) do
    n = :ets.update_counter(:pub_calls, :__count__, {2, 1}, {:__count__, 0})
    :ets.insert(:pub_calls, {n, argv})
  end

  defp calls_made do
    :ets.tab2list(:pub_calls)
    |> Enum.reject(fn {k, _} -> not is_integer(k) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
