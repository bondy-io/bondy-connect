%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rbac_user_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy_security.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").
-include("bondy_db_tables.hrl").

-define(LU1, <<"local_user_1">>).
-define(LU2, <<"local_user_2">>).
-define(SSOU1, <<"sso_user_1">>).
-define(SSOU2, <<"sso_user_2">>).
-define(REALM1_URI, <<"com.example.test1">>).
-define(REALM2_URI, <<"com.example.test2">>).
-define(SSO_REALM_URI, <<"com.example.test.user.sso">>).

-compile([nowarn_export_all, export_all]).

all() ->
    [
        test,
        invalid_sso_realm,
        resolve,
        add_sso_user_to_realm,
        update,
        update_rejects_credentials,
        change_password,
        update_groups,
        add_group,
        remove_group,
        membership_procedures_reply_after_commit,
        remove_user,
        remove_refuses_a_linked_sso_user,
        update_reports_a_missing_sso_user,
        delete_api_reports_a_linked_sso_user_as_a_conflict,
        list_members,
        group_deletion_cleans_members,
        membership_is_relation_authoritative,
        token_version,
        declarative_config_membership,
        recreated_user_inherits_nothing,
        remove_alias_leaves_other_owners_alone,
        alias_removal_survives_a_projection_timeout,
        user_removal_leaves_names_it_does_not_hold,
        user_procedures_answer_a_missing_user_like_update,
        reserved_names_answer_like_add
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    KeyPairs = [bondy_cryptosign:generate_key() || _ <- lists:seq(1, 3)],
    PubKeys = [
        maps:get(public, KeyPair)
     || KeyPair <- KeyPairs
    ],
    SSORealmUri = ?SSO_REALM_URI,
    ok = add_sso_realm(SSORealmUri),
    ok = add_realm(?REALM1_URI, SSORealmUri, KeyPairs, [
        #{
            username => ?LU1,
            authorized_keys => PubKeys,
            groups => [],
            meta => #{fruit => <<"apple">>}
        },
        #{
            username => ?LU2,
            password => ?LU2,
            groups => [],
            meta => #{fruit => <<"banana">>}
        },
        #{
            username => ?SSOU1,
            authorized_keys => PubKeys,
            groups => [],
            meta => #{fruit => <<"passion fruit">>},
            sso_realm_uri => ?SSO_REALM_URI
        },
        #{
            username => ?SSOU2,
            password => ?SSOU2,
            groups => [],
            meta => #{fruit => <<"orange">>},
            sso_realm_uri => ?SSO_REALM_URI
        }
    ]),
    ok = add_realm(?REALM2_URI, SSORealmUri, KeyPairs, []),
    [{keypairs, KeyPairs} | Config].

end_per_suite(Config) ->
    {save_config, Config}.

add_sso_realm(RealmUri) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test SSO realm">>,
        authmethods => [?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH],
        security_enabled => true,
        is_sso_realm => true,
        allow_connections => false,
        groups => [
            #{
                name => <<"sso_g1">>
            },
            #{
                name => <<"sso_g2">>
            }
        ]
    },
    _ = bondy_realm:create(Config),
    ok.

add_realm(RealmUri, SSORealmUri, _KeyPairs, Users) ->
    Config = #{
        uri => RealmUri,
        description => <<"A test realm">>,
        authmethods => [
            ?WAMP_CRA_AUTH, ?WAMP_CRYPTOSIGN_AUTH, ?PASSWORD_AUTH
        ],
        security_enabled => true,
        sso_realm_uri => SSORealmUri,
        grants => [
            #{
                permissions => [
                    <<"wamp.register">>,
                    <<"wamp.unregister">>,
                    <<"wamp.subscribe">>,
                    <<"wamp.unsubscribe">>,
                    <<"wamp.call">>,
                    <<"wamp.cancel">>,
                    <<"wamp.publish">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => <<"all">>
            }
        ],
        groups => [
            #{
                name => <<"a">>
            },
            #{
                name => <<"b">>
            }
        ],
        sources => [
            #{
                usernames => <<"all">>,
                authmethod => ?PASSWORD_AUTH,
                cidr => <<"0.0.0.0/0">>
            },
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ],
        users => Users
    },
    _ = bondy_realm:create(Config),
    ok.

test(_) ->
    _LU1 = bondy_rbac_user:fetch(?REALM1_URI, ?LU1),
    _LU2 = bondy_rbac_user:fetch(?REALM1_URI, ?LU2),
    _ = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    _ = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU2),
    _SSOU1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    _SSOU2 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU2),
    ok.

resolve(_) ->
    Local = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    Resolved = bondy_rbac_user:resolve(Local),

    ?assertEqual(
        [],
        bondy_rbac_user:authorized_keys(Local)
    ),

    ?assertNotEqual(
        [],
        bondy_rbac_user:authorized_keys(Resolved)
    ),

    ?assertEqual(
        #{
            fruit => <<"passion fruit">>,
            sso => #{}
        },
        maps:get(meta, Resolved)
    ).

