-module(map_reduce).

-export([seq/3,
         par/5]).

-include_lib("eunit/include/eunit.hrl").

seq(MapFun, ReduceFun, Input) ->
    %% Map
    KVs = [KV || {K, V} <- Input,
                 KV <- MapFun(K, V)],
    %% Reduce
    [KV2 || {K, Vs} <- KVs,
           KV2 <- ReduceFun(K, Vs)].

%% par_test_() ->
%%     Map = fun (K, Vs) -> {K, Vs} end,
%%     Reduce = fun (K, Vs) -> [{K, V} || V <- Vs] end,
%%     [?_assertEqual()].

par(MapFun, MapWorkers, ReduceFun, ReduceWorkers, Input) ->
    Parent = self(),
    PidsM = spawn_mappers(Parent, MapFun, MapWorkers, Input),
    MappedOutput = collect(PidsM),
    PidsR = spawn_reducers(Parent, ReduceFun, ReduceWorkers, MappedOutput),
    ReducedOutput = collect(PidsR),
    lists:flatten(ReducedOutput).

spawn_mappers(Parent, Map, Workers, Input) ->
    ?debugVal(Input),
    [spawn_mapper(Parent, Map, Workers, Chunk)
     || Chunk <- Input].

spawn_mapper(Parent, Map, W, Chunk) ->
    spawn_link(fun() ->
                       Mapped = [{erlang:phash2(K2, W), {K2, V2}}
                                 || {K,  V}  <- [Chunk],
                                    {K2, V2} <- Map(K, V)],
                       Parent ! {self(), Mapped}
               end).

collect(Pids) ->
    [receive {Pid, L} -> L end || Pid <- Pids].

spawn_reducers(Parent, Reduce, Workers, Chunk) ->
    [spawn_reducer(Parent, Reduce, WId, Chunk)
     || WId <- lists:seq(0, Workers-1)].


%% -type worker_id() :: non_neg_integer().
%% -spec spawn_reducer(pid(), reduce_fun(), worker_id(), [[{worker_id(), [{key(), value()}]}]]) -> pid().

spawn_reducer(Parent, Reduce, _WId, Chunk) ->
  spawn_link(fun() ->
                     Reduced = [KV || {K, Vs} <- Chunk,
                                      KV <- Reduce(K, Vs)],
                     Parent ! {self(), Reduced}
             end).
