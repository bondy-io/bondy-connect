[{M, F, A} || {M, F, A} <- [
        {bondy_db, fold, 6}, {bondy_namespace_catalog, table, 1},
        {bondy_registry_rib, realm_nodestrings, 2}, {bondy_config, nodestring, 0},
        {partisan_peer_service, members, 0},
        {partisan_peer_service, members_for_orchestration, 0},
        {partisan_peer_service, leave, 1}, {bondy_router_app, is_ready, 0},
        {bondy_alarm_api, local_alarms, 0}, {bondy_oplog_origin_retirement, run, 0},
        {bondy_oplog_instance, reclaim_stable_cells, 1}, {bondy_oplog, list_instances, 0},
        {prometheus_counter, values, 2}],
    not (code:ensure_loaded(M) =:= {module, M} andalso erlang:function_exported(M, F, A))].