invalid_sso_realm(Config) ->
    KeyPairs = ?config(keypairs, Config),
    PubKeys = [
        maps:get(public, KeyPair)
     || KeyPair <- KeyPairs
    ],
    User0 = #{
        username => ?SSOU1,
        authorized_keys => PubKeys,
        groups => [],
        meta => #{fruit => <<"passion fruit">>},
        sso_realm_uri => <<"com.wrong.uri">>
    },
    ?assertEqual(
        {error, already_exists},
        bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User0))
    ),

    User1 = User0#{username => <<"foo">>},
    ?assertEqual(
        {error, invalid_sso_realm},
        bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User1))
    ).

add_sso_user_to_realm(_) ->
    SSOU1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    User0 = #{
        username => ?SSOU1,
        password => <<"thisWillBeDroped">>,
        groups => [],
        meta => #{fruit => <<"passion fruit">>},
        sso_realm_uri => ?SSO_REALM_URI
    },

    ?assertEqual(
        {error, not_found},
        bondy_rbac_user:lookup(?REALM2_URI, ?SSOU1)
    ),

    {ok, NewUser} = bondy_rbac_user:add(
        ?REALM2_URI, bondy_rbac_user:new(User0)
    ),

    %% Because we are adding an existing SSO user to a new Realm the password
    %% is discarded
    ?assertEqual(
        false,
        bondy_rbac_user:has_password(NewUser)
    ),

    %% And the SSO groups, meta were for the SSO user were also discarded
    ?assertEqual(
        SSOU1,
        bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
    ).

update(_) ->
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    User0 = bondy_rbac_user:fetch(?REALM2_URI, ?SSOU1),

    Password = <<"newpassword">>,

    Data0 = #{
        password => Password,
        groups => [],
        sso_realm_uri => ?SSO_REALM_URI
    },

    ?assertMatch(
        {error, #{type := invalid_argument}},
        bondy_rbac_user:update(
            ?REALM2_URI, ?SSOU1, Data0, #{update_credentials => false}
        )
    ),
    ?assertEqual(
        SSOUser0,
        bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
    ),

    ?assertEqual(
        {ok, User0},
        bondy_rbac_user:update(
            ?REALM2_URI, ?SSOU1, Data0, #{update_credentials => true}
        )
    ),

    SSOUser1 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertNotEqual(
        SSOUser0,
        SSOUser1
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            Password, bondy_rbac_user:password(SSOUser1)
        )
    ),

    ok.

update_rejects_credentials(_) ->
    U = ~"upd_cred_user",
    ok = add_member(?REALM1_URI, U, []),
    ok = add_group(?REALM1_URI, ~"api_clients"),
    ClientId = ~"upd_cred_client",
    {ok, _} = bondy_oauth2_client:add(?REALM1_URI, #{
        ~"client_id" => ClientId,
        ~"client_secret" => ~"client-secret-0"
    }),

    Self = self(),
    {ok, Handler} = bondy_event_manager:add_callback(
        fun(Event) -> Self ! {event, Event} end
    ),

    ?assertMatch(
        {error, #{type := invalid_argument}},
        bondy_rbac_user:update(?REALM1_URI, U, #{password => ~"new-pw"})
    ),
    ?assertMatch(
        {error, #{type := invalid_argument}},
        bondy_oauth2_client:update(?REALM1_URI, ClientId, #{
            ~"client_secret" => ~"client-secret-1"
        })
    ),

    ?assert(verify(?REALM1_URI, U, U)),
    ?assertNot(verify(?REALM1_URI, U, ~"new-pw")),
    ?assert(verify(?REALM1_URI, ClientId, ~"client-secret-0")),
    ?assertNot(verify(?REALM1_URI, ClientId, ~"client-secret-1")),
    ?assertEqual(none, credentials_event(?REALM1_URI, U)),
    ?assertEqual(none, credentials_event(?REALM1_URI, ClientId)),

    %% Positive control: the observer does see a real credential change.
    ok = bondy_rbac_user:change_password(?REALM1_URI, U, ~"new-pw"),
    ?assert(verify(?REALM1_URI, U, ~"new-pw")),
    ?assertEqual(seen, credentials_event(?REALM1_URI, U)),

    ok = gen_event:delete_handler(bondy_event_manager, Handler, []).

change_password(_) ->
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),
    P1 = <<"newpassword">>,

    ?assertEqual(
        true,
        bondy_password:verify_string(P1, bondy_rbac_user:password(SSOUser0))
    ),

    ?assertEqual(
        false,
        bondy_password:verify_string(
            <<"wrongpassword">>, bondy_rbac_user:password(SSOUser0)
        )
    ),

    ?assertEqual(
        true,
        bondy_rbac_user:has_password(SSOUser0)
    ),

    ?assertNotEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"123456">>, <<"wrongpassword">>
        )
    ),

    ?assertEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"123456">>, <<"newpassword">>
        )
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            <<"123456">>,
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
            )
        )
    ),

    ?assertEqual(
        ok,
        bondy_rbac_user:change_password(
            ?REALM2_URI, ?SSOU1, <<"987654321">>
        )
    ),

    ?assertEqual(
        true,
        bondy_password:verify_string(
            <<"987654321">>,
            bondy_rbac_user:password(
                bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1)
            )
        )
    ).

