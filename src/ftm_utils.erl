-module(ftm_utils).

-export([make_sure_storage_exist/0
        ]).

-include_lib("ftm_crawler/include/ftm.hrl").

make_sure_storage_exist() ->
    case mnesia:create_schema([node()]) of
        ok -> ok;
        {error,{_,{already_exists,_}}} -> ok
    end,
    ok = mnesia:start(),
    case mnesia:create_table(?BLOCK_TABLE,
                             [{record_name, block},
                              {index, [id]},
                              {attributes, record_info(fields, block)},
                              {disc_copies, [node()|nodes()]},
                              {storage_properties, [{ets, [compressed]},
                                                    {dets, [{auto_save, 5000}]}
                                                   ]}
                             ]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, ?BLOCK_TABLE}} ->
            ok
    end,
    ok = mnesia:wait_for_tables([?BLOCK_TABLE], 5000).
