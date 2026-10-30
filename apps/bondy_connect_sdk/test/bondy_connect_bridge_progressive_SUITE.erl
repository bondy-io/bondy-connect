%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_bridge_progressive_SUITE).

-moduledoc """
Progressive call invocations across a bridge relay: an edge router dials the
core's `bridge_relay` listener. A callee connected to the edge is proxied into
the core's registry, and a caller connected to the core streams its arguments
to it. Both clients are SDK clients in the CT node.

In `bridge_on_the_caller_node` the core is one sovereign router
(`bondy_ct:start_nodes/2`). In `bridge_on_another_core_node` the core is a
two-node cluster: the bridge ends on the second node and the caller connects
to the first, which reaches the callee node-addressed.

The bridge setup is `bondy_bridge_relay_rpc_SUITE`'s, called on the edge.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(CORE, bcx_bridge_core).
-define(EDGE, bcx_bridge_edge).
-define(CORE1, bcx_bridge_core1).
-define(CORE2, bcx_bridge_core2).
-define(CLUSTER_EDGE, bcx_bridge_cluster_edge).
-define(REALM, ~"com.example.bondy_connect.bridge_progressive").
-define(DEVICE, ~"ct_device").
-define(HOST, "127.0.0.1").
-define(CORE_PORT, 18301).
-define(EDGE_PORT, 18302).
-define(CORE1_PORT, 18303).
-define(CORE2_PORT, 18304).
-define(CLUSTER_EDGE_PORT, 18305).

all() ->
    [
        {group, bridge_on_the_caller_node},
        {group, bridge_on_another_core_node}
    ].

groups() ->
    FirstChunk = [
        a_call_reaches_a_bridged_callee,
        a_bridged_callee_without_the_feature_lacks_it
    ],
    Stream = [a_progressive_call_streams_across_a_bridge],
    Cancel = [
        a_canceled_stream_interrupts_the_bridged_callee,
        a_caller_leaving_a_stream_interrupts_the_bridged_callee
    ],
    [
        {bridge_on_the_caller_node, [], FirstChunk ++ Stream ++ Cancel},
        {bridge_on_another_core_node, [], FirstChunk ++ Stream ++ Cancel}
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(bridge_on_the_caller_node, Config) ->
    Nodes = bondy_ct:start_nodes(
        [
            {?CORE, [
                {[bondy_router, listeners], [
                    {bridge, #{
                        transport => tcp, protocol => bridge_relay, port => 0
                    }}
                    | listeners(?CORE_PORT)
                ]}
            ]},
            {?EDGE, [{[bondy_router, listeners], listeners(?EDGE_PORT)}]}
        ],
        Config
    ),
    [{_, Core, _}, {_, Edge, _}] = Nodes,
    #{public := Pub} = KeyPair = bondy_cryptosign:generate_key(),
    _ = erpc:call(Core, bondy_realm, create, [core_realm(Pub)]),
    ok = add_bridge(Core, Edge, KeyPair),
    Visible = fun(Proc) ->
        erpc:call(Core, bondy_registry, has_matches, [
            registration, ?REALM, Proc
        ])
    end,
    [
        {nodes, Nodes},
        {bridge_node, Core},
        {caller_port, ?CORE_PORT},
        {callee_port, ?EDGE_PORT},
        {proxy_visible, Visible}
        | Config
    ];
init_per_group(bridge_on_another_core_node, Config) ->
    Core = bondy_ct:start_cluster(
        [
            {?CORE1, [{[bondy_router, listeners], listeners(?CORE1_PORT)}]},
            {?CORE2, [
                {[bondy_router, listeners], [
                    {bridge, #{
                        transport => tcp, protocol => bridge_relay, port => 0
                    }}
                    | listeners(?CORE2_PORT)
                ]}
            ]}
        ],
        Config
    ),
    %% `start_nodes/2` numbers this node 1, as `start_cluster/2` numbered
    %% CORE1, and derives the partisan peer port and the admin socket's runtime
    %% directory from that number; the edge takes a third node's.
    PeerPort = 18086 + 3,
    RuntimeDir = filename:join(
        "/tmp", "bondy_ct_" ++ os:getpid() ++ "_" ++ integer_to_list(PeerPort)
    ),
    ok = filelib:ensure_path(RuntimeDir),
    [{_, Edge, _}] =
        EdgeNodes = bondy_ct:start_nodes(
            [
                {?CLUSTER_EDGE, [
                    {[bondy_router, listeners], listeners(?CLUSTER_EDGE_PORT)},
                    {[bondy_router, platform_runtime_dir], RuntimeDir},
                    {[partisan, peer_port], PeerPort}
                ]}
            ],
            Config
        ),
    [{_, Core1, _}, {_, Core2, _}] = Core,
    #{public := Pub} = KeyPair = bondy_cryptosign:generate_key(),
    _ = erpc:call(Core1, bondy_realm, create, [core_realm(Pub)]),
    ok = wait_until(
        fun() ->
            case erpc:call(Core2, bondy_rbac_user, lookup, [?REALM, ?DEVICE]) of
                {ok, _} ->
                    erpc:call(Core2, bondy_rbac_source, list, [?REALM]) =/= [];
                {error, not_found} ->
                    false
            end
        end,
        erlang:monotonic_time(millisecond) + 30000,
        realm_not_replicated
    ),
    ok = add_bridge(Core2, Edge, KeyPair),
    Visible = fun(Proc) ->
        erpc:call(Core1, bondy_registry_rib, match_stubs, [?REALM, Proc]) =/=
            []
    end,
    [
        {nodes, Core ++ EdgeNodes},
        {bridge_node, Core2},
        {caller_port, ?CORE1_PORT},
        {callee_port, ?CLUSTER_EDGE_PORT},
        {proxy_visible, Visible}
        | Config
    ].

end_per_group(_, Config) ->
    ok = bondy_ct:stop_cluster(?config(nodes, Config)).

%% =============================================================================
%% TESTS
%% =============================================================================

-doc "A plain call reaches a callee on the other side of a bridge.".
a_call_reaches_a_bridged_callee(Config) ->
    Proc = ~"com.example.bridge.echo",
    Callee = connect(?config(callee_port, Config)),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun(Args, _, _) ->
        {ok, #{args => Args}}
    end),
    ok = wait_proxy(Config, Proc),

    Caller = connect(?config(caller_port, Config)),
    ?assertMatch(
        {ok, #{args := [1]}}, bondy_connect_client:call(Caller, Proc, [1])
    ),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
Every chunk of a progressive call reaches a callee on the other side of a
bridge, and the caller gets the callee's result. The result settles the call
promise on the bridge's node.
""".
a_progressive_call_streams_across_a_bridge(Config) ->
    Proc = ~"com.example.bridge.sum",
    Callee = connect(?config(callee_port, Config)),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun sum_input/3),
    ok = wait_proxy(Config, Proc),

    Caller = connect(?config(caller_port, Config)),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    ok = bondy_connect_client:send_input(Caller, Token, [2], #{}),
    ok = bondy_connect_client:finish_input(Caller, Token, [3], #{}),
    ?assertMatch({ok, #{args := [6]}}, next_reply(Token)),
    ok = assert_no_call_promise(Config),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A bridged callee that did not announce the feature gets no progressive call:
the caller gets `wamp.error.feature_not_supported`.
""".
a_bridged_callee_without_the_feature_lacks_it(Config) ->
    Proc = ~"com.example.bridge.unsupported",
    TestPid = self(),
    Callee = connect(?config(callee_port, Config), #{
        roles => #{callee => #{features => #{call_canceling => true}}}
    }),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun(_, _, _) ->
        TestPid ! handler_ran,
        {ok, #{args => []}}
    end),
    ok = wait_proxy(Config, Proc),

    Caller = connect(?config(caller_port, Config)),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    ?assertMatch(
        {error, #{uri := ?WAMP_FEATURE_NOT_SUPPORTED}}, next_reply(Token)
    ),
    receive
        handler_ran -> ct:fail(handler_ran)
    after 300 -> ok
    end,

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A `killnowait` CANCEL of a stream reaches the bridged callee: the caller gets
`wamp.error.canceled`, the callee's handler is interrupted, and the bridge's
node keeps no call promise.
""".
a_canceled_stream_interrupts_the_bridged_callee(Config) ->
    {Worker, Callee, Caller, Token} = start_stream(
        Config, ~"com.example.bridge.cancel"
    ),
    MRef = monitor(process, Worker),
    ok = bondy_connect_client:cancel(Caller, Token, killnowait),
    ?assertMatch({error, #{uri := ?WAMP_CANCELLED}}, next_reply(Token)),
    ok = assert_interrupted(MRef),
    ok = assert_no_call_promise(Config),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A caller that leaves during a stream interrupts the bridged callee, and the
bridge's node keeps no call promise.
""".
a_caller_leaving_a_stream_interrupts_the_bridged_callee(Config) ->
    {Worker, Callee, Caller, _} = start_stream(
        Config, ~"com.example.bridge.abandon"
    ),
    MRef = monitor(process, Worker),
    ok = bondy_connect_client:disconnect(Caller),
    ok = assert_interrupted(MRef),
    ok = assert_no_call_promise(Config),
    ok = bondy_connect_client:disconnect(Callee).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Opens a stream on `Proc` to a bridged callee whose handler runs until it is
%% interrupted, and returns the handler's process.
start_stream(Config, Proc) ->
    TestPid = self(),
    Callee = connect(?config(callee_port, Config)),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun(_, _, _) ->
        TestPid ! {worker, self()},
        receive
            never -> {ok, #{args => []}}
        end
    end),
    ok = wait_proxy(Config, Proc),
    Caller = connect(?config(caller_port, Config)),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    receive
        {worker, Worker} -> {Worker, Callee, Caller, Token}
    after 5000 -> ct:fail(handler_not_running)
    end.

assert_interrupted(MRef) ->
    receive
        {'DOWN', MRef, process, _, _} -> ok
    after 5000 -> ct:fail(callee_not_interrupted)
    end.

assert_no_call_promise(Config) ->
    ?assertEqual(
        [],
        erpc:call(?config(bridge_node, Config), bondy_rpc_promise, find_all, [
            bondy_rpc_promise:call_key_pattern(?REALM, '_', '_')
        ])
    ).

listeners(WampPort) ->
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

core_realm(PubKey) ->
    #{
        uri => ?REALM,
        authmethods => [?WAMP_CRYPTOSIGN_AUTH, ?WAMP_ANON_AUTH],
        security_enabled => true,
        users => [
            #{
                username => ?DEVICE,
                authorized_keys => [PubKey],
                groups => [],
                meta => #{}
            }
        ],
        sources => [
            #{
                usernames => [?DEVICE],
                authmethod => ?WAMP_CRYPTOSIGN_AUTH,
                cidr => ~"0.0.0.0/0"
            },
            anonymous_source()
        ],
        grants => [all_grant()]
    }.

edge_realm() ->
    #{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        sources => [anonymous_source()],
        grants => [all_grant()]
    }.

anonymous_source() ->
    #{
        usernames => [~"anonymous"],
        authmethod => ?WAMP_ANON_AUTH,
        cidr => ~"0.0.0.0/0"
    }.

all_grant() ->
    #{
        permissions => [
            ~"wamp.register",
            ~"wamp.unregister",
            ~"wamp.subscribe",
            ~"wamp.unsubscribe",
            ~"wamp.call",
            ~"wamp.cancel",
            ~"wamp.publish"
        ],
        uri => ~"",
        match => ~"prefix",
        roles => ~"all"
    }.

wait_proxy(Config, Proc) ->
    Visible = ?config(proxy_visible, Config),
    wait_until(
        fun() -> Visible(Proc) end,
        erlang:monotonic_time(millisecond) + 30000,
        proxy_registration_not_visible
    ).

add_bridge(Core, Edge, KeyPair) ->
    {Mod, Bin, File} = code:get_object_code(bondy_bridge_relay_rpc_SUITE),
    {module, Mod} = erpc:call(Edge, code, load_binary, [Mod, File, Bin]),
    _ = erpc:call(Edge, bondy_realm, create, [edge_realm()]),
    Port = erpc:call(Core, ranch, get_port, [bridge]),
    erpc:call(Edge, bondy_bridge_relay_rpc_SUITE, do_add_bridge, [
        Port, ?REALM, KeyPair
    ]).

wait_until(Fun, Deadline, Reason) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                ct:fail(Reason),
            timer:sleep(100),
            wait_until(Fun, Deadline, Reason)
    end.

connect(Port) ->
    connect(Port, #{}).

connect(Port, Extra) ->
    {ok, Conn} = bondy_connect_client:connect(Extra#{
        transport => tcp,
        endpoint => {?HOST, Port},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    Conn.

next_reply(Token) ->
    receive
        {bondy_connect_client, Token, Reply} -> Reply
    after 5000 ->
        ct:fail(no_reply)
    end.

sum_input([First], _, #{input := Input}) ->
    {ok, #{args => [sum_input(Input, First)]}}.

sum_input(Input, Acc) ->
    case Input() of
        {more, [N], _} -> sum_input(Input, Acc + N);
        {last, [N], _} -> Acc + N
    end.
