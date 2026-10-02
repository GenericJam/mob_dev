defmodule MobDev.XcodeLiveTest do
  # MOB-201: runs `mix mob.doctor`'s Xcode rows against the real Xcode the
  # environment selects (DEVELOPER_DIR), so the parser is checked on actual
  # `xcodebuild` / `xcrun` output, including Xcode 27.1's, which the dev Mac
  # doesn't have. Excluded by default (test_helper.exs); the `xcode` lane in
  # .github/workflows/test.yml runs it with the expectations set:
  #
  #   MOB_EXPECT_XCODE=27.1 MOB_EXPECT_IOS_SDK=27.1 MOB_EXPECT_DUO=ok \
  #     mix test --only xcode_live
  use ExUnit.Case, async: true

  alias MobDev.Toolchain
  alias Mix.Tasks.Mob.Doctor

  @moduletag :xcode_live

  test "doctor reports the selected Xcode, its iOS SDK and Duo support" do
    xcode = System.fetch_env!("MOB_EXPECT_XCODE")
    sdk = System.fetch_env!("MOB_EXPECT_IOS_SDK")
    duo = System.fetch_env!("MOB_EXPECT_DUO") |> String.to_existing_atom()

    rows = Doctor.__xcode_checks__(Toolchain.xcode_probe())

    assert [
             {:ok, "Xcode", xcode_detail, nil},
             {:ok, "iOS SDK", ^sdk, nil},
             {^duo, "iPhone Duo", _, _}
           ] = rows

    assert String.starts_with?(xcode_detail, xcode <> " "), inspect(rows)
  end
end
