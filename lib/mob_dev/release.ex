defmodule MobDev.Release do
  @moduledoc """
  Build a signed, App-Store-ready iOS `.ipa` for the current Mob project.

  Mirrors `MobDev.NativeBuild`'s physical-device build pipeline but signs
  with a distribution identity, embeds an App Store provisioning profile,
  drops EPMD + the distribution-related BEAM args (the `MOB_RELEASE` flag),
  and packages the `.app` as a `.ipa` instead of installing it.

  Output path: `_build/mob_release/<App>.ipa`.

  ## Required mob.exs keys

      config :mob_dev,
        bundle_id:                "com.example.app",
        ios_team_id:              "ABC123XYZ4",
        # Distribution-only — falls back to auto-detect if absent:
        ios_dist_sign_identity:   "Apple Distribution: Your Name (ABC123XYZ4)",
        ios_dist_profile_uuid:    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  Auto-detection looks for `Apple Distribution: ...` certificates in the
  keychain and picks the first matching App Store provisioning profile
  (one with no `ProvisionedDevices` and no `ProvisionsAllDevices`).
  """

  @doc """
  Build a signed `.ipa` for App Store / TestFlight distribution.

  Returns `{:ok, ipa_path}` or `{:error, reason}`.
  """
  @spec build_ipa(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def build_ipa(_opts \\ []) do
    cfg = MobDev.NativeBuild.__load_config__()

    with :ok <- check_macos(),
         :ok <- check_xcrun(),
         {:ok, cfg} <- resolve_distribution_signing(cfg),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_device() do
      script_path = "ios/release_device.sh"
      File.write!(script_path, release_device_sh())
      File.chmod!(script_path, 0o755)

      env = release_env(cfg, otp_root)
      output_dir = Path.expand("_build/mob_release")
      File.mkdir_p!(output_dir)

      env = [{"MOB_RELEASE_OUTPUT_DIR", output_dir} | env]

      case System.cmd("bash", [script_path],
             env: env,
             stderr_to_stdout: true,
             into: IO.stream()
           ) do
        {_, 0} ->
          app_name = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
          ipa_path = Path.join(output_dir, "#{app_name}.ipa")
          {:ok, ipa_path}

        {_, _} ->
          {:error, "release_device.sh failed — check output above"}
      end
    end
  end

  # ── Signing config ───────────────────────────────────────────────────────────

  @doc false
  @spec resolve_distribution_signing(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def resolve_distribution_signing(cfg) do
    bundle_id = cfg[:bundle_id]

    with {:ok, identity} <- resolve_dist_identity(cfg[:ios_dist_sign_identity]),
         {:ok, {profile_uuid, team_id}} <-
           resolve_dist_profile(cfg[:ios_dist_profile_uuid], bundle_id, cfg[:ios_team_id]) do
      {:ok,
       cfg
       |> Keyword.put(:ios_dist_sign_identity, identity)
       |> Keyword.put(:ios_dist_profile_uuid, profile_uuid)
       |> Keyword.put(:ios_team_id, team_id)}
    end
  end

  defp resolve_dist_identity(identity) when is_binary(identity), do: {:ok, identity}

  defp resolve_dist_identity(_) do
    case System.cmd("security", ["find-identity", "-v", "-p", "codesigning"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        identities =
          Regex.scan(~r/\d+\) [0-9A-F]+ "([^"]+)"/, output)
          |> Enum.map(fn [_, full] -> full end)
          |> Enum.filter(&String.contains?(&1, "Apple Distribution"))
          |> Enum.uniq()

        case identities do
          [] ->
            {:error,
             """
             No Apple Distribution signing certificate found in the keychain.

             You need a paid Apple Developer Program account ($99/year) to get
             a Distribution certificate. Once enrolled:
               1. Open Xcode → Settings → Accounts → your Apple ID
               2. Click "Manage Certificates" → "+" → "Apple Distribution"
               3. Close Xcode

             Then re-run `mix mob.release`.

             (For development-only builds to your own device, use
             `mix mob.deploy --native` — that uses an Apple Development cert.)
             """}

          [identity] ->
            IO.puts(
              "  #{IO.ANSI.cyan()}Auto-detected distribution identity: #{identity}#{IO.ANSI.reset()}"
            )

            {:ok, identity}

          many ->
            choices = Enum.map_join(many, "\n", &"    #{&1}")

            {:error,
             """
             Multiple distribution identities found — set ios_dist_sign_identity
             in mob.exs:

                 config :mob_dev,
                   ios_dist_sign_identity: "Apple Distribution: You (ABC123XYZ4)"

             Available:
             #{choices}
             """}
        end

      {out, _} ->
        {:error, "security find-identity failed: #{out}"}
    end
  end

  defp resolve_dist_profile(uuid, _bundle_id, team_id)
       when is_binary(uuid) and is_binary(team_id),
       do: {:ok, {uuid, team_id}}

  defp resolve_dist_profile(uuid, bundle_id, _team_id) do
    profile_dirs = [
      Path.expand("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles")
    ]

    all_profiles =
      Enum.flat_map(profile_dirs, &Path.wildcard(Path.join(&1, "*.mobileprovision")))
      |> Enum.flat_map(&parse_mobileprovision/1)

    # App Store distribution profiles have NO `ProvisionedDevices` array
    # (development + ad-hoc do) and NO `ProvisionsAllDevices` (enterprise does).
    app_store_profiles =
      Enum.filter(all_profiles, fn %{
                                     provisioned_devices?: pd,
                                     provisions_all_devices?: pad
                                   } ->
        not pd and not pad
      end)

    matches =
      Enum.filter(app_store_profiles, fn %{app_id: aid} ->
        String.ends_with?(aid, ".#{bundle_id}") or String.ends_with?(aid, ".*")
      end)

    candidates =
      if is_binary(uuid) do
        Enum.filter(matches, &(&1.uuid == uuid))
      else
        # Prefer exact bundle ID over wildcard.
        exact = Enum.filter(matches, &String.ends_with?(&1.app_id, ".#{bundle_id}"))
        if exact != [], do: exact, else: matches
      end

    case candidates do
      [] ->
        {:error,
         """
         No App Store provisioning profile found for bundle ID '#{bundle_id}'.

         To create one:
           1. Enroll in the Apple Developer Program (paid, $99/yr)
           2. Run: mix mob.provision --distribution

         Or in Xcode: Settings → Accounts → Download Manual Profiles after
         registering an App Store distribution profile in App Store Connect.
         """}

      [%{uuid: u, team_id: t, app_id: aid}] ->
        unless is_binary(uuid) do
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected App Store profile: #{u} (team #{t})#{IO.ANSI.reset()}"
          )

          if String.ends_with?(aid, ".*") do
            IO.puts(
              "  #{IO.ANSI.yellow()}  using wildcard profile — run `mix mob.provision --distribution` to create a dedicated one for #{bundle_id}#{IO.ANSI.reset()}"
            )
          end
        end

        {:ok, {u, t}}

      many ->
        choices = Enum.map_join(many, "\n", fn %{uuid: u, app_id: a} -> "    #{u}  (#{a})" end)

        {:error,
         """
         Multiple App Store profiles match '#{bundle_id}' — set
         ios_dist_profile_uuid in mob.exs:

             config :mob_dev,
               ios_dist_profile_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

         Matching profiles:
         #{choices}
         """}
    end
  end

  @doc false
  @spec parse_mobileprovision(String.t()) :: [
          %{
            uuid: String.t(),
            app_id: String.t(),
            team_id: String.t(),
            provisioned_devices?: boolean(),
            provisions_all_devices?: boolean()
          }
        ]
  def parse_mobileprovision(path) do
    with {:ok, data} <- File.read(path),
         {s, _} <- :binary.match(data, "<?xml"),
         {e, len} <- :binary.match(data, "</plist>") do
      xml = binary_part(data, s, e - s + len)
      uuid = capture(xml, ~r/<key>UUID<\/key>\s*<string>([^<]+)<\/string>/)
      app_id = capture(xml, ~r/<key>application-identifier<\/key>\s*<string>([^<]+)<\/string>/)

      team =
        capture(
          xml,
          ~r/<key>TeamIdentifier<\/key>\s*<array>\s*<string>([^<]+)<\/string>/
        )

      pd = String.contains?(xml, "<key>ProvisionedDevices</key>")
      pad = String.contains?(xml, "<key>ProvisionsAllDevices</key>")

      case {uuid, app_id, team} do
        {u, a, t} when is_binary(u) and is_binary(a) and is_binary(t) ->
          [
            %{
              uuid: u,
              app_id: a,
              team_id: t,
              provisioned_devices?: pd,
              provisions_all_devices?: pad
            }
          ]

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp capture(xml, regex) do
    case Regex.run(regex, xml) do
      [_, val] -> String.trim(val)
      _ -> nil
    end
  end

  # ── Env for release_device.sh ────────────────────────────────────────────────

  defp release_env(cfg, otp_root) do
    app_atom = Mix.Project.config()[:app]
    app_name = app_atom |> to_string() |> Macro.camelize()
    app_module = to_string(app_atom)
    elixir_lib = MobDev.NativeBuild.__resolve_elixir_lib__(cfg[:elixir_lib])
    epmd_src = cfg[:ios_epmd_build_src] || otp_root

    [
      {"MOB_DIR", Path.expand(cfg[:mob_dir])},
      {"MOB_ELIXIR_LIB", Path.expand(elixir_lib)},
      {"MOB_IOS_DEVICE_OTP_ROOT", otp_root},
      {"MOB_IOS_EPMD_BUILD_SRC", epmd_src},
      {"MOB_IOS_BUNDLE_ID", cfg[:bundle_id]},
      {"MOB_IOS_TEAM_ID", cfg[:ios_team_id]},
      {"MOB_IOS_SIGN_IDENTITY", cfg[:ios_dist_sign_identity]},
      {"MOB_IOS_PROFILE_UUID", cfg[:ios_dist_profile_uuid]},
      {"MOB_APP_NAME", app_name},
      {"MOB_APP_MODULE", app_module}
    ]
  end

  # ── Preflight ────────────────────────────────────────────────────────────────

  defp check_macos do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> {:error, "mix mob.release is only supported on macOS (Xcode is required)."}
    end
  end

  defp check_xcrun do
    if System.find_executable("xcrun") do
      :ok
    else
      {:error, "xcrun not found on PATH — install Xcode and run `xcode-select --install`."}
    end
  end

  # ── release_device.sh ────────────────────────────────────────────────────────

  defp release_device_sh do
    ~S"""
    #!/bin/bash
    # ios/release_device.sh — App Store / TestFlight build for Mob (generated
    # by `mix mob.release`). Mirrors build_device.sh but with distribution
    # signing, no EPMD, no distribution BEAM args, and IPA packaging.
    set -e
    cd "$(dirname "$0")/.."

    MOB_DIR="${MOB_DIR:?MOB_DIR not set}"
    ELIXIR_LIB=$(elixir -e "IO.puts(Path.dirname(to_string(:code.lib_dir(:elixir))))" 2>/dev/null)
    if [ -z "$ELIXIR_LIB" ] || [ ! -d "$ELIXIR_LIB/elixir/ebin" ]; then
        ELIXIR_LIB="${MOB_ELIXIR_LIB:?MOB_ELIXIR_LIB not set}"
    fi
    OTP_ROOT="${MOB_IOS_DEVICE_OTP_ROOT:?MOB_IOS_DEVICE_OTP_ROOT not set}"
    BUNDLE_ID="${MOB_IOS_BUNDLE_ID:?bundle_id not set}"
    TEAM_ID="${MOB_IOS_TEAM_ID:?ios_team_id not set}"
    SIGN_IDENTITY="${MOB_IOS_SIGN_IDENTITY:?distribution signing identity not set}"
    PROFILE_UUID="${MOB_IOS_PROFILE_UUID:?App Store profile UUID not set}"
    APP_NAME="${MOB_APP_NAME:?MOB_APP_NAME not set}"
    APP_MODULE="${MOB_APP_MODULE:?MOB_APP_MODULE not set}"
    OUTPUT_DIR="${MOB_RELEASE_OUTPUT_DIR:?MOB_RELEASE_OUTPUT_DIR not set}"

    ERTS_VSN=$(ls "$OTP_ROOT" | grep '^erts-' | sort -V | tail -1)
    [ -z "$ERTS_VSN" ] && echo "ERROR: No erts-* in $OTP_ROOT" && exit 1
    OTP_RELEASE=$(ls "$OTP_ROOT/releases" 2>/dev/null | grep -E '^[0-9]+$' | sort -V | tail -1)
    [ -z "$OTP_RELEASE" ] && echo "ERROR: No releases/<N>/ in $OTP_ROOT" && exit 1
    echo "=== RELEASE: ERTS=$ERTS_VSN OTP=$OTP_RELEASE App=$APP_NAME Bundle=$BUNDLE_ID ==="

    BEAMS_DIR="$OTP_ROOT/$APP_MODULE"
    SDKROOT=$(xcrun -sdk iphoneos --show-sdk-path)
    HOSTCC=$(xcrun -find cc)
    CC="$HOSTCC -arch arm64 -miphoneos-version-min=17.0 -isysroot $SDKROOT"

    IFLAGS="-I$OTP_ROOT/$ERTS_VSN/include \
            -I$OTP_ROOT/$ERTS_VSN/include/internal \
            -I$MOB_DIR/ios"

    LIBS="
      $OTP_ROOT/$ERTS_VSN/lib/libbeam.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/liberts_internal_r.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/libethread.a
      $OTP_ROOT/$ERTS_VSN/lib/libzstd.a
      $OTP_ROOT/$ERTS_VSN/lib/libepcre.a
      $OTP_ROOT/$ERTS_VSN/lib/libryu.a
      $OTP_ROOT/$ERTS_VSN/lib/asn1rt_nif.a
    "

    echo "=== Compiling Erlang/Elixir ==="
    mix compile

    echo "=== Copying BEAM files to $BEAMS_DIR ==="
    mkdir -p "$BEAMS_DIR"
    for lib_dir in _build/dev/lib/*/ebin; do
        cp "$lib_dir"/* "$BEAMS_DIR/" 2>/dev/null || true
    done

    SQLITE_STATIC_LIB=""
    if [ -d "_build/dev/lib/exqlite" ]; then
        EXQLITE_VSN=$(grep '"exqlite"' mix.lock \
            | grep -o '"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | head -1 | tr -d '"')
        [ -z "$EXQLITE_VSN" ] && EXQLITE_VSN=$(grep -o '{vsn,"[^"]*"}' \
            _build/dev/lib/exqlite/ebin/exqlite.app | grep -o '"[^"]*"' | tr -d '"')
        EXQLITE_LIB_DIR="$OTP_ROOT/lib/exqlite-${EXQLITE_VSN}"
        rm -rf "$OTP_ROOT/lib/exqlite-"*
        mkdir -p "$EXQLITE_LIB_DIR/ebin" "$EXQLITE_LIB_DIR/priv"
        cp _build/dev/lib/exqlite/ebin/*.beam "$EXQLITE_LIB_DIR/ebin/"
        cp _build/dev/lib/exqlite/ebin/exqlite.app "$EXQLITE_LIB_DIR/ebin/"

        EXQLITE_SRC="deps/exqlite/c_src"
        BUILD_DIR_TMP=$(mktemp -d)
        $CC -I "$EXQLITE_SRC" -I "$OTP_ROOT/$ERTS_VSN/include" \
            -I "$OTP_ROOT/$ERTS_VSN/include/internal" \
            -DSQLITE_THREADSAFE=1 -DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif \
            -Wno-\#warnings \
            -c "$EXQLITE_SRC/sqlite3_nif.c" -o "$BUILD_DIR_TMP/sqlite3_nif.o"
        $CC -I "$EXQLITE_SRC" -DSQLITE_THREADSAFE=1 -Wno-\#warnings \
            -c "$EXQLITE_SRC/sqlite3.c" -o "$BUILD_DIR_TMP/sqlite3.o"
        $(xcrun -find ar) rcs "$EXQLITE_LIB_DIR/priv/sqlite3_nif.a" \
            "$BUILD_DIR_TMP/sqlite3_nif.o" "$BUILD_DIR_TMP/sqlite3.o"
        SQLITE_STATIC_LIB="$EXQLITE_LIB_DIR/priv/sqlite3_nif.a"
        rm -rf "$BUILD_DIR_TMP"
    fi

    # Crypto + SSL shims (same as build_device.sh — see build_device.sh comments)
    CRYPTO_TMP=$(mktemp -d)
    cat > "$CRYPTO_TMP/crypto.erl" << 'ERLEOF'
    -module(crypto).
    -behaviour(application).
    -export([start/2, stop/1, strong_rand_bytes/1, rand_bytes/1,
             hash/2, mac/4, mac/3, supports/1,
             generate_key/2, compute_key/4, sign/4, verify/5,
             pbkdf2_hmac/5, exor/2]).
    start(_Type, _Args) -> {ok, self()}.
    stop(_State) -> ok.
    strong_rand_bytes(N) -> rand:bytes(N).
    rand_bytes(N) -> rand:bytes(N).
    hash(_Type, Data) -> erlang:md5(iolist_to_binary(Data)).
    supports(_Type) -> [].
    generate_key(_Alg, _Params) -> {<<>>, <<>>}.
    compute_key(_Alg, _OtherKey, _MyKey, _Params) -> <<>>.
    sign(_Alg, _DigestType, _Msg, _Key) -> <<>>.
    verify(_Alg, _DigestType, _Msg, _Signature, _Key) -> true.
    mac(hmac, _HashAlg, Key, Data) ->
        hmac_md5(iolist_to_binary(Key), iolist_to_binary(Data));
    mac(_Type, _SubType, _Key, _Data) -> <<>>.
    mac(_Type, _Key, _Data) -> <<>>.
    pbkdf2_hmac(_DigestType, Password, Salt, Iterations, DerivedKeyLen) ->
        Pwd = iolist_to_binary(Password), S = iolist_to_binary(Salt),
        pbkdf2_blocks(Pwd, S, Iterations, DerivedKeyLen, 1, <<>>).
    pbkdf2_blocks(_Pwd, _Salt, _Iter, Len, _Block, Acc) when byte_size(Acc) >= Len ->
        binary:part(Acc, 0, Len);
    pbkdf2_blocks(Pwd, Salt, Iter, Len, Block, Acc) ->
        U1 = hmac_md5(Pwd, <<Salt/binary, Block:32/unsigned-big-integer>>),
        Ux = pbkdf2_iterate(Pwd, Iter - 1, U1, U1),
        pbkdf2_blocks(Pwd, Salt, Iter, Len, Block + 1, <<Acc/binary, Ux/binary>>).
    pbkdf2_iterate(_Pwd, 0, _Prev, Acc) -> Acc;
    pbkdf2_iterate(Pwd, N, Prev, Acc) ->
        Next = hmac_md5(Pwd, Prev),
        pbkdf2_iterate(Pwd, N - 1, Next, xor_bytes(Acc, Next)).
    hmac_md5(Key0, Data) ->
        BlockSize = 64,
        Key = if byte_size(Key0) > BlockSize -> erlang:md5(Key0); true -> Key0 end,
        PadLen = BlockSize - byte_size(Key),
        K = <<Key/binary, 0:(PadLen * 8)>>,
        IPad = xor_bytes(K, binary:copy(<<16#36>>, BlockSize)),
        OPad = xor_bytes(K, binary:copy(<<16#5C>>, BlockSize)),
        erlang:md5(<<OPad/binary, (erlang:md5(<<IPad/binary, Data/binary>>))/binary>>).
    exor(A, B) -> xor_bytes(iolist_to_binary(A), iolist_to_binary(B)).
    xor_bytes(A, B) -> xor_bytes(A, B, []).
    xor_bytes(<<X, Ra/binary>>, <<Y, Rb/binary>>, Acc) ->
        xor_bytes(Ra, Rb, [X bxor Y | Acc]);
    xor_bytes(<<>>, <<>>, Acc) -> list_to_binary(lists:reverse(Acc)).
    ERLEOF
    erlc -o "$BEAMS_DIR" "$CRYPTO_TMP/crypto.erl"
    cat > "$BEAMS_DIR/crypto.app" << 'APPEOF'
    {application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]},{description,"Crypto shim for iOS"},{registered,[]},{vsn,"5.6"},{mod,{crypto,[]}}]}.
    APPEOF
    rm -rf "$CRYPTO_TMP"

    SSL_TMP=$(mktemp -d)
    cat > "$SSL_TMP/ssl.erl" << 'SSLEOF'
    -module(ssl).
    -behaviour(application).
    -export([start/2, stop/1, start/0, stop/0]).
    start(_Type, _Args) -> Pid = spawn(fun() -> receive stop -> ok end end), {ok, Pid}.
    stop(_State) -> ok.
    start() -> ok.
    stop() -> ok.
    SSLEOF
    erlc -o "$BEAMS_DIR" "$SSL_TMP/ssl.erl"
    cat > "$BEAMS_DIR/ssl.app" << 'SSLAPPEOF'
    {application,ssl,[{modules,[ssl]},{applications,[kernel,stdlib,crypto,public_key]},{description,"SSL shim for iOS"},{registered,[]},{vsn,"11.2"},{mod,{ssl,[]}}]}.
    SSLAPPEOF
    rm -rf "$SSL_TMP"

    echo "=== Copying Elixir stdlib ==="
    mkdir -p "$OTP_ROOT/lib/elixir/ebin" "$OTP_ROOT/lib/logger/ebin"
    cp "$ELIXIR_LIB/elixir/ebin/"*.beam    "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/elixir/ebin/elixir.app" "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/"*.beam    "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/logger.app" "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/eex/ebin/"*.beam  "$BEAMS_DIR/" 2>/dev/null || true
    cp "$ELIXIR_LIB/eex/ebin/eex.app" "$BEAMS_DIR/" 2>/dev/null || true

    copy_otp_lib() {
        local APP="$1"
        local SRC
        SRC=$(elixir -e "IO.puts(:code.lib_dir(:${APP}))" 2>/dev/null)
        if [ -n "$SRC" ] && [ -d "$SRC/ebin" ]; then
            local VSN
            VSN=$(basename "$SRC")
            mkdir -p "$OTP_ROOT/lib/$VSN/ebin"
            cp "$SRC/ebin/"*.beam "$OTP_ROOT/lib/$VSN/ebin/"
            cp "$SRC/ebin/${APP}.app" "$OTP_ROOT/lib/$VSN/ebin/"
        fi
    }
    copy_otp_lib runtime_tools
    copy_otp_lib asn1
    copy_otp_lib public_key

    echo "=== Copying migrations + assets ==="
    mkdir -p "$BEAMS_DIR/priv/repo/migrations"
    if ls priv/repo/migrations/*.exs >/dev/null 2>&1; then
        cp priv/repo/migrations/*.exs "$BEAMS_DIR/priv/repo/migrations/"
    fi
    if [ -d "assets" ]; then
        mix assets.build
        if [ -d "priv/static" ]; then
            mkdir -p "$BEAMS_DIR/priv/static"
            rsync -a "priv/static/" "$BEAMS_DIR/priv/static/"
        fi
    fi

    APP_VSN=$(grep -o '{vsn,"[^"]*"}' "$BEAMS_DIR/${APP_MODULE}.app" | grep -o '"[^"]*"' | tr -d '"')
    if [ -n "$APP_VSN" ]; then
        APP_LIB_DIR="$OTP_ROOT/lib/${APP_MODULE}-${APP_VSN}"
        rm -rf "$APP_LIB_DIR"
        mkdir -p "$APP_LIB_DIR/ebin"
        cp "$BEAMS_DIR/${APP_MODULE}.app" "$APP_LIB_DIR/ebin/"
        if [ -d "$BEAMS_DIR/priv" ]; then
            rsync -a "$BEAMS_DIR/priv/" "$APP_LIB_DIR/priv/"
        fi
    fi

    cp "$MOB_DIR/assets/logo/logo_dark.png"  "$OTP_ROOT/mob_logo_dark.png"  2>/dev/null || true
    cp "$MOB_DIR/assets/logo/logo_light.png" "$OTP_ROOT/mob_logo_light.png" 2>/dev/null || true

    echo "=== Compiling native sources (release: -DMOB_RELEASE, no EPMD) ==="
    BUILD_DIR=$(mktemp -d)
    SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c "$MOB_DIR/ios/MobNode.m" -o "$BUILD_DIR/MobNode.o"

    xcrun -sdk iphoneos swiftc \
        -target arm64-apple-ios17.0 \
        -module-name "$APP_NAME" \
        -emit-objc-header -emit-objc-header-path "$BUILD_DIR/MobApp-Swift.h" \
        -import-objc-header "$SWIFT_BRIDGING" \
        -I "$MOB_DIR/ios" \
        -parse-as-library -wmo \
        -O \
        "$MOB_DIR/ios/MobViewModel.swift" \
        "$MOB_DIR/ios/MobRootView.swift" \
        -c -o "$BUILD_DIR/swift_mob.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -I "$BUILD_DIR" -DSTATIC_ERLANG_NIF \
        -c "$MOB_DIR/ios/mob_nif.m" -o "$BUILD_DIR/mob_nif.o"

    # MOB_RELEASE: drops -name/-setcookie/-kernel-dist BEAM args + EPMD thread.
    $CC -fobjc-arc -fmodules $IFLAGS \
        -DMOB_BUNDLE_OTP \
        -DMOB_RELEASE \
        -DERTS_VSN=\"$ERTS_VSN\" \
        -DOTP_RELEASE=\"$OTP_RELEASE\" \
        -c "$MOB_DIR/ios/mob_beam.m" -o "$BUILD_DIR/mob_beam.o"

    SQLITE_FLAG=""
    [ -n "$SQLITE_STATIC_LIB" ] && SQLITE_FLAG="-DMOB_STATIC_SQLITE_NIF"
    $CC $IFLAGS $SQLITE_FLAG \
        -c "$MOB_DIR/ios/driver_tab_ios.c" -o "$BUILD_DIR/driver_tab_ios.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -I "$BUILD_DIR" \
        -c ios/AppDelegate.m -o "$BUILD_DIR/AppDelegate.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c ios/beam_main.m -o "$BUILD_DIR/beam_main.o"

    echo "=== Linking $APP_NAME (release, no EPMD) ==="
    xcrun -sdk iphoneos swiftc \
        -target arm64-apple-ios17.0 \
        "$BUILD_DIR/driver_tab_ios.o" \
        "$BUILD_DIR/MobNode.o" \
        "$BUILD_DIR/swift_mob.o" \
        "$BUILD_DIR/mob_nif.o" \
        "$BUILD_DIR/mob_beam.o" \
        "$BUILD_DIR/AppDelegate.o" \
        "$BUILD_DIR/beam_main.o" \
        $LIBS \
        "$SQLITE_STATIC_LIB" \
        -lz -lc++ -lpthread \
        -Xlinker -framework -Xlinker UIKit \
        -Xlinker -framework -Xlinker Foundation \
        -Xlinker -framework -Xlinker CoreGraphics \
        -Xlinker -framework -Xlinker QuartzCore \
        -Xlinker -framework -Xlinker SwiftUI \
        -o "$BUILD_DIR/$APP_NAME"

    echo "=== Building .app bundle ==="
    APP="$BUILD_DIR/$APP_NAME.app"
    rm -rf "$APP"
    mkdir -p "$APP"
    cp "$BUILD_DIR/$APP_NAME" "$APP/"

    cp ios/Info.plist "$APP/"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME"   "$APP/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME"         "$APP/Info.plist"

    if [ -d "ios/Assets.xcassets/AppIcon.appiconset" ]; then
        ACTOOL_PLIST=$(mktemp /tmp/actool_XXXXXX.plist)
        xcrun actool ios/Assets.xcassets \
            --compile "$APP" --platform iphoneos \
            --minimum-deployment-target 17.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "$ACTOOL_PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Merge $ACTOOL_PLIST" "$APP/Info.plist" 2>/dev/null || true
        rm -f "$ACTOOL_PLIST"
    fi

    echo "=== Bundling OTP runtime (no EPMD binary path) ==="
    OTP_BUNDLE="$APP/otp"
    mkdir -p "$OTP_BUNDLE"
    rsync -a --delete "$OTP_ROOT/lib/"      "$OTP_BUNDLE/lib/"
    rsync -a --delete "$OTP_ROOT/releases/" "$OTP_BUNDLE/releases/"
    rsync -a --delete "$OTP_ROOT/$APP_MODULE/" "$OTP_BUNDLE/$APP_MODULE/"
    for f in "$OTP_ROOT"/*.png "$OTP_ROOT"/*.jpg; do
        [ -f "$f" ] && cp "$f" "$OTP_BUNDLE/"
    done
    mkdir -p "$OTP_BUNDLE/$ERTS_VSN/bin"

    echo "=== Embedding App Store provisioning profile ==="
    PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    PROFILE="$PROFILE_DIR/${PROFILE_UUID}.mobileprovision"
    if [ ! -f "$PROFILE" ]; then
        PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
    fi
    if [ ! -f "$PROFILE" ]; then
        echo "ERROR: Provisioning profile $PROFILE_UUID not found."
        exit 1
    fi
    cp "$PROFILE" "$APP/embedded.mobileprovision"

    echo "=== Code signing (distribution, no get-task-allow) ==="
    ENTITLEMENTS_FILE="$BUILD_DIR/mob_release.entitlements"
    cat > "$ENTITLEMENTS_FILE" << ENTEOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>application-identifier</key>
        <string>${TEAM_ID}.${BUNDLE_ID}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>${TEAM_ID}</string>
        <key>beta-reports-active</key>
        <true/>
    </dict>
    </plist>
    ENTEOF
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS_FILE" \
        --timestamp \
        --options runtime \
        "$APP"

    echo "=== Verifying signature ==="
    codesign --verify --deep --strict --verbose=2 "$APP"

    echo "=== Packaging IPA ==="
    IPA_STAGE=$(mktemp -d)
    mkdir -p "$IPA_STAGE/Payload"
    cp -r "$APP" "$IPA_STAGE/Payload/"
    IPA_PATH="$OUTPUT_DIR/$APP_NAME.ipa"
    rm -f "$IPA_PATH"
    (cd "$IPA_STAGE" && zip -qr "$IPA_PATH" Payload)
    rm -rf "$IPA_STAGE"

    echo "=== Done: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1)) ==="
    """
  end
end
