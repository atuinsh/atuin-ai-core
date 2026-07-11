-module(log_ffi).
-export([warning/1]).

%% Erlang `logger` feeds the same pipeline Elixir's Logger frontend does,
%% so warnings keep their severity (and reach level-based filtering and
%% alerting) under any host without an Elixir wrapper module. The format
%% string guards against `~` sequences in the message.
warning(Message) ->
    logger:warning("~ts", [Message]),
    nil.
