%% =============================================================================
%% Crash-injection coverage for the staged-root debounce.
%%
%% The pack writer debounces manifest rewrites: `set_root/2` updates the
%% in-memory manifest but only fsyncs the on-disk file when the policy
%% fires (`root_flush_every_records` / `root_flush_every_ms`).
%% `close/1` / `flush/1` / `seal/1` force a final write so clean
%% shutdown is lossless. The crash window is the gap between a
%% `set_root/2` call and the next debounce flush: a hard exit there
%% should leave the on-disk root at the previously persisted value,
%% and a subsequent WAL replay (or any other authoritative `set_root`
%% caller) should be able to bring the on-disk root back to the
%% in-memory value.
%%
%% This module spawns a peer node, drives the store from there, and
%% SIGKILLs the peer between `set_root/2` and any debounce flush. The
%% parent then opens the store directly and verifies both halves.
%%
%% It also SIGKILLs a sealing peer, in both seal modes, right before and
%% right after the first call of each exported `bondy_mst_pack_seal' function
%% and of `bondy_mst_pack_manifest:write/2' (wrapped with meck on the peer),
%% and checks that the store reopens and that, after reopening, every sealed
%% pack the manifest names has its pack and index files, and that every page of a seal the peer
%% reported complete is readable. A function the seal path does not call
%% through its module is reported `not_reached'. SIGKILL ends the VM but not
%% the OS, so writes still in the page cache survive: this does not cover
%% power loss.
%% =============================================================================

-module(bondy_mst_pack_crash_injection_test).

-include_lib("eunit/include/eunit.hrl").

%% Invoked by the peer via erpc:call/4.
-export([peer_stage_root/4]).
-export([peer_seal_killed_at/5]).

-define(STAGED_TAG, staged_ack).

%% =============================================================================
%% Eunit entry
%% =============================================================================

%% Slightly looser timeout: peer boot + kill -9 + manifest fsyncs.
crash_loses_staged_root_wal_replay_recovers_test_() ->
    {timeout, 60, fun crash_loses_staged_root_wal_replay_recovers/0}.

crash_loses_staged_root_wal_replay_recovers() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = ensure_distribution(),
    Dir = mk_tmp_dir(),
    InstId = mk_inst_id(),
    Persisted = sha256(<<"persisted-root">>),
    Staged = sha256(<<"staged-root">>),
    Pages = mk_pages([{k1, v1}, {k2, v2}, {k3, v3}]),
    try
        %% Persist R0 on parent with low threshold so the
        %% set_root call fsyncs immediately. Close cleanly.
        Store0 = bondy_mst_pack_store:open(sha256, #{
            dir => Dir,
            instance_id => InstId,
            root_flush_every_records => 1,
            root_flush_every_ms => infinity
        }),
        Store1 = bondy_mst_pack_store:set_root(Store0, Persisted),
        ok = bondy_mst_pack_store:close(Store1),
        ?assertEqual(Persisted, on_disk_root(Dir)),

        %% The peer reopens the SAME dir with debounce off, appends
        %% synced pages, stages R1, and parks (no close, no flush).
        {ok, Peer, Node} = start_peer(),
        try
            ok = setup_peer(Node),
            PeerOsPid = peer_os_pid(Node),
            ?STAGED_TAG = erpc:call(
                Node,
                ?MODULE,
                peer_stage_root,
                [Dir, InstId, Staged, Pages]
            ),

            %% kill -9. peer:start_link/1 linked the peer to
            %% us; trap_exit catches the linked exit.
            _ = os:cmd("kill -9 " ++ integer_to_list(PeerOsPid)),
            ok = await_peer_exit(Peer, 5_000)
        after
            try
                peer:stop(Peer)
            catch
                _:_ -> ok
            end
        end,

        %% The staged R1 is lost. The on-disk manifest is
        %% still at R0 because no debounce ever fired on the peer.
        ?assertEqual(Persisted, on_disk_root(Dir)),

        %% Simulate WAL replay: reopen, observe R0, write R1
        %% authoritatively, close. The on-disk root catches up.
        Store2 = bondy_mst_pack_store:open(sha256, #{
            dir => Dir,
            instance_id => InstId,
            root_flush_every_records => 1,
            root_flush_every_ms => infinity
        }),
        ?assertEqual(Persisted, bondy_mst_pack_store:get_root(Store2)),
        %% Pages appended before the crash were sync_every_records=1 on
        %% the peer, so they should still be visible.
        lists:foreach(
            fun(Page) ->
                Hash = bondy_mst_page:hash(Page, sha256),
                ?assertEqual(Page, bondy_mst_pack_store:get(Store2, Hash))
            end,
            Pages
        ),
        Store3 = bondy_mst_pack_store:set_root(Store2, Staged),
        ok = bondy_mst_pack_store:close(Store3),
        ?assertEqual(Staged, on_disk_root(Dir))
    after
        rmrf(Dir)
    end.

kill_at_each_seal_boundary_leaves_a_store_that_reopens_test_() ->
    {timeout, 600, fun kill_at_each_seal_boundary/0}.

kill_at_each_seal_boundary() ->
    process_flag(trap_exit, true),
    {ok, _} = application:ensure_all_started(telemetry),
    ok = ensure_distribution(),
    Points = [
        {Mode, Mod, Fun, Arity, When}
     || Mode <- [sync, async],
        {Mod, Fun, Arity} <-
            [{bondy_mst_pack_manifest, write, 2}] ++
            [
                {bondy_mst_pack_seal, F, A}
             || {F, A} <- bondy_mst_pack_seal:module_info(exports),
                F =/= module_info
            ],
        When <- [before, 'after']
    ],
    Outcomes = [{Point, kill_at(Point)} || Point <- Points],
    ?debugFmt("seal boundary kills: ~w", [
        [P || {P, killed} <- Outcomes]
    ]),
    %% A boundary the seal path never calls proves nothing, so the manifest
    %% write must have been reached on both sides in each mode.
    [
        ?assertEqual(
            {Mode, When, killed},
            {Mode, When, proplists:get_value(
                {Mode, bondy_mst_pack_manifest, write, 2, When}, Outcomes
            )}
        )
     || Mode <- [sync, async], When <- [before, 'after']
    ].

kill_at({Mode, Mod, Fun, Arity, When} = Point) ->
    Dir = mk_tmp_dir(),
    InstId = mk_inst_id(),
    try
        {ok, Peer, Node} = start_peer(),
        ok = setup_peer(Node),
        ok = erpc:cast(
            Node,
            ?MODULE,
            peer_seal_killed_at,
            [self(), Dir, InstId, Mode, {Mod, Fun, Arity, When}]
        ),
        Outcome =
            receive
                {'EXIT', Peer, _} -> killed;
                {boundary_not_reached, Node} -> not_reached
            after 30_000 -> error({no_outcome, Point})
            end,
        ok = stop_if_alive(Outcome, Peer),
        Sealed = sealed_acks([]),
        Store = bondy_mst_pack_store:open(sha256, #{
            dir => Dir, instance_id => InstId
        }),
        {ok, M} = bondy_mst_pack_manifest:read(Dir),
        ?assertEqual(
            {Point, []},
            {Point, [
                Id
             || Id <- bondy_mst_pack_manifest:sealed_packs(M),
                not (filelib:is_regular(pack_file(Dir, Id, ".pack")) andalso
                    filelib:is_regular(pack_file(Dir, Id, ".idx")))
            ]}
        ),
        ?assertEqual(
            {Point, []},
            {Point, [
                Hash
             || {_PackId, Hashes} <- Sealed,
                Hash <- Hashes,
                not is_tuple(bondy_mst_pack_store:get(Store, Hash))
            ]}
        ),
        ok = bondy_mst_pack_store:close(Store),
        Outcome
    after
        rmrf(Dir)
    end.

stop_if_alive(killed, _Peer) ->
    ok;
stop_if_alive(not_reached, Peer) ->
    ok = peer:stop(Peer),
    receive
        {'EXIT', Peer, _} -> ok
    after 10_000 -> error(peer_did_not_stop)
    end.

sealed_acks(Acc) ->
    receive
        {pack_sealed, PackId, Hashes} -> sealed_acks([{PackId, Hashes} | Acc])
    after 0 ->
        Acc
    end.

pack_file(Dir, Id, Ext) ->
    filename:join(Dir, lists:flatten(io_lib:format("pack-~4..0B~s", [Id, Ext]))).

%% =============================================================================
%% Peer-side entry
%% =============================================================================

%% Runs on the peer: seals one pack cleanly, then wraps `Mod:Fun/Arity' so its
%% first call kills this VM `When' it runs, and seals a second pack. Reports
%% `boundary_not_reached' if the second seal completes without calling it.
peer_seal_killed_at(Parent, Dir, InstId, Mode, {Mod, Fun, Arity, When}) ->
    Store0 = bondy_mst_pack_store:open(sha256, #{
        dir => Dir,
        instance_id => InstId,
        seal_mode => Mode,
        sync_every_records => 1,
        sync_every_ms => infinity,
        auto_seal_records => 50,
        auto_seal_bytes => infinity
    }),
    Store1 = put_and_seal(Parent, Mode, 1, Store0),
    ok = meck:new(Mod, [passthrough, no_link]),
    ok = meck:expect(Mod, Fun, killing(Arity, When)),
    _ = put_and_seal(Parent, Mode, 2, Store1),
    Parent ! {boundary_not_reached, node()},
    ok.

