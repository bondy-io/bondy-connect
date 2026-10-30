%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_meta_api_cluster_SUITE).

-moduledoc """
The WAMP Registration and Subscription Meta APIs on a two-node cluster: the
entries are split across the nodes and every meta call is made on node1, so
an answer about node2's entries comes through the RIB stubs and a call to
node2. The stubs converge eventually, so each case waits for node1 to see
node2's entry before it asserts.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.bondy_connect.cluster.meta_api").
-define(HOST, "127.0.0.1").
-define(NODE1_WAMP_PORT, 18211).
-define(NODE2_WAMP_PORT, 18212).

all() ->
    [
        subscription_match_includes_a_peer_subscription,
        registration_match_names_the_peer_best_registration,
        subscribers_count_excludes_a_peer_pattern_subscription,
        callee_list_names_only_the_exact_callees
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(
        [
            {bcx_meta1, [
                {[bondy_router, listeners], peer_listeners(?NODE1_WAMP_PORT)}
            ]},
            {bcx_meta2, [
                {[bondy_router, listeners], peer_listeners(?NODE2_WAMP_PORT)}
            ]}
        ],
        Config
    ),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    [{_, Node1, _}, {_, Node2, _}] = Nodes,
    _ = erpc:call(Node1, bondy_realm, create, [realm_config()]),
    ok = wait_until(fun() ->
        case erpc:call(Node2, bondy_realm, lookup, [?REALM]) of
            {ok, _} -> true;
            {error, not_found} -> false
        end
    end),
    ok = wait_until(fun() ->
        erpc:call(Node2, bondy_rbac_source, list, [?REALM]) =/= []
    end),
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

peer_listeners(WampPort) ->
    [
        {admin, #{
            transport => tcp,
            protocol => http,
            port => 0,
            start_phase => early,
            services => [admin_api, wamp_ws, admin, metrics]
        }},
        {wamp_tcp, #{
            transport => tcp,
            protocol => wamp_rawsocket,
            port => WampPort,
            enabled => true
        }}
    ].

%% =============================================================================
%% TESTS
%% =============================================================================

subscription_match_includes_a_peer_subscription(_) ->
    Uri = ~"com.example.cluster.meta.sub.leaf",
    {A, Exact} = subscribe(?NODE1_WAMP_PORT, Uri, #{}),
    {B, Prefix} = subscribe(
        ?NODE2_WAMP_PORT, ~"com.example.cluster.meta.sub", #{match => ~"prefix"}
    ),
    Expected = lists:sort([Exact, Prefix]),
    ok = wait_until(fun() ->
        lists:sort(call_one(~"wamp.subscription.match", [Uri])) == Expected
    end),
    disconnect([A, B]).

registration_match_names_the_peer_best_registration(_) ->
    Uri = ~"com.example.cluster.meta.reg.leaf",
    {A, _} = register(
        ?NODE1_WAMP_PORT, ~"com.example.cluster.meta.reg", #{match => ~"prefix"}
    ),
    {B, Exact} = register(?NODE2_WAMP_PORT, Uri, #{}),
    ok = wait_until(fun() ->
        call_args(~"wamp.registration.match", [Uri]) == [Exact]
    end),
    disconnect([A, B]).

%% node2's prefix subscription matches the URI of node1's exact one, so a
%% routing-direction count would include node2's subscriber.
subscribers_count_excludes_a_peer_pattern_subscription(_) ->
    Uri = ~"com.example.cluster.meta.count.leaf",
    {A, Exact} = subscribe(?NODE1_WAMP_PORT, Uri, #{}),
    {B, Prefix} = subscribe(
        ?NODE2_WAMP_PORT,
        ~"com.example.cluster.meta.count",
        #{match => ~"prefix"}
    ),
    ok = wait_until(fun() ->
        lists:member(Prefix, call_one(~"wamp.subscription.match", [Uri]))
    end),
    ?assertEqual(1, call_one(~"wamp.subscription.count_subscribers", [Exact])),
    ?assertEqual(
        [session_id(A)],
        call_one(~"wamp.subscription.list_subscribers", [Exact])
    ),
    disconnect([A, B]).

%% node1's prefix registration matches `Uri` too, so a routing-direction walk
%% would also list its callee.
callee_list_names_only_the_exact_callees(_) ->
    Uri = ~"com.example.cluster.meta.callees.leaf",
    {A, _} = register(
        ?NODE1_WAMP_PORT,
        ~"com.example.cluster.meta.callees",
        #{match => ~"prefix"}
    ),
    {B, _} = register(?NODE2_WAMP_PORT, Uri, #{}),
    Session = session_id(B),
    Callees = fun() ->
        #{~"values" := Values} = call_one(
            ~"bondy.registration.callee.list", [?REALM, Uri]
        ),
        [S || #{~"session_id" := S} <- Values]
    end,
    ok = wait_until(fun() -> lists:member(Session, Callees()) end),
    ?assertEqual([Session], Callees()),
    disconnect([A, B]).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
subscribe(Port, Uri, Opts) ->
    Conn = connect(Port),
    Ignore = fun(_, _, _) -> ok end,
    {ok, Id} = bondy_connect_client:subscribe(Conn, Uri, Ignore, Opts),
    {Conn, Id}.

%% @private
register(Port, Uri, Opts) ->
    Conn = connect(Port),
    Reply = fun(_, _, _) -> {ok, #{}} end,
    {ok, Id} = bondy_connect_client:register(Conn, Uri, Reply, Opts),
    {Conn, Id}.

%% @private
session_id(Conn) ->
    {ok, #{args := [#{~"session" := Id}]}} =
        bondy_connect_client:call(Conn, ~"bondy.session.self", []),
    Id.

%% @private
call_one(Uri, Args) ->
    [Value] = call_args(Uri, Args),
    Value.

%% @private
call_args(Uri, Args) ->
    Conn = connect(?NODE1_WAMP_PORT),
    {ok, #{args := Result}} = bondy_connect_client:call(Conn, Uri, Args),
    ok = bondy_connect_client:disconnect(Conn),
    Result.

%% @private
connect(Port) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    Conn.

%% @private
disconnect(Conns) ->
    lists:foreach(
        fun(Conn) -> ok = bondy_connect_client:disconnect(Conn) end, Conns
    ).

%% @private
wait_until(Fun) ->
    wait_until(Fun, 300).

%% @private
wait_until(_, 0) ->
    error(timeout);
wait_until(Fun, Retries) ->
    case Fun() of
        true ->
            ok;
        false ->
            ok = timer:sleep(100),
            wait_until(Fun, Retries - 1)
    end.

%% @private
realm_config() ->
    #{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    ~"wamp.register",
                    ~"wamp.unregister",
                    ~"wamp.subscribe",
                    ~"wamp.unsubscribe",
                    ~"wamp.call",
                    ~"wamp.publish"
                ],
                uri => ~"",
                match => ~"prefix",
                roles => [~"anonymous"]
            }
        ],
        sources => [
            #{
                usernames => [~"anonymous"],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => ~"0.0.0.0/0"
            }
        ]
    }.
