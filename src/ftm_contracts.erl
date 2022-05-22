-module(ftm_contracts).

-export([get_metadatas/0
        ]).

-include_lib("ftm_crawler/include/ftm.hrl").
-include_lib("eunit/include/eunit.hrl").

get_metadatas() ->
    ftm_utils:make_sure_storage_exist(),
    BlockId = 38828890, % 38802495,
    TsSpec = [{#block{id = '$1',is_reduced = '_',transactions = '$2'},
               [{'==', '$1', BlockId},
                {'>',{length,'$2'},0}],
               [{{'$1','$2'}}]}],
    {atomic, Ts} = mnesia:transaction(fun () ->
                                              mnesia:select(?BLOCK_TABLE, TsSpec)
                                      end),
    workers:par(fun map/2, fun reduce/2, Ts, 20).

map(K, Ts) ->
    F = lists:filtermap(fun (T) ->
                                case find_metadata_string(T) of
                                    nomatch -> false;
                                    E -> {true, E}
                                end
                        end, Ts),
    FT = [fetch_ipfs(T) || T <- F],
    [{K, FT}].

reduce(K, Ts) ->
    [{K, Ts}].

fetch_ipfs(#{<<"ipfs_cid_v0">> := decode_error} = M) ->
    {decode_error, maps:get(<<"ipfs">>, M)};
fetch_ipfs(#{<<"ipfs_cid_v0">> := IPFS} = M) ->
    Url = ["https://ipfs.io/ipfs/", IPFS],
    io:format("Fetching ~s~n", [Url]),
    case httpc:request(get, {Url, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {_, _, B}} ->
            B;
        {error, timeout} ->
            {timeout, maps:get(<<"ipfs">>, M)};
        E ->
            io:format(user, "Error while fetching ~p~n", [E]),
            {not_fetched, maps:get(<<"ipfs">>, M)}
    end.


find_metadata_string_test() ->
    ?assertMatch(#{<<"ipfs_cid_v0">> := "Qmeqd4EMNioKGtjbUEZtwMh7ofQgGPygNkQb2R1WnV3Lb5",
                   <<"solc">> := <<0,8,11>>},
                 find_metadata_string(#{<<"input">> => <<"aaaaaa2646970667358221220f526f71758be50a30d18d1b69adbb5a711c18470247f481673d41046071a27d464736f6c634300080b0033bbbb">>})),
    ?assertEqual(nomatch,
                 find_metadata_string(#{<<"input">> => <<"0xe2bbb15800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000032bc59434456b6a9b">>})).

find_metadata_string(#{<<"input">> := Input}) ->
    case re:run(Input, "[aA]264.*0033", [{capture, all, binary}]) of
        {match, [M]} ->
            decode_cbor(M);
        nomatch ->
            % io:format(user, "Could not match ~p~n", [Input]),
            nomatch
    end.


decode_cbor(Bin) ->
    try erl_cbor:decode_hex(Bin) of
        {ok, I, R} ->
            B = I#{<<"ipfs_cid_v0">> => base58:binary_to_base58(maps:get(<<"ipfs">>, I))},
            case R of
                <<"0033", _/binary>> ->
                    B;
                _ ->
                    B#{rest => R}
            end
    catch E:R ->
            io:format(user, "Error when decoding ~p:~p~n", [E,R]),
            decode_failure
    end.

