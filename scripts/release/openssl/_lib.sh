#!/usr/bin/env bash
# scripts/release/openssl/_lib.sh
#
# Shared values for the cross-compile scripts in this directory.
# Source this from another script: `. "$(dirname "$0")/_lib.sh"`.
#
# Single source of truth on the Bash side; mirrors mob_dev's
# `MobDev.NdkVersion.@recommended` constant. The NDK we build OpenSSL
# (and later libbeam.a) against has to match the one that built the
# bundled OTP tarballs — different libc++ inline namespaces between
# NDK 25 and NDK 27 fail to link with `__cxa_allocate_exception`
# (or similar) at the libpigeon.so step.
#
# When you bump @recommended in lib/mob_dev/ndk_version.ex, bump the
# default below too. CI doesn't (yet) drift-check this against the
# Elixir module, but `mix mob.doctor` will warn the developer if their
# install is out of date.

# Default NDK version used to cross-compile OpenSSL + OTP tarballs.
# Override with NDK_VERSION=... in the environment if you know what
# you're doing.
: "${NDK_VERSION:=27.2.12479018}"

# Default NDK install root on macOS. Honors caller-set ANDROID_NDK_ROOT.
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/$NDK_VERSION}"

export NDK_VERSION ANDROID_NDK_ROOT
