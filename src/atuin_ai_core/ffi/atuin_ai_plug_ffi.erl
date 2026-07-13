-module(atuin_ai_plug_ffi).
-export([put_resp_header/3, send_chunked/2, put_status/2, json/2]).

%% Result-tuple wrappers over the raising Plug.Conn API, so the Gleam side
%% never crosses the FFI on an exception. Erlang rather than an Elixir
%% wrapper module so the package carries its own FFI; the host only needs
%% Plug itself.

put_resp_header(Conn, Key, Value) ->
    safely(fun() -> 'Elixir.Plug.Conn':put_resp_header(Conn, Key, Value) end).

send_chunked(Conn, Status) ->
    safely(fun() -> 'Elixir.Plug.Conn':send_chunked(Conn, Status) end).

put_status(Conn, Status) ->
    safely(fun() -> 'Elixir.Plug.Conn':put_status(Conn, Status) end).

%% Mirrors Phoenix.Controller.json/2 — JSON content type, the conn's
%% status (or 200), body encoded with OTP's `json` (the encoder gleam_json
%% uses) — without requiring Phoenix on the host.
json(Conn, Data) ->
    safely(fun() ->
        Body = iolist_to_binary(json:encode(Data)),
        WithType = 'Elixir.Plug.Conn':put_resp_content_type(
            Conn, <<"application/json">>),
        Status = case maps:get(status, WithType) of
            nil -> 200;
            S -> S
        end,
        'Elixir.Plug.Conn':send_resp(WithType, Status, Body)
    end).

safely(F) ->
    try
        {ok, F()}
    catch
        _:#{'__exception__' := true} = E ->
            {error, 'Elixir.Exception':message(E)};
        _:Reason ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.
