defmodule MobDev.Plugin.SignatureGateAcknowledgedTest do
  # async: false — acknowledged_unsafe/1 reads the global
  # :mob, :acknowledge_unsafe_plugins env, which these tests set.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.SignatureGate

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_sig_ack_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    original = Application.fetch_env(:mob, :acknowledge_unsafe_plugins)
    Application.put_env(:mob, :acknowledge_unsafe_plugins, [:mob_from_env])

    on_exit(fn ->
      File.rm_rf!(dir)

      case original do
        {:ok, value} -> Application.put_env(:mob, :acknowledge_unsafe_plugins, value)
        :error -> Application.delete_env(:mob, :acknowledge_unsafe_plugins)
      end
    end)

    {:ok, dir: dir}
  end

  test "appends mob.exs's :acknowledge_unsafe_plugins to the env list", %{dir: dir} do
    File.write!(Path.join(dir, "mob.exs"), """
    import Config
    config :mob, :acknowledge_unsafe_plugins, [:mob_unsigned]
    """)

    assert SignatureGate.acknowledged_unsafe(dir) == [:mob_from_env, :mob_unsigned]
  end

  test "is just the env list when mob.exs is missing", %{dir: dir} do
    assert SignatureGate.acknowledged_unsafe(dir) == [:mob_from_env]
  end

  # MOB-280: a broken mob.exs used to read as "nothing acknowledged".
  test "raises when mob.exs fails to evaluate", %{dir: dir} do
    File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, :plugins, [:x\n")

    assert_raise TokenMissingError, fn -> SignatureGate.acknowledged_unsafe(dir) end
  end
end
