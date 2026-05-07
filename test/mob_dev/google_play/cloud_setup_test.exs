defmodule MobDev.GooglePlay.CloudSetupTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay.CloudSetup

  # ── build_enable_api_url/2 ───────────────────────────────────────────────────

  describe "build_enable_api_url/2" do
    test "builds correct Service Usage API URL" do
      url = CloudSetup.build_enable_api_url("my-project-123", "androidpublisher.googleapis.com")

      assert url ==
               "https://serviceusage.googleapis.com/v1/projects/my-project-123/services/androidpublisher.googleapis.com:enable"
    end

    test "encodes the project ID in the path" do
      url = CloudSetup.build_enable_api_url("some-project", "some.api.googleapis.com")
      assert url =~ "/projects/some-project/"
    end

    test "appends :enable action" do
      url = CloudSetup.build_enable_api_url("proj", "api.googleapis.com")
      assert String.ends_with?(url, ":enable")
    end
  end

  # ── parse_projects_response/1 ────────────────────────────────────────────────

  describe "parse_projects_response/1" do
    test "returns projects list from a valid response" do
      resp = %{
        "projects" => [
          %{"projectId" => "project-a", "displayName" => "Project A"},
          %{"projectId" => "project-b", "displayName" => "Project B"}
        ]
      }

      result = CloudSetup.parse_projects_response(resp)
      assert length(result) == 2
      assert Enum.any?(result, &(&1["projectId"] == "project-a"))
    end

    test "returns empty list when projects key is missing" do
      assert CloudSetup.parse_projects_response(%{}) == []
    end

    test "returns empty list when projects is empty" do
      assert CloudSetup.parse_projects_response(%{"projects" => []}) == []
    end

    test "passes through project map fields unchanged" do
      project = %{"projectId" => "my-proj", "displayName" => "My Project", "state" => "ACTIVE"}
      resp = %{"projects" => [project]}
      [result] = CloudSetup.parse_projects_response(resp)
      assert result == project
    end
  end

  # ── save_key_file/2 ─────────────────────────────────────────────────────────

  describe "save_key_file/2" do
    test "decodes base64 and writes JSON to ~/.google_play/{filename}.json" do
      json = Jason.encode!(%{"type" => "service_account", "project_id" => "test"})
      b64 = Base.encode64(json)
      filename = "test-key-#{:erlang.unique_integer([:positive])}"

      assert {:ok, path} = CloudSetup.save_key_file(b64, filename)

      on_exit(fn -> File.rm(path) end)

      assert String.ends_with?(path, "#{filename}.json")
      assert File.exists?(path)
      assert File.read!(path) == json
    end

    test "sets file permissions to 600" do
      json = "{}"
      b64 = Base.encode64(json)
      filename = "test-perms-#{:erlang.unique_integer([:positive])}"

      {:ok, path} = CloudSetup.save_key_file(b64, filename)
      on_exit(fn -> File.rm(path) end)

      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "returns error for invalid base64" do
      assert {:error, _} = CloudSetup.save_key_file("not-valid-base64!!!", "test-key")
    end

    test "saves to ~/.google_play/ directory" do
      b64 = Base.encode64("{}")
      filename = "test-dir-#{:erlang.unique_integer([:positive])}"

      {:ok, path} = CloudSetup.save_key_file(b64, filename)
      on_exit(fn -> File.rm(path) end)

      expected_dir = Path.expand("~/.google_play")
      assert Path.dirname(path) == expected_dir
    end
  end
end
