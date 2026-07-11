-module(callers_ffi).
-export([callers/0, put_callers/1]).

%% Mirrors the Elixir `$callers` convention (Task, Mox): the chain a
%% process spawned on our behalf should carry is the current process plus
%% its own callers. Both `undefined` (Erlang pdict miss) and `nil` (an
%% Elixir host stored nil) mean "no chain".

callers() ->
    Existing = case get('$callers') of
        undefined -> [];
        nil -> [];
        List when is_list(List) -> List;
        Other -> [Other]
    end,
    [self() | Existing].

put_callers(Callers) when is_list(Callers) ->
    put('$callers', Callers),
    nil;
put_callers(Callers) ->
    put('$callers', [Callers]),
    nil.