update_groups(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [],
        bondy_rbac_user:groups(User0)
    ),

    ?assertEqual(
        [],
        bondy_rbac_user:groups(SSOUser0)
    ),

    ?assertMatch(
        {ok, #{groups := [<<"a">>]}},
        bondy_rbac_user:update(
            ?REALM1_URI, ?SSOU1, #{<<"groups">> => [<<"a">>]}
        )
    ),

    ?assertMatch(
        {ok, #{groups := [<<"sso_g1">>]}},
        bondy_rbac_user:update(
            ?SSO_REALM_URI,
            ?SSOU1,
            #{<<"groups">> => [<<"sso_g1">>]}
        )
    ).

add_group(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [<<"a">>],
        bondy_rbac_user:groups(User0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:add_group(?REALM1_URI, ?SSOU1, <<"b">>)
    ),
    ?assertEqual(
        [<<"a">>, <<"b">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1))
    ),
    ?assertEqual(
        {error, {no_such_groups, [<<"c">>]}},
        bondy_rbac_user:add_group(?REALM1_URI, ?SSOU1, <<"c">>)
    ),

    ?assertEqual(
        [<<"sso_g1">>],
        bondy_rbac_user:groups(SSOUser0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:add_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g2">>)
    ),
    ?assertEqual(
        [<<"sso_g1">>, <<"sso_g2">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1))
    ),
    ?assertEqual(
        {error, {no_such_groups, [<<"sso_g3">>]}},
        bondy_rbac_user:add_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g3">>)
    ).

remove_group(_) ->
    User0 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    SSOUser0 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        [<<"a">>, <<"b">>],
        bondy_rbac_user:groups(User0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:remove_group(?REALM1_URI, ?SSOU1, <<"b">>)
    ),
    ?assertEqual(
        [<<"a">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1))
    ),

    ?assertEqual(
        [<<"sso_g1">>, <<"sso_g2">>],
        bondy_rbac_user:groups(SSOUser0)
    ),
    ?assertEqual(
        ok,
        bondy_rbac_user:remove_group(?SSO_REALM_URI, ?SSOU1, <<"sso_g2">>)
    ),
    ?assertEqual(
        [<<"sso_g1">>],
        bondy_rbac_user:groups(bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1))
    ).

%% The eight `bondy.user.*` and `bondy.group.*` membership procedures, through
%% `bondy_wamp_api:handle_call/2`. The bondy_docs WAMP API reference documents
%% no results for any of them, so each must answer an empty RESULT once its
%% change is stored. The case records every reply, crash included, and the
%% stored group lists before asserting, so one run shows all eight.
membership_procedures_reply_after_commit(_) ->
    R = ~"com.example.test.membership_api",
    _ = bondy_realm:create(R),
    ok = lists:foreach(
        fun(G) -> ok = add_group(R, G) end, [~"m_a", ~"m_b", ~"m_c", ~"m_d"]
    ),
    ok = add_member(R, ~"m_user", []),
    Steps = [
        {?BONDY_USER_ADD_GROUP, [~"m_user", ~"m_a"], user, [~"m_a"]},
        {?BONDY_USER_ADD_GROUPS, [~"m_user", [~"m_b", ~"m_c"]], user, [
            ~"m_a", ~"m_b", ~"m_c"
        ]},
        {?BONDY_USER_REMOVE_GROUP, [~"m_user", ~"m_a"], user, [~"m_b", ~"m_c"]},
        {?BONDY_USER_REMOVE_GROUPS, [~"m_user", [~"m_b"]], user, [~"m_c"]},
        {?BONDY_GROUP_ADD_GROUP, [~"m_d", ~"m_a"], group, [~"m_a"]},
        {?BONDY_GROUP_ADD_GROUPS, [~"m_d", [~"m_b", ~"m_c"]], group, [
            ~"m_a", ~"m_b", ~"m_c"
        ]},
        {?BONDY_GROUP_REMOVE_GROUP, [~"m_d", ~"m_a"], group, [~"m_b", ~"m_c"]},
        {?BONDY_GROUP_REMOVE_GROUPS, [~"m_d", [~"m_b"]], group, [~"m_c"]}
    ],
    Observed = [
        {Proc, api_reply(Proc, [R | Args]), stored_groups(Kind, R, hd(Args))}
     || {Proc, Args, Kind, _} <- Steps
    ],
    Expected = [
        {Proc, {result, undefined}, Groups}
     || {Proc, _, _, Groups} <- Steps
    ],
    ?assertEqual(Expected, Observed).

