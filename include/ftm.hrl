-define(BLOCK_TABLE, ftm_block_table).
-record(block,
        {id :: pos_integer(),
         is_reduced = false :: boolean(),
         transactions :: []
        }).