put_and_seal(Parent, Mode, N, Store0) ->
    Pages = [
        bondy_mst_page:new(0, undefined, [{{N, I}, I, undefined}])
     || I <- lists:seq(1, 50)
    ],
    Store1 = lists:foldl(
        fun(Page, Acc) ->
            {_Hash, Acc1} = bondy_mst_pack_store:put(Acc, Page),
            Acc1
        end,
        Store0,
        Pages
    ),
    {PackId, Store2} = peer_seal(Mode, Store1),
    Parent ! {pack_sealed, PackId, [bondy_mst_page:hash(P, sha256) || P <- Pages]},
    Store2.

killing(2, When) -> fun(A, B) -> kill_around(When, [A, B]) end;
killing(3, When) -> fun(A, B, C) -> kill_around(When, [A, B, C]) end;
killing(4, When) -> fun(A, B, C, D) -> kill_around(When, [A, B, C, D]) end;
killing(6, When) ->
    fun(A, B, C, D, E, F) -> kill_around(When, [A, B, C, D, E, F]) end.

kill_around(before, _Args) ->
    kill_self();
kill_around('after', Args) ->
    _ = meck:passthrough(Args),
    kill_self().

kill_self() ->
    _ = os:cmd("kill -9 " ++ os:getpid()),
    timer:sleep(infinity).

