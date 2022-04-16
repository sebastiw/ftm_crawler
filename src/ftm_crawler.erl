-module(ftm_crawler).

-compile(export_all).
-export([start/0]).

-include_lib("eunit/include/eunit.hrl").

-define(BLOCK_TABLE, ftm_block_table).
-define(NUM_BLOCKS_PER_FETCH, 100).


%% we want to end up in something like
-record(block,
        {id :: pos_integer(),
         fetched = false :: boolean(),
         transactions :: []
        }).

start() ->
    start(1,1).

%% Actually Number of ?NUM_BLOCKS_PER_FETCH blocks.
%% i.e. NumberOfBlocks=1000 with ?NUM_BLOCKS_PER_FETCH=100 would mean
%% a total of 100000 Blocks.
start(BlockId, NumberOfBlocks) ->
    make_sure_storage_exist(),
    crawl(BlockId, NumberOfBlocks).


crawl(BlockId, NumberOfBlocks) ->
    crawl(BlockId, NumberOfBlocks, ?NUM_BLOCKS_PER_FETCH).

crawl(BlockId, NumberOfBlocks, NumBlocksPerFetch) ->
    crawl(BlockId, NumberOfBlocks, NumBlocksPerFetch, 1, 1).

crawl(BlockId, NumberOfBlocks, MapSize, ReduceSize) ->
    crawl(BlockId, NumberOfBlocks, ?NUM_BLOCKS_PER_FETCH, MapSize, ReduceSize).

crawl(BlockId, NumberOfBlocks, NumBlocksPerFetch, 1, 1) ->
    BlockIDs = [{BlockId+I*NumBlocksPerFetch, undefined}
                || I <- lists:seq(0, NumberOfBlocks-1)],
    map_reduce:seq(fun map/2, fun reduce/2, BlockIDs);
crawl(BlockId, NumberOfBlocks, NumBlocksPerFetch, MapSize, ReduceSize) ->
    BlockIDs = [{BlockId+I*NumBlocksPerFetch, undefined}
                || I <- lists:seq(0, NumberOfBlocks-1)],
    map_reduce:par(fun map/2, MapSize, fun reduce/2, ReduceSize, BlockIDs).

make_sure_storage_exist() ->
    mnesia:create_schema([node()]),
    mnesia:start(),
    case mnesia:create_table(?BLOCK_TABLE,
                             [{record_name, block},
                              %% {index, [id]},
                              {attributes, record_info(fields, block)},
                              {ram_copies, [node()]},
                              {disc_only_copies, nodes()},
                              {storage_properties, [{ets, [compressed]},
                                                    {dets, [{auto_save, 5000}]}
                                                   ]}
                             ]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, ftm_block_table}} ->
            ok
    end.

