Rec = [{I, bondy_oplog_instance:reclaim_stable_cells(I)} || I <- bondy_oplog:list_instances()],
#{node => binary_to_list(bondy_config:nodestring()),
  retirement => bondy_oplog_origin_retirement:run(),
  reclaim_discarded => lists:sum([maps:get(discarded, M, 0) || {_, {ok, #{} = M}} <- Rec]),
  reclaim_scanned => lists:sum([maps:get(scanned, M, 0) || {_, {ok, #{} = M}} <- Rec]),
  reclaim_errors => [X || {_, {error, _} = X} <- Rec]}.