peer_seal(sync, Store0) ->
    {ok, Store} = bondy_mst_pack_store:seal(Store0),
    {lists:last(bondy_mst_pack_store:sealed_pack_ids(Store)), Store};
peer_seal(async, Store0) ->
    {rolled, Job, Store1} = bondy_mst_pack_store:maybe_roll_for_seal(Store0),
    PackId = maps:get(pack_id, Job),
    ok = bondy_mst_pack_store:run_seal_job(Job),
    {ok, Store} = bondy_mst_pack_store:complete_seal(Store1, PackId),
    {PackId, Store}.


%% Runs on the peer node. Opens the store with the manifest debounce
%% effectively disabled, appends synced pages, stages a new root, and
%% intentionally returns without closing or flushing. The store stays
%% open in the peer's process tree until the parent SIGKILLs the VM.
peer_stage_root(Dir, InstId, StagedRoot, Pages) ->
    Store0 = bondy_mst_pack_store:open(sha256, #{
        dir => Dir,
        instance_id => InstId,
        %% Manifest debounce off so set_root/2 never fsyncs.
        root_flush_every_records => infinity,
        root_flush_every_ms => infinity,
        %% Append path fully synced so post-crash reopen sees the pages.
        sync_every_records => 1,
        sync_every_ms => infinity,
        %% Auto-seal off — a seal would force a manifest rewrite.
        auto_seal_records => infinity,
        auto_seal_bytes => infinity
    }),
    Store1 = lists:foldl(
        fun(Page, Acc) ->
            {_Hash, Acc1} = bondy_mst_pack_store:put(Acc, Page),
            Acc1
        end,
        Store0,
        Pages
    ),
    _Store2 = bondy_mst_pack_store:set_root(Store1, StagedRoot),
    %% Leak the store deliberately. The parent SIGKILLs the BEAM next.
    ?STAGED_TAG.

