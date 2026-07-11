-module(uuid_ffi).
-export([generate/0, valid/1]).

%% UUIDv7 per RFC 9562: 48-bit unix-millisecond timestamp, then random
%% bits under the version and variant markers. Millisecond-ordered, like
%% the UUIDv7 library the hosted deployment previously supplied via FFI;
%% sub-millisecond ordering is random.
generate() ->
    Millis = os:system_time(millisecond),
    <<RandA:12, RandB:62, _:6>> = crypto:strong_rand_bytes(10),
    encode(<<Millis:48, 7:4, RandA:12, 2:2, RandB:62>>).

encode(<<A:32, B:16, C:16, D:16, E:48>>) ->
    iolist_to_binary(io_lib:format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C, D, E])).

%% Any RFC 4122-shaped UUID, either hex case — the same strings
%% Ecto.UUID.cast accepts (session IDs are client-supplied and are
%% typically v7 but historically v4).
valid(UUID) when is_binary(UUID), byte_size(UUID) =:= 36 ->
    case UUID of
        <<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-,
            E:12/binary>> ->
            lists:all(fun hex_chunk/1, [A, B, C, D, E]);
        _ ->
            false
    end;
valid(_) ->
    false.

hex_chunk(Bin) ->
    lists:all(fun is_hex/1, binary_to_list(Bin)).

is_hex(C) when C >= $0, C =< $9; C >= $a, C =< $f; C >= $A, C =< $F -> true;
is_hex(_) -> false.
