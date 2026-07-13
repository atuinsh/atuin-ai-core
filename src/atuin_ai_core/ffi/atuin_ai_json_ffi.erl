-module(atuin_ai_json_ffi).
-export([encode/1]).

%% Encode an arbitrary already-decoded JSON term (a `Dynamic`) using Erlang/OTP's
%% built-in `json` module — the same encoder `gleam_json` is built on — so it
%% runs without the Elixir runtime. `json:encode/1` returns iodata; flatten it
%% to the binary Gleam expects for a `String`.
encode(Term) ->
    iolist_to_binary(json:encode(Term)).
