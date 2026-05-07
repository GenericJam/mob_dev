-module(crypto).
-export([strong_rand_bytes/1]).

%% Minimal crypto stub for Android builds.
%%
%% The Mob pre-built Android OTP release omits the crypto OTP application
%% because it requires a cross-compiled OpenSSL NIF. Ecto and other deps
%% declare :crypto as a required application dependency even though the only
%% function called at runtime is strong_rand_bytes/1 (for UUID generation).
%%
%% This stub satisfies the dependency using the BEAM's built-in :rand module,
%% which is seeded from os:timestamp() at BEAM start. UUID generation works
%% correctly; cryptographic strength is reduced, which is acceptable for a
%% local-only mobile app without TLS or encryption use cases.

strong_rand_bytes(N) ->
    list_to_binary([rand:uniform(256) - 1 || _ <- lists:seq(1, N)]).
