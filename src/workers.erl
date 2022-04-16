-module(workers).

-export([seq/3,
         par/4,
         split_into/2
        ]).

-include_lib("eunit/include/eunit.hrl").

-type work() :: {term(), list()}.

-spec seq(fun(), fun(), list(work())) ->
          list(work()).
seq(MapFun, ReduceFun, Work) ->
    par(MapFun, ReduceFun, Work, 1).

-spec par(fun(), fun(), list(work()), pos_integer()) ->
          list(work()).
par(MapFun, ReduceFun, Work, NumWorkers) ->
    Self = self(),
    Chunks = split_into(NumWorkers, Work),
    PidRefs = [spawn_worker(Self, MapFun, C) || C <- Chunks],
    Ws = collect_work(PidRefs),
    reduce_work(ReduceFun, Ws).

spawn_worker(Parent, Fun, {K, Chunk}) ->
    Ref = make_ref(),
    Pid = spawn_link(fun () ->
                             Done = [{K, Fun(ChunkKey, C)} || {ChunkKey, C} <- Chunk],
                             Parent ! {work, self(), Ref, Done}
                     end),
    {Pid, Ref}.

collect_work(PidRefs) ->
    [receive
         {work, Pid, Ref, Work} ->
             Work
     end
     || {Pid, Ref} <- PidRefs].

%%% Chunks here are the collected work from the split_into
%%% meaning the split_into funtion has returned chunks prefixed with some id,
%%% and those chunks have also an chunk-key from the map/2-function
-spec reduce_work(fun(), list(list({pos_integer(), work()}))) -> list(work()).
reduce_work(Fun, Chunks) ->
    FCh = [Fun(K, W)
           || C <- Chunks,
              {_WorkerKey, Work} <- C,
              {K, W} <- Work],
    lists:flatten(FCh).

%%% split_into takes a list and splits that into X sublists
-spec split_into(ChunkSize :: pos_integer(),
                 Work :: list(work())) ->
          list({pos_integer(), list(work())}).

split_into(N, L) ->
  split_into(N, L, length(L)).

-spec split_into(ChunkSize :: pos_integer(),
                 Work :: list(work()),
                 WorkLen :: pos_integer()) ->
          list({pos_integer(), list(work())}).

split_into(1, L, _) ->
  [{1, L}];
split_into(N, L, Len) ->
  {Pre, Suf} = lists:split(Len div N, L),
  [{N, Pre}|split_into(N-1, Suf, Len-(Len div N))].
