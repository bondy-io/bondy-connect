ByLabel = fun(Name, Key) ->
    lists:foldl(
        fun({L, V}, A) ->
            K = case lists:keyfind(Key, 1, L) of {_, X} -> X; false -> none end,
            maps:update_with(K, fun(Y) -> Y + V end, V, A)
        end, #{}, prometheus_counter:values(default, Name)) end,
Total = fun(Name) ->
    lists:sum([V || {_, V} <- prometheus_counter:values(default, Name)]) end,
#{node => binary_to_list(bondy_config:nodestring()),
  is_ready => bondy_router_app:is_ready(),
  alarms => bondy_alarm_api:local_alarms(),
  stalled_by_reason => ByLabel(bondy_oplog_reclamation_stalled_total, reason),
  sweep_by_result => ByLabel(bondy_oplog_applier_sweep_cells_total, result),
  origins_reaped => Total(bondy_oplog_applier_origins_reaped_total),
  retirements => ByLabel(bondy_oplog_retirements_total, outcome)}.
