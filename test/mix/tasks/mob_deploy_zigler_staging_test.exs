defmodule Mix.Tasks.Mob.DeployZiglerStagingTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mob.Deploy

  @staging_env "ZIGLER_STAGING_ROOT"
  @module_stage "Elixir.Example.Nifs.GhosttyVt"

  setup do
    previous_staging_root = System.fetch_env(@staging_env)
    System.delete_env(@staging_env)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "mob_deploy_zigler_staging_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      restore_env(previous_staging_root)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "native stages stay isolated across checkouts and cwd changes", %{tmp: tmp} do
    checkout_a = Path.join(tmp, "checkout-a")
    checkout_b = Path.join(tmp, "checkout-b")
    build_path_a = Path.join(checkout_a, "_build/dev")
    build_path_b = Path.join(checkout_b, "_build/dev")
    staging_root_a = Path.join(build_path_a, "zigler-staging")
    staging_root_b = Path.join(build_path_b, "zigler-staging")
    staged_build_a = Path.join([staging_root_a, @module_stage, "build.zig"])
    staged_build_b = Path.join([staging_root_b, @module_stage, "build.zig"])
    include_a = Path.join(checkout_a, "native/ghostty/include")
    include_b = Path.join(checkout_b, "native/ghostty/include")

    File.mkdir_p!(include_a)
    File.mkdir_p!(include_b)

    compiler_a = fn "compile", args ->
      assert args == ["--force"]
      assert System.fetch_env!(@staging_env) == staging_root_a
      File.mkdir_p!(Path.dirname(staged_build_a))
      File.write!(staged_build_a, include_a)
      :ok
    end

    assert :built_a =
             Deploy.with_zigler_staging(
               true,
               fn ->
                 assert File.read!(staged_build_a) == include_a
                 :built_a
               end,
               build_path: build_path_a,
               compiler: compiler_a
             )

    File.rm_rf!(checkout_a)

    compiler_b = fn "compile", args ->
      assert args == ["--force"]
      assert System.fetch_env!(@staging_env) == staging_root_b
      refute System.fetch_env!(@staging_env) == staging_root_a
      File.mkdir_p!(Path.dirname(staged_build_b))
      File.write!(staged_build_b, include_b)
      :ok
    end

    assert :built_b =
             Deploy.with_zigler_staging(
               true,
               fn ->
                 File.cd!(tmp, fn ->
                   assert System.fetch_env!(@staging_env) == staging_root_b
                   assert File.read!(staged_build_b) == include_b
                   :built_b
                 end)
               end,
               build_path: build_path_b,
               compiler: compiler_b
             )

    refute File.exists?(checkout_a)
    assert File.read!(staged_build_b) == include_b
    refute File.read!(staged_build_b) =~ checkout_a
    assert System.fetch_env(@staging_env) == :error
  end

  test "native compile honors an explicit staging root and restores it afterward", %{tmp: tmp} do
    explicit_root = Path.join(tmp, "explicit-zigler-stage")
    System.put_env(@staging_env, explicit_root)

    compiler = fn "compile", args ->
      assert args == ["--force"]
      assert File.dir?(explicit_root)
      assert System.fetch_env!(@staging_env) == explicit_root
      :ok
    end

    assert :native_operation =
             Deploy.with_zigler_staging(
               true,
               fn ->
                 assert System.fetch_env!(@staging_env) == explicit_root
                 :native_operation
               end,
               build_path: Path.join(tmp, "ignored-build-path"),
               compiler: compiler
             )

    assert System.fetch_env!(@staging_env) == explicit_root
  end

  test "native compile restores an unset staging root when the build raises", %{tmp: tmp} do
    assert_raise RuntimeError, "injected native failure", fn ->
      Deploy.with_zigler_staging(true, fn -> raise "injected native failure" end,
        build_path: Path.join(tmp, "_build/dev"),
        compiler: fn "compile", ["--force"] -> :ok end
      )
    end

    assert System.fetch_env(@staging_env) == :error
  end

  test "fast deploy remains incremental and does not create or change a staging root", %{tmp: tmp} do
    build_path = Path.join(tmp, "_build/dev")
    existing_root = Path.join(tmp, "existing-explicit-root")
    System.put_env(@staging_env, existing_root)

    compiler = fn "compile", args ->
      assert args == []
      assert System.fetch_env!(@staging_env) == existing_root
      :ok
    end

    assert :fast_operation =
             Deploy.with_zigler_staging(
               false,
               fn ->
                 assert System.fetch_env!(@staging_env) == existing_root
                 :fast_operation
               end,
               build_path: build_path,
               compiler: compiler
             )

    refute File.exists?(build_path)
    refute File.exists?(existing_root)
    assert System.fetch_env!(@staging_env) == existing_root
  end

  defp restore_env({:ok, value}), do: System.put_env(@staging_env, value)
  defp restore_env(:error), do: System.delete_env(@staging_env)
end
