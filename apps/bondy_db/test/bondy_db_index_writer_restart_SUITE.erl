%% =============================================================================
%% SPDX-FileCopyrightText: 2023 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% A restarted secondary writer replays the leftover intents of each durable
%% primary, then syncs that primary before any replayed op reaches the index.
%% An install's cells are not in the WAL and an open install group's intents
%% are not yet synced, so without the sync a crash could keep the replayed
%% index ops and lose the install
%% (`proofs/quint/configs/IndexIntents/InstallBatch_Writer_NoReplaySync.qnt`).
%% Each case runs on a durable single-bookie table with the rebuild server
%% held, so no rebuild delivers or marks anything:
%%
%% - `replay_syncs_the_primary_after_reading_its_intents/1`: the restarted
%%   writer reads the primary's intents, syncs, and only then writes the
%%   index, and the replayed op is indexed.
%% - `a_failed_replay_sync_marks_the_index_for_rebuild/1`: the writer's sync
%%   fails; it marks the index shards for rebuild, and a flush then writes
%%   nothing to the index.
%%
%% Not covered: the crash that loses unsynced cells. A killed process leaves
%% leveled's acknowledged writes in the OS page cache, so only a power loss
%% would drop them; the model checks that interleaving.

-module(bondy_db_index_writer_restart_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(R, <<"r1">>).
-define(INDEX, by_value).

all() ->
    [
        replay_syncs_the_primary_after_reading_its_intents,
        a_failed_replay_sync_marks_the_index_for_rebuild
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_db),
    ok = bondy_oplog_sync_scheduler:set_dispatch(undefined),
    ok = bondy_oplog_gc_scheduler:set_trigger(undefined),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    ok = filelib:ensure_path(Dir),
    {ok, Sup} = bondy_db_leveled_sup:start_link(),
    {ok, Db} = bondy_db:open(Case, #{
        topology => bondy_db_topology_single_bookie,
        topology_opts => #{sup => Sup, dir => filename:join(Dir, "leveled")},
        shard_count => 1,
        fold_module => lww_register,
        oplog_instance_opts => #{
            wal_dir => unicode:characters_to_binary(filename:join(Dir, "wal"))
        }
    }),
    {ok, Table} = bondy_db:open_table(Db, users, #{
        fold_module => lww_register,
        indexes => [#{name => ?INDEX, extract => []}]
    }),
    [{db, Db}, {table, Table} | Config].

end_per_testcase(_Case, Config) ->
    ok = bondy_db:close(?config(db, Config)).

%% =============================================================================
%% CASES
%% =============================================================================

replay_syncs_the_primary_after_reading_its_intents(Config) ->
    Table = ?config(table, Config),
    ok = bondy_db:apply(
        Table, ?R, <<"u1">>, {set, bondy_db:tick(Table), <<"on">>}
    ),
    ok = meck:new(bondy_db_projection_leveled, [passthrough]),
    ok = sys:suspend(bondy_oplog_index_rebuild),
    try
        [Writer] = restart_writers(Table),
        ok = flush_index(Table),
        Calls = [
            F
         || {Pid, {_M, F, _A}, _R} <- meck:history(bondy_db_projection_leveled),
            Pid =:= Writer
        ],
        {Read, [sync | AfterSync]} = lists:splitwith(
            fun(F) -> F =/= sync end, Calls
        ),
        ?assert(lists:member(range, Read)),
        ?assertNot(lists:member(put_batch, Read)),
        ?assert(lists:member(put_batch, AfterSync)),
        ?assertNot(lists:any(fun needs_rebuild/1, entries(Table))),
        ?assertEqual(
            {ok, [{<<"u1">>, #{}}]},
            bondy_db:index_get(Table, ?R, ?INDEX, <<"on">>, #{})
        )
    after
        meck:unload(bondy_db_projection_leveled),
        ok = sys:resume(bondy_oplog_index_rebuild)
    end.

a_failed_replay_sync_marks_the_index_for_rebuild(Config) ->
    Table = ?config(table, Config),
    ok = bondy_db:apply(
        Table, ?R, <<"u1">>, {set, bondy_db:tick(Table), <<"on">>}
    ),
    ok = flush_index(Table),
    ok = meck:new(bondy_db_projection_leveled, [passthrough]),
    ok = meck:expect(bondy_db_projection_leveled, sync, fun(Handle) ->
        case proc_lib:initial_call(self()) of
            {bondy_oplog_secondary_writer, init, _} -> {error, eio};
            {_Module, _Function, _Args} -> meck:passthrough([Handle]);
            false -> meck:passthrough([Handle])
        end
    end),
    ok = sys:suspend(bondy_oplog_index_rebuild),
    try
        [Writer] = restart_writers(Table),
        ok = flush_index(Table),
        ?assert(lists:all(fun needs_rebuild/1, entries(Table))),
        ?assertEqual(
            [],
            [
                F
             || {Pid, {_M, F, _A}, _R} <- meck:history(
                    bondy_db_projection_leveled
                ),
                Pid =:= Writer,
                F =:= put_batch
            ]
        )
    after
        meck:unload(bondy_db_projection_leveled),
        ok = sys:resume(bondy_oplog_index_rebuild)
    end,
    ok = wait_until(fun() ->
        not lists:any(fun needs_rebuild/1, entries(Table))
    end).

%% =============================================================================
%% HELPERS
%% =============================================================================

entries(Table) ->
    Info = bondy_db:info(Table),
    NS = maps:get(namespace, Info),
    #{?INDEX := #{sec_shard_count := N}} = maps:get(indexes, Info),
    [
        Entry
     || Shard <- lists:seq(0, N - 1),
        {ok, Entry} <- [bondy_oplog_core_registry:lookup(NS, ?INDEX, Shard)]
    ].

writer_pids(Table) ->
    lists:usort([
        bondy_oplog_core_registry:entry_writer_pid(E)
     || E <- entries(Table)
    ]).

%% Kills the table's writers and returns their successors once each row
%% carries a new live pid, which the successor stamps in `init/1` before it
%% replays.
restart_writers(Table) ->
    Old = writer_pids(Table),
    lists:foreach(
        fun(Pid) ->
            Ref = erlang:monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, killed} -> ok
            end
        end,
        Old
    ),
    ok = wait_until(fun() ->
        New = writer_pids(Table),
        lists:all(
            fun(P) ->
                is_pid(P) andalso is_process_alive(P) andalso
                    not lists:member(P, Old)
            end,
            New
        )
    end),
    writer_pids(Table).

%% A `flush_sync/1` call queues behind `init/1`, so it returns after the
%% replay and flushes what the replay buffered.
flush_index(Table) ->
    lists:foreach(
        fun(Pid) -> ok = bondy_oplog_secondary_writer:flush_sync(Pid) end,
        writer_pids(Table)
    ).

needs_rebuild(Entry) ->
    bondy_oplog_core_registry:index_needs_rebuild(Entry).

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, N - 1)
    end.
