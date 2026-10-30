%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_meta_api_SUITE).

-moduledoc """
The WAMP Registration and Subscription Meta APIs (`wamp.registration.*` and
`wamp.subscription.*`) called by a `bondy_connect_sdk` session against a
single-node router, and the `WELCOME` that advertises them.

Each case runs in its own realm, so a `list` result holds exactly the entries
the case created. Every case covers one node only; the cluster-wide
resolution these procedures do is not exercised here.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(HOST, "127.0.0.1").
-define(PORT, 18082).
-define(EXACT_URI, ~"com.example.meta.leaf").
-define(PREFIX_URI, ~"com.example.meta").
-define(WILDCARD_URI, ~"com.example..leaf").
-define(UNKNOWN_ID, 1).
-define(MASTER_REALM, ~"com.leapsight.bondy").

all() ->
    [
        welcome_advertises_both_meta_apis,
        registration_list_groups_ids_by_policy,
        registration_lookup_finds_the_exact_registration,
        lookup_reads_the_policy_from_its_options,
        registration_match_returns_the_best_registration,
        registration_match_names_the_oldest_callee_of_a_shared_group,
        registration_get_describes_the_registration,
        registration_callees_are_listed_and_counted,
        callee_list_is_scoped_to_the_exact_registration,
        subscription_list_groups_ids_by_policy,
        subscription_lookup_finds_the_exact_subscription,
        subscription_match_returns_every_matching_id,
        subscription_get_describes_the_subscription,
        get_reaches_a_msgpack_client,
        subscription_subscribers_are_listed_and_counted,
        subscribers_are_scoped_to_the_match_policy,
        bondy_procedures_read_a_named_realm
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    Config.

end_per_suite(_) ->
    ok.

init_per_testcase(Case, Config) ->
    Realm = <<"com.example.meta_api.", (atom_to_binary(Case))/binary>>,
    ok = add_anon_realm(Realm),
    [{realm, Realm} | Config].

end_per_testcase(_, _) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

welcome_advertises_both_meta_apis(Config) ->
    #{broker := #{features := Broker}, dealer := #{features := Dealer}} =
        welcome_roles(?config(realm, Config)),
    ?assertEqual(true, maps:get(subscription_meta_api, Broker)),
    ?assertEqual(true, maps:get(registration_meta_api, Dealer)).

registration_list_groups_ids_by_policy(Config) ->
    {Conns, #{exact := E, prefix := P, wildcard := W}} = register_three(Config),
    #{~"exact" := [E], ~"prefix" := [P], ~"wildcard" := Wildcard} =
        call_one(Config, ~"wamp.registration.list", []),
    ?assert(lists:member(W, Wildcard)),
    lists:foreach(
        fun(Id) ->
            #{~"uri" := Uri} = call_one(Config, ~"wamp.registration.get", [Id]),
            ?assertMatch(<<"wamp.session.", _/binary>>, Uri)
        end,
        Wildcard -- [W]
    ),
    disconnect(Conns).

registration_lookup_finds_the_exact_registration(Config) ->
    {Conns, #{exact := E}} = register_three(Config),
    ?assertEqual(
        E, call_one(Config, ~"wamp.registration.lookup", [?EXACT_URI])
    ),
    ?assertEqual(
        [], call_args(Config, ~"wamp.registration.lookup", [~"com.example.no"])
    ),
    disconnect(Conns).

%% The specification's `lookup(uri, options)`: the second argument is the
%% match policy, never a URI under the first argument's realm.
lookup_reads_the_policy_from_its_options(Config) ->
    {Regs, #{prefix := P, wildcard := W}} = register_three(Config),
    {Subs, #{prefix := SP}} = subscribe_three(Config),
    Prefix = #{match => ~"prefix"},
    ?assertEqual(
        P, call_one(Config, ~"wamp.registration.lookup", [?PREFIX_URI, Prefix])
    ),
    ?assertEqual(
        W,
        call_one(
            Config,
            ~"wamp.registration.lookup",
            [?WILDCARD_URI, #{match => ~"wildcard"}]
        )
    ),
    ?assertEqual(
        [], call_args(Config, ~"wamp.registration.lookup", [?PREFIX_URI])
    ),
    ?assertEqual(
        SP, call_one(Config, ~"wamp.subscription.lookup", [?PREFIX_URI, Prefix])
    ),
    ?assertMatch(
        {error, #{uri := ?WAMP_INVALID_ARGUMENT}},
        call(
            Config,
            ~"wamp.registration.lookup",
            [?PREFIX_URI, #{match => ~"fuzzy"}]
        )
    ),
    disconnect(Regs ++ Subs).

registration_match_returns_the_best_registration(Config) ->
    {[Exact | Conns], #{exact := E, prefix := P}} = register_three(Config),
    ?assertEqual(E, call_one(Config, ~"wamp.registration.match", [?EXACT_URI])),

    ok = bondy_connect_client:disconnect(Exact),
    ok = wait_until(
        fun() ->
            call_args(Config, ~"wamp.registration.match", [?EXACT_URI]) == [P]
        end
    ),
    ?assertEqual(
        [], call_args(Config, ~"wamp.registration.match", [~"com.example.no"])
    ),
    disconnect(Conns).

%% Each callee of a shared registration holds its own id; `match` names the
%% oldest, the one the `first` policy would invoke.
registration_match_names_the_oldest_callee_of_a_shared_group(Config) ->
    Opts = #{invoke => ~"roundrobin"},
    {A, IdA} = register_on_new_connection(Config, ?EXACT_URI, Opts),
    ok = timer:sleep(2),
    {B, _} = register_on_new_connection(Config, ?EXACT_URI, Opts),
    ?assertEqual(
        IdA, call_one(Config, ~"wamp.registration.match", [?EXACT_URI])
    ),
    disconnect([A, B]).

registration_get_describes_the_registration(Config) ->
    {Conns, #{exact := E}} = register_three(Config),
    Reg = call_one(Config, ~"wamp.registration.get", [E]),
    ?assertMatch(
        #{
            ~"id" := E,
            ~"uri" := ?EXACT_URI,
            ~"match" := ~"exact",
            ~"invoke" := ~"single",
            ~"created" := _
        },
        Reg
    ),
    ?assert(
        is_integer(
            calendar:rfc3339_to_system_time(
                binary_to_list(maps:get(~"created", Reg))
            )
        )
    ),
    ?assertMatch(
        {error, #{uri := ?WAMP_NO_SUCH_REGISTRATION}},
        call(Config, ~"wamp.registration.get", [?UNKNOWN_ID])
    ),
    disconnect(Conns).

registration_callees_are_listed_and_counted(Config) ->
    Opts = #{invoke => ~"roundrobin"},
    {A, IdA} = register_on_new_connection(Config, ?EXACT_URI, Opts),
    {B, IdB} = register_on_new_connection(Config, ?EXACT_URI, Opts),
    Sessions = lists:sort([session_id(A), session_id(B)]),
    lists:foreach(
        fun(Id) ->
            Listed = call_one(Config, ~"wamp.registration.list_callees", [Id]),
            ?assertEqual(Sessions, lists:sort(Listed)),
            ?assertEqual(
                2, call_one(Config, ~"wamp.registration.count_callees", [Id])
            )
        end,
        [IdA, IdB]
    ),
    disconnect([A, B]).

%% The prefix registration matches `?EXACT_URI` too, so a routing-direction
%% walk would also list its callee.
callee_list_is_scoped_to_the_exact_registration(Config) ->
    Realm = ?config(realm, Config),
    {A, _} = register_on_new_connection(Config, ?EXACT_URI, #{}),
    {B, _} = register_on_new_connection(
        Config, ?PREFIX_URI, #{match => ~"prefix"}
    ),
    #{~"values" := Values} = call_one(
        Config, ~"bondy.registration.callee.list", [Realm, ?EXACT_URI]
    ),
    ?assertEqual([session_id(A)], [S || #{~"session_id" := S} <- Values]),
    disconnect([A, B]).

subscription_list_groups_ids_by_policy(Config) ->
    {Conns, #{exact := E, prefix := P, wildcard := W}} = subscribe_three(
        Config
    ),
    ?assertEqual(
        #{~"exact" => [E], ~"prefix" => [P], ~"wildcard" => [W]},
        call_one(Config, ~"wamp.subscription.list", [])
    ),
    disconnect(Conns).

subscription_lookup_finds_the_exact_subscription(Config) ->
    {Conns, #{exact := E}} = subscribe_three(Config),
    ?assertEqual(
        E, call_one(Config, ~"wamp.subscription.lookup", [?EXACT_URI])
    ),
    ?assertEqual(
        [], call_args(Config, ~"wamp.subscription.lookup", [~"com.example.no"])
    ),
    disconnect(Conns).

subscription_match_returns_every_matching_id(Config) ->
    {Conns, #{exact := E, prefix := P, wildcard := W}} = subscribe_three(
        Config
    ),
    Ids = call_one(Config, ~"wamp.subscription.match", [?EXACT_URI]),
    ?assertEqual(lists:sort([E, P, W]), lists:sort(Ids)),
    ?assertEqual(
        [], call_args(Config, ~"wamp.subscription.match", [~"com.example.no"])
    ),
    disconnect(Conns).

subscription_get_describes_the_subscription(Config) ->
    {Conns, #{exact := E}} = subscribe_three(Config),
    Sub = call_one(Config, ~"wamp.subscription.get", [E]),
    ?assertMatch(
        #{
            ~"id" := E,
            ~"uri" := ?EXACT_URI,
            ~"match" := ~"exact",
            ~"created" := _
        },
        Sub
    ),
    ?assert(
        is_integer(
            calendar:rfc3339_to_system_time(
                binary_to_list(maps:get(~"created", Sub))
            )
        )
    ),
    ?assertMatch(
        {error, #{uri := ?WAMP_NO_SUCH_SUBSCRIPTION}},
        call(Config, ~"wamp.subscription.get", [?UNKNOWN_ID])
    ),
    disconnect(Conns).

%% `bondy_msgpack` encodes no datetime term (its moduledoc), so `created` must
%% leave the router as the ISO 8601 string the WAMP spec defines.
get_reaches_a_msgpack_client(Config) ->
    {Reg, RegId} = register_on_new_connection(Config, ?EXACT_URI, #{}),
    {Sub, SubId} = subscribe_on_new_connection(Config, ?EXACT_URI, #{}),
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?config(realm, Config),
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [msgpack]
    }),
    lists:foreach(
        fun({Uri, Id}) ->
            {ok, #{args := [#{~"id" := Id, ~"created" := Created}]}} =
                bondy_connect_client:call(Conn, Uri, [Id]),
            ?assert(
                is_integer(
                    calendar:rfc3339_to_system_time(binary_to_list(Created))
                )
            )
        end,
        [{~"wamp.registration.get", RegId}, {~"wamp.subscription.get", SubId}]
    ),
    disconnect([Conn, Reg, Sub]).

subscription_subscribers_are_listed_and_counted(Config) ->
    {A, IdA} = subscribe_on_new_connection(Config, ?EXACT_URI, #{}),
    {B, IdB} = subscribe_on_new_connection(Config, ?EXACT_URI, #{}),
    Sessions = lists:sort([session_id(A), session_id(B)]),
    lists:foreach(
        fun(Id) ->
            Listed = call_one(
                Config, ~"wamp.subscription.list_subscribers", [Id]
            ),
            ?assertEqual(Sessions, lists:sort(Listed)),
            ?assertEqual(
                2,
                call_one(Config, ~"wamp.subscription.count_subscribers", [Id])
            )
        end,
        [IdA, IdB]
    ),
    disconnect([A, B]).

%% An exact and a prefix subscription on the same URI string are different
%% subscriptions; neither one's members include the other's subscriber.
subscribers_are_scoped_to_the_match_policy(Config) ->
    {A, ExactId} = subscribe_on_new_connection(Config, ?PREFIX_URI, #{}),
    {B, PrefixId} = subscribe_on_new_connection(
        Config, ?PREFIX_URI, #{match => ~"prefix"}
    ),
    ?assertEqual(
        [session_id(A)],
        call_one(Config, ~"wamp.subscription.list_subscribers", [ExactId])
    ),
    ?assertEqual(
        1, call_one(Config, ~"wamp.subscription.count_subscribers", [ExactId])
    ),
    ?assertEqual(
        [session_id(B)],
        call_one(Config, ~"wamp.subscription.list_subscribers", [PrefixId])
    ),
    disconnect([A, B]).

%% A master-realm session names the realm it reads, as the admin HTTP API does.
bondy_procedures_read_a_named_realm(Config) ->
    Realm = ?config(realm, Config),
    {A, RegId} = register_on_new_connection(Config, ?EXACT_URI, #{}),
    {B, SubId} = subscribe_on_new_connection(Config, ?EXACT_URI, #{}),
    ?assertMatch(
        #{id := RegId, uri := ?EXACT_URI},
        admin_call(~"bondy.registration.get", [Realm, RegId])
    ),
    ?assertEqual(
        [session_id(A)],
        admin_call(~"bondy.registration.list_callees", [Realm, RegId])
    ),
    ?assertEqual(
        1, admin_call(~"bondy.registration.count_callees", [Realm, RegId])
    ),
    ?assertMatch(
        #{id := SubId, uri := ?EXACT_URI},
        admin_call(~"bondy.subscription.get", [Realm, SubId])
    ),
    ?assertEqual(
        [session_id(B)],
        admin_call(~"bondy.subscription.list_subscribers", [Realm, SubId])
    ),
    ?assertEqual(
        1, admin_call(~"bondy.subscription.count_subscribers", [Realm, SubId])
    ),
    disconnect([A, B]).

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
register_three(Config) ->
    {C1, E} = register_on_new_connection(Config, ?EXACT_URI, #{}),
    {C2, P} = register_on_new_connection(
        Config, ?PREFIX_URI, #{match => ~"prefix"}
    ),
    {C3, W} = register_on_new_connection(
        Config, ?WILDCARD_URI, #{match => ~"wildcard"}
    ),
    {[C1, C2, C3], #{exact => E, prefix => P, wildcard => W}}.

%% @private
subscribe_three(Config) ->
    {C1, E} = subscribe_on_new_connection(Config, ?EXACT_URI, #{}),
    {C2, P} = subscribe_on_new_connection(
        Config, ?PREFIX_URI, #{match => ~"prefix"}
    ),
    {C3, W} = subscribe_on_new_connection(
        Config, ?WILDCARD_URI, #{match => ~"wildcard"}
    ),
    {[C1, C2, C3], #{exact => E, prefix => P, wildcard => W}}.

%% @private
register_on_new_connection(Config, Uri, Opts) ->
    Conn = connect(Config),
    Reply = fun(_, _, _) -> {ok, #{}} end,
    {ok, Id} = bondy_connect_client:register(Conn, Uri, Reply, Opts),
    {Conn, Id}.

%% @private
subscribe_on_new_connection(Config, Uri, Opts) ->
    Conn = connect(Config),
    Ignore = fun(_, _, _) -> ok end,
    {ok, Id} = bondy_connect_client:subscribe(Conn, Uri, Ignore, Opts),
    {Conn, Id}.

%% @private
wait_until(Fun) ->
    wait_until(Fun, 50).

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
session_id(Conn) ->
    {ok, #{args := [#{~"session" := Id}]}} =
        bondy_connect_client:call(Conn, ~"bondy.session.self", []),
    Id.

%% @private
admin_call(Uri, Args) ->
    M = bondy_wamp_message:call(1, #{}, Uri, Args),
    Ctxt = bondy_context:local_context(?MASTER_REALM),
    {reply, #result{args = [Value]}} = bondy_wamp_api:handle_call(M, Ctxt),
    Value.

%% @private
call_one(Config, Uri, Args) ->
    [Value] = call_args(Config, Uri, Args),
    Value.

%% @private
call_args(Config, Uri, Args) ->
    {ok, #{args := Result}} = call(Config, Uri, Args),
    Result.

%% @private
call(Config, Uri, Args) ->
    Conn = connect(Config),
    Result = bondy_connect_client:call(Conn, Uri, Args),
    ok = bondy_connect_client:disconnect(Conn),
    Result.

%% @private
welcome_roles(Realm) ->
    {ok, St0} = bondy_wamp_protocol:init(
        {raw, binary, erl}, {{127, 0, 0, 1}, 5000}, #{}
    ),
    Hello = bondy_wamp_message:hello(Realm, #{
        roles => #{caller => #{}, subscriber => #{}},
        authmethods => [?WAMP_ANON_AUTH]
    }),
    {reply, [Bin], _} = bondy_wamp_protocol:handle_inbound(
        bondy_wamp_encoding:encode(Hello, erl), St0
    ),
    {[#welcome{details = #{roles := Roles}}], <<>>} =
        bondy_wamp_encoding:decode({raw, binary, erl}, Bin),
    Roles.

%% @private
connect(Config) ->
    {ok, Conn} = bondy_connect_client:connect(#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?config(realm, Config),
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
add_anon_realm(Uri) ->
    _ = bondy_realm:create(#{
        uri => Uri,
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
    }),
    ok.