%% =============================================================================
%% Distribution + peer plumbing
%% =============================================================================

ensure_distribution() ->
    case net_kernel:get_state() of
        #{started := no} ->
            %% Longnames `@127.0.0.1` to match the peer's host (see
            %% start_peer/0). A shortnames controller plus a `@127.0.0.1`
            %% peer name is rejected with `nodistribution`. OTP 28 dropped
            %% the legacy list form `net_kernel:start([Name, longnames])`,
            %% so use start/2.
            Name = list_to_atom(
                "bondymst_crash_" ++
                    integer_to_list(os:system_time(microsecond)) ++
                    "@127.0.0.1"
            ),
            {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
            true = erlang:set_cookie(node(), bondymsttestcookie),
            ok;
        _ ->
            ok
    end.

start_peer() ->
    Name = list_to_atom(
        "bondymst_crash_peer_" ++
            integer_to_list(os:system_time(microsecond))
    ),
    Cookie = atom_to_list(erlang:get_cookie()),
    PeerOpts = #{
        name => Name,
        host => "127.0.0.1",
        connection => standard_io,
        args => ["-setcookie", Cookie, "-pa" | code:get_path()]
    },
    peer:start_link(PeerOpts).

setup_peer(Node) ->
    %% `telemetry` is started explicitly because the bondy_mst put path
    %% emits events; without it the peer logs
    %% "Failed to lookup telemetry handlers" warnings. Wait for the
    %% backing ETS table to exist before returning so subsequent puts
    %% don't race the supervisor.
    {ok, _} = erpc:call(Node, application, ensure_all_started, [telemetry]),
    {ok, _} = erpc:call(Node, application, ensure_all_started, [bondy_mst]),
    ok = wait_for_telemetry_table(Node, 50),
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

wait_for_telemetry_table(_Node, 0) ->
    %% Cosmetic only — proceed even if the table never showed up.
    ok;
wait_for_telemetry_table(Node, N) ->
    case erpc:call(Node, ets, whereis, [telemetry_handler_table]) of
        undefined ->
            timer:sleep(20),
            wait_for_telemetry_table(Node, N - 1);
        _Tid ->
            ok
    end.

peer_os_pid(Node) ->
    list_to_integer(erpc:call(Node, os, getpid, [])).

await_peer_exit(Peer, TimeoutMs) ->
    receive
        {'EXIT', Peer, _Reason} -> ok
    after TimeoutMs ->
        %% Belt-and-braces: peer:stop will reap any zombie state.
        try
            peer:stop(Peer)
        catch
            _:_ -> ok
        end,
        ok
    end.

%% =============================================================================
%% Misc helpers
%% =============================================================================

mk_tmp_dir() ->
    Base = filename:join(
        [
            "/tmp",
            io_lib:format(
                "bondy_mst_pack_crash_injection_~p_~p",
                [
                    erlang:system_time(microsecond),
                    erlang:unique_integer([positive])
                ]
            )
        ]
    ),
    Dir = lists:flatten(Base),
    ok = filelib:ensure_path(Dir),
    Dir.

rmrf(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.

mk_inst_id() ->
    iolist_to_binary(
        io_lib:format("crash-inj-~p", [erlang:unique_integer([positive])])
    ).

sha256(Bin) ->
    crypto:hash(sha256, Bin).

mk_pages(KVs) ->
    [bondy_mst_page:new(0, undefined, [{K, V, undefined}]) || {K, V} <- KVs].

on_disk_root(Dir) ->
    {ok, M} = bondy_mst_pack_manifest:read(Dir),
    bondy_mst_pack_manifest:current_root(M).