map(K, undefined) ->
    Cache = [catch mnesia:dirty_read(?BLOCK_TABLE, K+I) || I <- lists:seq(0, ?NUM_BLOCKS_PER_FETCH-1)],
    InCache = fun ([]) -> false;
                  ({'EXIT', {aborted, {no_exists, N}}}) ->
                      ?debugVal(N),
                      false;
                  ([_]) -> true
              end,
    case lists:all(InCache, Cache) of
        false ->
            Bs = fetch_blocks(K, ?NUM_BLOCKS_PER_FETCH),
            Ts = [{convert_to_int(maps:get(<<"number">>, B)),
                   maps:get(<<"transactions">>, B, [])}
                  || B <- Bs],
            Ts;
        true ->
            [{B#block.id, B#block.transactions} || [B] <- Cache]
    end;
map(K, V) ->
    [{K, V}].

convert_to_int(<<"0x", B/binary>>) when byte_size(B) rem 2 == 0 ->
    D = binary:decode_hex(B),
    <<I:(bit_size(D))/big>> = D,
    I;
convert_to_int(<<"0x", B/binary>>) when byte_size(B) rem 2 == 1 ->
    convert_to_int(<<"0x0", B/binary>>).

reduce(K, Ts) ->
    Contracts = [clean_transaction(T) || T <- Ts, is_contract(T)],
    catch mnesia:dirty_write(?BLOCK_TABLE, #block{id = K, transactions = Contracts}),
    [{K, Contracts}].

clean_transaction(T) ->
    maps:with([<<"contractAddress">>, <<"from">>, <<"input">>, <<"hash">>], T).

fetch_blocks(FromBlock, NumBlocks) ->
    Url = "https://rpc.ankr.com/multichain",
    Headers = [],
    ContentType = "application/json",
    Body = jsx:encode(body(1, FromBlock, NumBlocks)),
    io:format("Fetching ~s (~p)~n", [Url, Body]),
    {ok, {_, _, B}} = httpc:request(post, {Url, Headers, ContentType, Body}, [], [{body_format, binary}]),
    #{<<"result">> := #{<<"blocks">> := Bs}} = jsx:decode(B),
    Bs.

is_contract(Transaction) ->
    ContractAddress = maps:get(<<"contractAddress">>, Transaction, null),
    null =/= ContractAddress.

body(CallId, FromBlock, NumBlocks) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"method">> => <<"ankr_getBlocksRange">>,
      <<"params">> =>
          #{<<"blockchain">> => <<"fantom">>,
            <<"fromBlock">> => FromBlock,
            <<"toBlock">> => FromBlock + NumBlocks
           },
      <<"id">> => CallId
     }.

a_test() ->
    Reply = reply(),
    meck:new(httpc),
    meck:expect(httpc, request, fun (_, R, _, _) -> ?debugVal(R), Reply end),
    Exp = [{9509443,
            [#{<<"contractAddress">> =>
                   <<"0xdfd84e3dcd39086a133479f5bc11cf01276cd507">>,
               <<"from">> =>
                   <<"0x11e465c310970d535bf61dd57095519ad38877ef">>,
               <<"hash">> =>
                   <<"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b">>,
               <<"input">> =>
                   <<"0xe2bbb15800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000032bc59434456b6a9b">>}]}],
    ?assertEqual(Exp, crawl(16#911a43, 1)).


reply() ->
    {ok,{{"HTTP/1.1",200,"OK"},
         [{"connection","keep-alive"},
          {"date","Sat, 09 Apr 2022 23:52:51 GMT"},
          {"server","cloudflare"},
          {"content-length","14310"},
          {"content-type","application/json"},
          {"access-control-allow-origin","*"},
          {"cf-cache-status","DYNAMIC"},
          {"access-control-allow-headers",
           "Content-Type,Authorization"},
          {"access-control-allow-methods","GET,POST,DELETE,OPTIONS"},
          {"access-control-max-age","86400"},
          {"expect-ct",
           "max-age=604800, report-uri=\"https://report-uri.cloudflare.com/cdn-cgi/beacon/expect-ct\""},
          {"cf-ray","6f9728aa9c8258f6-TXL"}],

         <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"blocks\":[{\"blockchain\":\"fantom\",\"number\":\"0x911a43\",\"hash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"parentHash\":\"0x00003d8e000014260c59a1b17139f1129fa12e07dbe4b65e30b5a24c2c792e4f\",\"nonce\":\"0x0000000000000000\",\"mixHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"sha3Uncles\":\"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347\",\"logsBloom\":\"0x00000000000000000000000000000000000000008400001000000000800000100000000000082200000000000000010008000000000020000000800000240000000000000009000001000008000000000000000000040000000000000000000004008008020000000040008000000800000000000000000010000010000200000000000100000000008000000800010000000400000000000000000000000810060002040000000008040000000000000020400400004800000003080000000000000002000000000000000041001000210000000000000200000100000060024010060000000000080000000000000000000000400480000000000000080000\",\"stateRoot\":\"0x5c7217df54c472d03bad9fb62e788eb82e739a2e4af773e6f72e077d810d8102\",\"miner\":\"0x0000000000000000000000000000000000000000\",\"difficulty\":\"0x0\",\"extraData\":\"0x\",\"size\":\"0x435\",\"gasLimit\":\"0xffffffffffff\",\"gasUsed\":\"0x76067\",\"timestamp\":\"0x60c4a110\",\"transactionsRoot\":\"0x2c5e931638dd5ef01ca5e934225327f88534673ea0052dda699d7ccf058ede95\",\"receiptsRoot\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"totalDifficulty\":\"0x0\",\"transactions\":[{\"v\":\"0x217\",\"r\":\"0xef3ebb32d5670ed21158a7b97b9b63221495bc9754db66c9325f97f63136bd4a\",\"s\":\"0x420295f17f73f64fc96f4fb3a37e019ee8ec24b9dd607e4e1c222458d155c11a\",\"nonce\":\"0x477\",\"from\":\"0x11e465c310970d535bf61dd57095519ad38877ef\",\"gas\":\"0x3bb56\",\"gasPrice\":\"0x1087ee0604\",\"input\":\"0xe2bbb15800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000032bc59434456b6a9b\",\"blockNumber\":\"0x911a43\",\"to\":null,\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"value\":\"0x0\",\"type\":\"0x0\",\"contractAddress\":\"0xdfd84e3dcd39086a133479f5bc11cf01276cd507\",\"cumulativeGasUsed\":\"0x24c81\",\"gasUsed\":\"0x24c81\",\"logs\":[{\"address\":\"0xed940c1db02a8e7dc2e6748aff3aab165b59c7e3\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"0x0000000000000000000000008eb17431443406bc80b6217f998f3b1c7162a818\"],\"data\":\"0x00000000000000000000000000000000000000000000000022b1c8c1227a0000\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x0\",\"removed\":false},{\"address\":\"0xed940c1db02a8e7dc2e6748aff3aab165b59c7e3\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"0x00000000000000000000000088d4de11ab29b892d6e371285ffdb3533568955f\"],\"data\":\"0x0000000000000000000000000000000000000000000000015af1d78b58c40000\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x1\",\"removed\":false},{\"address\":\"0xed940c1db02a8e7dc2e6748aff3aab165b59c7e3\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x00000000000000000000000088d4de11ab29b892d6e371285ffdb3533568955f\",\"0x00000000000000000000000011e465c310970d535bf61dd57095519ad38877ef\"],\"data\":\"0x00000000000000000000000000000000000000000000000002f89df5fcb75f65\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x2\",\"removed\":false},{\"address\":\"0xdfd84e3dcd39086a133479f5bc11cf01276cd507\",\"topics\":[\"0x71bab65ced2e5750775a0613be067df48ef06cf92a496ebf7663ae0660924954\",\"0x00000000000000000000000011e465c310970d535bf61dd57095519ad38877ef\",\"0x0000000000000000000000000000000000000000000000000000000000000001\"],\"data\":\"0x00000000000000000000000000000000000000000000000002f89df5fcb75f65\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x3\",\"removed\":false},{\"address\":\"0x31c782f4f7bdabc2f1ac02da1782ea6107c4cfcf\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x00000000000000000000000011e465c310970d535bf61dd57095519ad38877ef\",\"0x000000000000000000000000dfd84e3dcd39086a133479f5bc11cf01276cd507\"],\"data\":\"0x0000000000000000000000000000000000000000000000032bc59434456b6a9b\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x4\",\"removed\":false},{\"address\":\"0xdfd84e3dcd39086a133479f5bc11cf01276cd507\",\"topics\":[\"0x90890809c654f11d6e72a28fa60149770a0d11ec6c92319d6ceb2bb0a4ea1a15\",\"0x00000000000000000000000011e465c310970d535bf61dd57095519ad38877ef\",\"0x0000000000000000000000000000000000000000000000000000000000000001\"],\"data\":\"0x0000000000000000000000000000000000000000000000032bc59434456b6a9b\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"transactionIndex\":\"0x0\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x5\",\"removed\":false}],\"logsBloom\":\"0x0\",\"transactionHash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"hash\":\"0x02ba9129c44d2cacead8cedd2a2ba70267bf9e3f94a0c08855e7c2e71d009f9b\",\"status\":\"0x1\"},{\"v\":\"0x218\",\"r\":\"0x66a60df9cc7f036caaec0221c535f3510f41e9ae35ad95907ba29741ba0e4f50\",\"s\":\"0x1af671518d04f15a1d0bfd2a18dd87a28462bd2c6f345745121f8bc93cf0f5de\",\"nonce\":\"0x9dd\",\"from\":\"0x922d92e77293e7d65300fa9478114c73ea6ad6e4\",\"gas\":\"0x14196\",\"gasPrice\":\"0x1087ee0603\",\"input\":\"0x441a3e7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\",\"blockNumber\":\"0x911a43\",\"to\":\"0xcc0a87f7e7c693042a9cc703661f5060c80acb43\",\"transactionIndex\":\"0x1\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"value\":\"0x0\",\"type\":\"0x0\",\"contractAddress\":null,\"cumulativeGasUsed\":\"0x38e17\",\"gasUsed\":\"0x14196\",\"logs\":[{\"address\":\"0x4cdf39285d7ca8eb3f090fda0c069ba5f4145b37\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x000000000000000000000000cc0a87f7e7c693042a9cc703661f5060c80acb43\",\"0x000000000000000000000000922d92e77293e7d65300fa9478114c73ea6ad6e4\"],\"data\":\"0x000000000000000000000000000000000000000000000000005ce771d03929c1\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xca4a0224997d17e999bf8651a7b09ee7696a1e010836f48cf3b65c492b67cb47\",\"transactionIndex\":\"0x1\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x6\",\"removed\":false},{\"address\":\"0xcc0a87f7e7c693042a9cc703661f5060c80acb43\",\"topics\":[\"0xe2403640ba68fed3a2f88b7557551d1993f84b99bb10ff833f0cf8db0c5e0486\",\"0x000000000000000000000000922d92e77293e7d65300fa9478114c73ea6ad6e4\"],\"data\":\"0x000000000000000000000000000000000000000000000000005ce771d03929c1\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xca4a0224997d17e999bf8651a7b09ee7696a1e010836f48cf3b65c492b67cb47\",\"transactionIndex\":\"0x1\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x7\",\"removed\":false},{\"address\":\"0xcc0a87f7e7c693042a9cc703661f5060c80acb43\",\"topics\":[\"0xf279e6a1f5e320cca91135676d9cb6e44ca8a08c0b88342bcdb1144f6511b568\",\"0x000000000000000000000000922d92e77293e7d65300fa9478114c73ea6ad6e4\",\"0x0000000000000000000000000000000000000000000000000000000000000000\"],\"data\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xca4a0224997d17e999bf8651a7b09ee7696a1e010836f48cf3b65c492b67cb47\",\"transactionIndex\":\"0x1\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x8\",\"removed\":false}],\"logsBloom\":\"0x0\",\"transactionHash\":\"0xca4a0224997d17e999bf8651a7b09ee7696a1e010836f48cf3b65c492b67cb47\",\"hash\":\"0xca4a0224997d17e999bf8651a7b09ee7696a1e010836f48cf3b65c492b67cb47\",\"status\":\"0x1\"},{\"v\":\"0x217\",\"r\":\"0x639879557946976fd69004abef3738679cbd70260778faed30e3d951b21881a4\",\"s\":\"0x420c3905168214ac593e560614c92f9c4eda268baa0b1a003cfd7f81d12d2db9\",\"nonce\":\"0x4b\",\"from\":\"0x93623ba07c49ac9d93755f56bb5facbebcafaa18\",\"gas\":\"0x7a120\",\"gasPrice\":\"0x1087ee0603\",\"input\":\"0xe2bbb15800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a3eb210272cd5a2\",\"blockNumber\":\"0x911a43\",\"to\":\"0xacaca07e398d4946ad12232f40f255230e73ca72\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"value\":\"0x0\",\"type\":\"0x0\",\"contractAddress\":null,\"cumulativeGasUsed\":\"0x76067\",\"gasUsed\":\"0x3d250\",\"logs\":[{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x000000000000000000000000acaca07e398d4946ad12232f40f255230e73ca72\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\"],\"data\":\"0x0000000000000000000000000000000000000000000000000044f640f96ea73a\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x9\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xdec2bacdd2f05b59de34da9b523dff8be42e5e38e818c82fdb0bae774387a724\",\"0x000000000000000000000000acaca07e398d4946ad12232f40f255230e73ca72\"],\"data\":\"0x00000000000000000000000000000000000000000000e790046ddac9130feabf00000000000000000000000000000000000000000000e7900428e48819a14385\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xa\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xdec2bacdd2f05b59de34da9b523dff8be42e5e38e818c82fdb0bae774387a724\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\"],\"data\":\"0x0000000000000000000000000000000000000000000000000a3eb210272cd5a20000000000000000000000000000000000000000000000000a83a851209b7cdc\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xb\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\",\"0x000000000000000000000000acaca07e398d4946ad12232f40f255230e73ca72\"],\"data\":\"0x0000000000000000000000000000000000000000000000000a3eb210272cd5a2\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xc\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\",\"0x000000000000000000000000acaca07e398d4946ad12232f40f255230e73ca72\"],\"data\":\"0xffffffffffffffffffffffffffffffffffffffffffffffffdb5c834ecfe90dfa\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xd\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xdec2bacdd2f05b59de34da9b523dff8be42e5e38e818c82fdb0bae774387a724\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\"],\"data\":\"0x0000000000000000000000000000000000000000000000000a83a851209b7cdc0000000000000000000000000000000000000000000000000044f640f96ea73a\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xe\",\"removed\":false},{\"address\":\"0x841fad6eae12c286d1fd18d1d525dffa75c7effe\",\"topics\":[\"0xdec2bacdd2f05b59de34da9b523dff8be42e5e38e818c82fdb0bae774387a724\",\"0x000000000000000000000000acaca07e398d4946ad12232f40f255230e73ca72\"],\"data\":\"0x00000000000000000000000000000000000000000000e7900428e48819a1438500000000000000000000000000000000000000000000e7900e67969840ce1927\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0xf\",\"removed\":false},{\"address\":\"0xacaca07e398d4946ad12232f40f255230e73ca72\",\"topics\":[\"0x90890809c654f11d6e72a28fa60149770a0d11ec6c92319d6ceb2bb0a4ea1a15\",\"0x00000000000000000000000093623ba07c49ac9d93755f56bb5facbebcafaa18\",\"0x0000000000000000000000000000000000000000000000000000000000000000\"],\"data\":\"0x0000000000000000000000000000000000000000000000000a3eb210272cd5a2\",\"blockNumber\":\"0x911a43\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"transactionIndex\":\"0x2\",\"blockHash\":\"0x00003d8e00001430776c761752f14606dd91c804d32c1172e2361a74b553e8ad\",\"logIndex\":\"0x10\",\"removed\":false}],\"logsBloom\":\"0x0\",\"transactionHash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"hash\":\"0xc6a2086e69adf25a04f5bf95db84e7190e2c1822e3026a7e7618a59fa5f5a288\",\"status\":\"0x1\"}],\"uncles\":[]}]}}">>}}.
