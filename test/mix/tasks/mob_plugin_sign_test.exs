defmodule Mix.Tasks.Mob.Plugin.SignTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Sign, Verify}

  setup do
    tmp_home =
      Path.join(System.tmp_dir!(), "mob_sign_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    previous = Application.get_env(:mob_dev, :plugin_key_home)
    Application.put_env(:mob_dev, :plugin_key_home, tmp_home)

    plugin_dir =
      Path.join(System.tmp_dir!(), "mob_sign_plugin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(plugin_dir, "priv"))

    manifest = %{name: :mob_sign_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
    File.write!(Path.join(plugin_dir, "priv/mob_plugin.exs"), inspect(manifest))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mob_dev, :plugin_key_home, previous),
        else: Application.delete_env(:mob_dev, :plugin_key_home)

      File.rm_rf!(tmp_home)
      File.rm_rf!(plugin_dir)
    end)

    {:ok, plugin_dir: plugin_dir}
  end

  test "end-to-end: keygen + sign produces a verifiable signature", %{plugin_dir: dir} do
    Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])
    Mix.Tasks.Mob.Plugin.Sign.run(["--plugin", dir])

    assert File.exists?(Sign.signature_path(dir))

    # verify_plugin/1 (MOB-74): no manifest arg needed — the envelope carries
    # the signed file_hashes list on disk so verification runs off the bytes.
    assert :ok = Verify.verify_plugin(dir)
  end

  test "errors when no keygen has been run for the plugin", %{plugin_dir: dir} do
    assert_raise Mix.Error, ~r/no private key/, fn ->
      Mix.Tasks.Mob.Plugin.Sign.run(["--plugin", dir])
    end
  end

  test "errors when the plugin has no manifest", %{plugin_dir: dir} do
    File.rm!(Path.join(dir, "priv/mob_plugin.exs"))

    assert_raise Mix.Error, ~r/no priv\/mob_plugin\.exs/, fn ->
      Mix.Tasks.Mob.Plugin.Sign.run(["--plugin", dir])
    end
  end
end