remove_user(_) ->
    _Local = bondy_rbac_user:fetch(?REALM1_URI, ?LU1),
    _SSO1 = bondy_rbac_user:fetch(?REALM1_URI, ?SSOU1),
    _SSO2 = bondy_rbac_user:fetch(?SSO_REALM_URI, ?SSOU1),

    ?assertEqual(
        ok,
        bondy_rbac_user:remove(?REALM1_URI, ?LU1)
    ),
    ?assertMatch(
        {error, {no_such_user, _}},
        bondy_rbac_user:remove(?REALM1_URI, ?LU1)
    ),

    ?assertEqual(
        ok,
        bondy_rbac_user:remove(?REALM1_URI, ?SSOU1)
    ),
    ?assertMatch(
        {error, {no_such_user, _}},
        bondy_rbac_user:remove(?REALM1_URI, ?SSOU1)
    ),
    ok = bondy_rbac_user:remove(?REALM2_URI, ?SSOU1),
    ?assertEqual(
        ok,
        bondy_rbac_user:remove(?SSO_REALM_URI, ?SSOU1)
    ).

remove_refuses_a_linked_sso_user(_) ->
    Username = <<"sso_linked">>,
    User = #{
        username => Username,
        password => Username,
        sso_realm_uri => ?SSO_REALM_URI
    },
    {ok, _} = bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User)),
    {ok, _} = bondy_rbac_user:add(?REALM2_URI, bondy_rbac_user:new(User)),
    ?assertEqual(
        {error, {in_use, [?REALM1_URI, ?REALM2_URI]}},
        bondy_rbac_user:remove(?SSO_REALM_URI, Username)
    ),
    _ = bondy_rbac_user:fetch(?SSO_REALM_URI, Username),
    ok = bondy_rbac_user:remove(?REALM1_URI, Username),
    ?assertEqual(
        {error, {in_use, [?REALM2_URI]}},
        bondy_rbac_user:remove(?SSO_REALM_URI, Username)
    ),
    ok = bondy_rbac_user:remove(?REALM2_URI, Username),
    ?assertEqual(ok, bondy_rbac_user:remove(?SSO_REALM_URI, Username)).

%% `remove/3` refuses while a local user links to the SSO user, but a peer can
%% remove it before the link replicates; clearing the cell stands in for that.
update_reports_a_missing_sso_user(_) ->
    Username = ~"sso_missing",
    User = #{
        username => Username,
        password => Username,
        sso_realm_uri => ?SSO_REALM_URI
    },
    {ok, _} = bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User)),
    Table = bondy_namespace_catalog:table(?BONDY_DB_USER_TAB),
    ok = bondy_db:apply(Table, ?SSO_REALM_URI, Username, clear),
    ?assertEqual(
        {error, {no_such_user, Username}},
        bondy_rbac_user:update(?REALM1_URI, Username, #{
            meta => #{fruit => ~"kiwi"}
        })
    ).

delete_api_reports_a_linked_sso_user_as_a_conflict(_) ->
    Username = <<"sso_linked_api">>,
    User = #{
        username => Username,
        password => Username,
        sso_realm_uri => ?SSO_REALM_URI
    },
    {ok, _} = bondy_rbac_user:add(?REALM1_URI, bondy_rbac_user:new(User)),
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    Call = bondy_wamp_message:call(
        1, #{}, ?BONDY_USER_DELETE, [?SSO_REALM_URI, Username]
    ),
    {reply, Error0} = bondy_rbac_api:handle_call(
        ?BONDY_USER_DELETE, Call, Ctxt
    ),
    Error = bondy_wamp_message:decode_partial(Error0),
    ?assertEqual(<<"bondy.error.conflict">>, Error#error.error_uri),
    ?assertMatch(
        #{
            <<"nature">> := <<"permanent">>,
            <<"details">> := #{<<"realms">> := [?REALM1_URI]}
        },
        Error#error.kwargs
    ),
    ok = bondy_rbac_user:remove(?REALM1_URI, Username),
    ok = bondy_rbac_user:remove(?SSO_REALM_URI, Username).

