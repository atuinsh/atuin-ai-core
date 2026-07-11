-module(clock_ffi).
-export([monotonic_ms/0]).

monotonic_ms() ->
    erlang:monotonic_time(millisecond).
