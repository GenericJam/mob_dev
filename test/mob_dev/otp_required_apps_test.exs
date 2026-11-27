defmodule MobDev.OtpRequiredAppsTest do
  use ExUnit.Case, async: true

  alias MobDev.OtpRequiredApps

  describe "app_dependencies/1" do
    @describetag :tmp_dir

    test "skips optional applications", %{tmp_dir: dir} do
      # gettext_sigils' shape: igniter is optional, a build tool that a
      # MIX_ENV=prod release would otherwise ship once mob_dev compiles it.
      path = Path.join(dir, "gettext_sigils.app")

      File.write!(path, """
      {application,gettext_sigils,
                   [{applications,[kernel,stdlib,elixir,gettext,igniter]},
                    {optional_applications,[igniter]},
                    {included_applications,[inc]},
                    {vsn,"0.5.0"}]}.
      """)

      assert OtpRequiredApps.app_dependencies(path) ==
               ~w(kernel stdlib elixir gettext inc)
    end

    test "is [] for an unreadable file", %{tmp_dir: dir} do
      assert OtpRequiredApps.app_dependencies(Path.join(dir, "missing.app")) == []
    end
  end
end