%% The `member` relation's reverse access path: list a group's members via
%% the substrate `by_group` index, paginated and realm-isolated, instead of
%% scanning the realm's users.
list_members(_) ->
    G = <<"member_test_group">>,
    ok = add_group(?REALM1_URI, G),
    ok = add_group(?REALM2_URI, G),
    R1Users = [<<"mtu_01">>, <<"mtu_02">>, <<"mtu_03">>],
    [ok = add_member(?REALM1_URI, U, [G]) || U <- R1Users],
    %% Same group NAME in another realm with a different member — must not
    %% cross over (the index bucket is realm-agnostic; the read is not).
    ok = add_member(?REALM2_URI, <<"mtu_other">>, [G]),

    %% All members, in (normalised username) key order, realm-scoped.
    ?assertEqual(
        {R1Users, undefined}, bondy_rbac_group:members(?REALM1_URI, G, #{})
    ),
    ?assertEqual(
        {[<<"mtu_other">>], undefined},
        bondy_rbac_group:members(?REALM2_URI, G, #{})
    ),

    %% Keyset pagination: limit 2 ⇒ a page of 2 + a continuation, then the rest.
    {P1, Cont} = bondy_rbac_group:members(?REALM1_URI, G, #{limit => 2}),
    ?assertEqual([<<"mtu_01">>, <<"mtu_02">>], P1),
    ?assertNotEqual(undefined, Cont),
    ?assertEqual(
        {[<<"mtu_03">>], undefined},
        bondy_rbac_group:members(?REALM1_URI, G, #{limit => 2, cursor => Cont})
    ).

%% Deleting a group drains its members through the reverse index (bounded to
%% the group's members, not the whole realm) and removes it from each
%% member's `user.groups`.
group_deletion_cleans_members(_) ->
    G = <<"deletable_group">>,
    ok = add_group(?REALM1_URI, G),
    Users = [<<"dgu_01">>, <<"dgu_02">>],
    [ok = add_member(?REALM1_URI, U, [G]) || U <- Users],
    ?assertEqual(
        {Users, undefined}, bondy_rbac_group:members(?REALM1_URI, G, #{})
    ),

    ok = bondy_rbac_group:remove(?REALM1_URI, G),

    [
        ?assertEqual(
            [],
            bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, U))
        )
     || U <- Users
    ],
    ?assertEqual(
        {[], undefined}, bondy_rbac_group:members(?REALM1_URI, G, #{})
    ).

%% Membership is authoritative in the cell-per-fact `security_group_members`
%% relation, NOT in the user record: the API surfaces a user's groups (derived
%% on read), but the persisted user cell carries no `groups` field, so there is
%% no second, divergence-prone copy. Removing a membership drops it from the
%% derived set.
membership_is_relation_authoritative(_) ->
    U = <<"rel_auth_user">>,
    G = <<"rel_auth_group">>,
    ok = add_group(?REALM1_URI, G),
    ok = add_member(?REALM1_URI, U, [G]),

    ?assertEqual(
        [G], bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, U))
    ),

    %% The persisted user CELL has NO `groups` key — membership lives only in
    %% the relation.
    Table = bondy_namespace_catalog:table(security_users),
    {ok, {Value, _Hlc}} = bondy_db:read(Table, ?REALM1_URI, U),
    ?assert(is_map(Value)),
    ?assertNot(maps:is_key(groups, Value)),

    ok = bondy_rbac_user:remove_group(?REALM1_URI, U, G),
    ?assertEqual(
        [], bondy_rbac_user:groups(bondy_rbac_user:fetch(?REALM1_URI, U))
    ).

token_version(_) ->
    U = <<"tv_user_1">>,
    ok = add_member(?REALM1_URI, U, []),

    %% A freshly written user cell has a monotonic HLC version.
    {ok, V0} = bondy_rbac_user:token_version(?REALM1_URI, U),
    ?assert(is_integer(V0) andalso V0 >= 0),

    %% Every write to the user cell advances the version (the cell HLC is
    %% strictly increasing), so a credential change is observable as a higher
    %% version — this is what lets the auth path detect a token issued before
    %% the change.
    ok = bondy_rbac_user:change_password(?REALM1_URI, U, <<"new-secret-123">>),
    {ok, V1} = bondy_rbac_user:token_version(?REALM1_URI, U),
    ?assert(V1 > V0),

    %% A second mutation advances it again — monotonic, not merely changed once.
    ok = bondy_rbac_user:change_password(?REALM1_URI, U, <<"new-secret-456">>),
    {ok, V2} = bondy_rbac_user:token_version(?REALM1_URI, U),
    ?assert(V2 > V1),

    %% The anonymous user has no stored cell / no revocable tokens → sentinel 0.
    ?assertEqual(
        {ok, 0}, bondy_rbac_user:token_version(?REALM1_URI, anonymous)
    ),

    ?assertEqual(
        {error, not_found},
        bondy_rbac_user:token_version(?REALM1_URI, <<"no_such_user_xyz">>)
    ).

declarative_config_membership(_) ->
    %% The declarative path is the one `bondy_realm:apply_config/0` takes at
    %% every boot: overwrite the record, skip the runtime lifecycle
    %% side-effects, and emit a write only when something actually differs.
    U = <<"decl_user_1">>,
    G1 = <<"decl_group_1">>,
    G2 = <<"decl_group_2">>,
    ok = add_group(?REALM1_URI, G1),
    ok = add_group(?REALM1_URI, G2),

    ok = declarative_add(?REALM1_URI, U, [G1]),
    ?assertEqual([G1], user_groups(?REALM1_URI, U)),

    {ok, V0} = bondy_rbac_user:token_version(?REALM1_URI, U),

    %% Re-applying the SAME declaration writes nothing: membership is unchanged
    %% and the user cell is not re-stamped, so the revocation zookie holds
    %% still. This is what stops every boot perturbing cross-node convergence.
    ok = declarative_add(?REALM1_URI, U, [G1]),
    ?assertEqual([G1], user_groups(?REALM1_URI, U)),
    ?assertEqual({ok, V0}, bondy_rbac_user:token_version(?REALM1_URI, U)),

    %% A membership-only change still advances the zookie, even though the
    %% record itself is identical. Without that write, a group revoked through
    %% the config file would leave already-issued tokens valid.
    ok = declarative_add(?REALM1_URI, U, [G1, G2]),
    ?assertEqual([G1, G2], user_groups(?REALM1_URI, U)),
    {ok, V1} = bondy_rbac_user:token_version(?REALM1_URI, U),
    ?assert(V1 > V0),

    %% The file is the desired state, so a group dropped from it is retracted.
    ok = declarative_add(?REALM1_URI, U, []),
    ?assertEqual([], user_groups(?REALM1_URI, U)),
    {ok, V2} = bondy_rbac_user:token_version(?REALM1_URI, U),
    ?assert(V2 > V1).

recreated_user_inherits_nothing(_) ->
    %% A username is not an identity — it is a key that can be handed to someone
    %% else. Everything keyed by it lives in a table of its own (memberships,
    %% grants, sources, alias pointers, tokens), so a delete that forgets one of
    %% them silently grants the next holder of the name whatever it left behind.
    Uri = <<"com.example.user.recreate">>,
    User = <<"recreated">>,
    Alias = <<"recreated_alias">>,
    Group = <<"recreate_group">>,
    Resource = <<"com.recreate.">>,

    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        groups => [#{name => Group}],
        users => [
            #{username => User, password => User, groups => [Group]}
        ],
        grants => [
            #{
                permissions => [<<"wamp.call">>],
                uri => Resource,
                match => <<"prefix">>,
                roles => [Group]
            }
        ]
    }),

    %% A user-specific grant, a source and an alias — the state that is keyed by
    %% the username rather than reached through the group.
    ok = bondy_rbac:grant(Uri, #{
        <<"permissions">> => [<<"wamp.register">>],
        <<"uri">> => Resource,
        <<"match">> => <<"prefix">>,
        <<"roles">> => [User]
    }),
    {ok, _} = bondy_rbac_source:add(Uri, #{
        <<"usernames">> => [User],
        <<"authmethod">> => ?PASSWORD_AUTH,
        <<"cidr">> => <<"0.0.0.0/0">>,
        <<"meta">> => #{}
    }),
    ok = bondy_rbac_user:add_alias(Uri, User, Alias),

    C0 = bondy_rbac:get_context(Uri, User),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.call">>, Resource, C0)),
    ?assertEqual(ok, bondy_rbac:authorize(<<"wamp.register">>, Resource, C0)),
    ?assertEqual([Group], user_groups(Uri, User)),
    ?assertNotEqual([], bondy_rbac_source:match(Uri, User)),
    ?assertMatch({ok, #{username := User}}, bondy_rbac_user:lookup(Uri, Alias)),

    ok = bondy_rbac_user:remove(Uri, User),
    ?assertEqual({error, not_found}, bondy_rbac_user:lookup(Uri, User)),

    %% Re-create the name. The group still exists and still holds its grant, so
    %% anything the new user inherits came from the old one's leftovers — the
    %% new user declares no groups.
    ok = declarative_add(Uri, User, []),

    ?assertEqual([], user_groups(Uri, User)),

    C1 = bondy_rbac:get_context(Uri, User),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.call">>, Resource, C1),
        "the group grant must not be reachable without the membership"
    ),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(<<"wamp.register">>, Resource, C1),
        "the deleted user's own grant must not survive its user"
    ),
    ?assertEqual([], bondy_rbac_source:match(Uri, User)),
    ?assertEqual({error, not_found}, bondy_rbac_user:lookup(Uri, Alias)).

