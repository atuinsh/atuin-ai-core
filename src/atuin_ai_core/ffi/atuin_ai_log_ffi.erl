-module(atuin_ai_log_ffi).

-export([error/1, warning/1, info/1, debug/1]).

%% Erlang `logger` feeds the same pipeline Elixir's Logger frontend does,
%% so warnings keep their severity (and reach level-based filtering and
%% alerting) under any host without an Elixir wrapper module. The format
%% string guards against `~` sequences in the message.
error(Message) ->
    logger:error("~ts", [Message]),
    nil.

warning(Message) ->
    logger:warning("~ts", [Message]),
    nil.

info(Message) ->
    logger:info("~ts", [Message]),
    nil.

debug(Message) ->
    logger:debug("~ts", [Message]),
    nil.