%% A user removing a name it does not hold, whether another user's alias or
%% another user's username, leaves that name with its owner.
remove_alias_leaves_other_owners_alone(_) ->
    Uri = <<"com.example.user.alias_owner">>,
    Remover = <<"alias_remover">>,
    Owner = <<"alias_owner">>,
    Other = <<"alias_other">>,
    Alias = <<"owners_alias">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        users => [
            #{username => U, password => U}
         || U <- [Remover, Owner, Other]
        ]
    }),
    ok = bondy_rbac_user:add_alias(Uri, Owner, Alias),

    Results = [
        {Name, bondy_rbac_user:remove_alias(Uri, Remover, Name)}
     || Name <- [Alias, Other]
    ],
    Owners = [
        {Name, owner(bondy_rbac_user:lookup(Uri, Name))}
     || Name <- [Alias, Other]
    ],
    ?assertEqual(
        {[{Alias, ok}, {Other, ok}], [{Alias, Owner}, {Other, Other}]},
        {Results, Owners}
    ).

%% This module's user writes treat `{error, timeout}` from `bondy_db:apply/4` as
%% an appended write still being projected. An alias clear must do the same and
%% drop the alias from the user, or deleting the user later clears the name
%% after someone else has claimed it.
alias_removal_survives_a_projection_timeout(_) ->
    Uri = <<"com.example.user.alias_timeout">>,
    Owner = <<"timeout_owner">>,
    Claimant = <<"timeout_claimant">>,
    Alias = <<"timeout_alias">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        users => [#{username => U, password => U} || U <- [Owner, Claimant]]
    }),
    ok = bondy_rbac_user:add_alias(Uri, Owner, Alias),

    ok = meck:new(bondy_db, [passthrough, no_link]),
    ok = meck:expect(bondy_db, apply, fun
        (Table, Realm, Key, clear) when Key =:= Alias ->
            ok = meck:passthrough([Table, Realm, Key, clear]),
            {error, timeout};
        (Table, Realm, Key, Event) ->
            meck:passthrough([Table, Realm, Key, Event])
    end),
    Removed =
        try
            bondy_rbac_user:remove_alias(Uri, Owner, Alias)
        after
            ok = meck:unload(bondy_db)
        end,
    OwnerAliases = maps:get(aliases, bondy_rbac_user:fetch(Uri, Owner), []),
    Claimed = bondy_rbac_user:add_alias(Uri, Claimant, Alias),
    ok = bondy_rbac_user:remove(Uri, Owner),
    ?assertEqual(
        {ok, [], ok, Claimant},
        {Removed, OwnerAliases, Claimed,
            owner(bondy_rbac_user:lookup(Uri, Alias))}
    ).

%% Deleting a user whose alias list names something it does not hold, another
%% user's alias or another user's username, leaves that name with its holder.
%% The list is written directly to stand for one that drifted from the cells.
user_removal_leaves_names_it_does_not_hold(_) ->
    Uri = <<"com.example.user.removal_owner">>,
    Removed = <<"removal_removed">>,
    Owner = <<"removal_owner">>,
    Other = <<"removal_other">>,
    Alias = <<"removal_alias">>,
    _ = bondy_realm:create(#{
        uri => Uri,
        security_enabled => true,
        authmethods => [?PASSWORD_AUTH],
        users => [
            #{username => U, password => U}
         || U <- [Removed, Owner, Other]
        ]
    }),
    ok = bondy_rbac_user:add_alias(Uri, Owner, Alias),
    Table = bondy_namespace_catalog:table(?BONDY_DB_USER_TAB),
    {ok, {Record, _}} = bondy_db:read(Table, Uri, Removed),
    ok = bondy_db:apply(
        Table, Uri, Removed, {set, Record#{aliases => [Alias, Other]}}
    ),

    ok = bondy_rbac_user:remove(Uri, Removed),
    ?assertEqual(
        [{Alias, Owner}, {Other, Other}],
        [
            {Name, owner(bondy_rbac_user:lookup(Uri, Name))}
         || Name <- [Alias, Other]
        ]
    ).

%% Through `bondy_wamp_api:handle_call/2`, for a username the realm does not
%% hold. The bondy_docs WAMP API reference names `wamp.error.no_such_principal`
%% for each of these procedures; `bondy.user.update` is the reference answer.
user_procedures_answer_a_missing_user_like_update(_) ->
    R = ~"com.example.test.enable_missing",
    _ = bondy_realm:create(R),
    Update = api_reply(?BONDY_USER_UPDATE, [R, ~"nobody", #{}]),
    ?assertEqual({error, ?WAMP_NO_SUCH_PRINCIPAL}, Update),
    Calls = [
        {?BONDY_USER_ENABLE, [R, ~"nobody"]},
        {?BONDY_USER_DISABLE, [R, ~"nobody"]},
        {?BONDY_USER_IS_ENABLED, [R, ~"nobody"]},
        {?BONDY_USER_ADD_ALIAS, [R, ~"nobody", ~"somealias"]},
        {?BONDY_USER_REMOVE_ALIAS, [R, ~"nobody", ~"somealias"]}
    ],
    ?assertEqual(
        [{P, Update} || {P, _} <- Calls],
        [{P, api_reply(P, A)} || {P, A} <- Calls]
    ),
    ok = add_member(R, ~"somebody", []),
    Toggled = [
        {
            api_reply(P, [R, ~"somebody"]),
            api_reply(?BONDY_USER_IS_ENABLED, [R, ~"somebody"])
        }
     || P <- [?BONDY_USER_DISABLE, ?BONDY_USER_ENABLE]
    ],
    ?assertEqual(
        [
            {{result, undefined}, {result, [false]}},
            {{result, undefined}, {result, [true]}}
        ],
        Toggled
    ).

%% A reserved name answers every write the way `bondy.user.add` answers it.
%% Only `bondy_wamp_api:handle_call/2` runs here, so `add`'s validator raises
%% and its URI is read from the raised error.
reserved_names_answer_like_add(_) ->
    R = ~"com.example.test.reserved_names",
    _ = bondy_realm:create(R),
    Add = #{~"username" => ~"all", ~"password" => ~"x1y2z3w4"},
    {crashed, Raised} = api_reply(?BONDY_USER_ADD, [R, Add]),
    #{uri := Uri} = bondy_connect_error:from_term(Raised),
    Calls = [
        {?BONDY_USER_ADD_ALIAS, [R, ~"anonymous", ~"somealias"]}
        | [
            C
         || N <- [~"anonymous", ~"all"],
            C <- [
                {?BONDY_USER_UPDATE, [R, N, #{}]},
                {?BONDY_USER_DELETE, [R, N]},
                {?BONDY_USER_ENABLE, [R, N]},
                {?BONDY_USER_DISABLE, [R, N]},
                {?BONDY_GROUP_UPDATE, [R, N, #{}]},
                {?BONDY_GROUP_DELETE, [R, N]},
                {?BONDY_OAUTH2_CLIENT_UPDATE, [R, N, #{}]},
                {?BONDY_OAUTH2_CLIENT_DELETE, [R, N]},
                {?BONDY_OAUTH2_RES_OWNER_UPDATE, [R, N, #{}]},
                {?BONDY_OAUTH2_RES_OWNER_DELETE, [R, N]}
            ]
        ]
    ],
    ?assertEqual(
        [{P, A, {error, Uri}} || {P, A} <- Calls],
        [{P, A, api_reply(P, A)} || {P, A} <- Calls]
    ).

%% =============================================================================
%% Member-test helpers
%% =============================================================================

owner({ok, #{username := Username}}) ->
    Username;
owner({error, not_found}) ->
    not_found.

%% Adds a user the way `bondy_realm:apply_rbac_config/3` does. The user carries
%% no credentials so the stored record is identical across applies — a password
%% is salted per call, which would defeat the idempotency assertions.
declarative_add(RealmUri, Username, Groups) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        groups => Groups
    }),
    {ok, _} = bondy_rbac_user:add(RealmUri, User, #{
        declarative => true,
        update_credentials => true,
        forward_credentials => true
    }),
    ok.

user_groups(RealmUri, Username) ->
    lists:sort(
        bondy_rbac_user:groups(bondy_rbac_user:fetch(RealmUri, Username))
    ).

add_group(RealmUri, Name) ->
    {ok, _} = bondy_rbac_group:add(
        RealmUri, bondy_rbac_group:new(#{name => Name})
    ),
    ok.

verify(RealmUri, Username, Password) ->
    bondy_password:verify_string(
        Password,
        bondy_rbac_user:password(bondy_rbac_user:fetch(RealmUri, Username))
    ).

credentials_event(RealmUri, Username) ->
    receive
        {event, {[bondy, user, credentials, updated], RealmUri, Username}} ->
            seen
    after 500 ->
        none
    end.

add_member(RealmUri, Username, Groups) ->
    User = bondy_rbac_user:new(#{
        username => Username,
        password => Username,
        groups => Groups
    }),
    {ok, _} = bondy_rbac_user:add(RealmUri, User),
    ok.

api_reply(Proc, Args) ->
    Ctxt = bondy_context:local_context(?MASTER_REALM_URI),
    M = bondy_wamp_message:call(1, #{}, Proc, Args),
    try bondy_wamp_api:handle_call(M, Ctxt) of
        {reply, #result{args = A}} -> {result, A};
        {reply, #error{error_uri = Uri}} -> {error, Uri}
    catch
        error:Reason -> {crashed, Reason}
    end.

stored_groups(user, RealmUri, Name) ->
    user_groups(RealmUri, Name);
stored_groups(group, RealmUri, Name) ->
    lists:sort(bondy_rbac_group:groups(bondy_rbac_group:fetch(RealmUri, Name))).
