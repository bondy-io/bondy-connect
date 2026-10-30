%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_master_realm_hardening_SUITE).
-moduledoc """
The master-realm hardening rules: the master realm
must not accept anonymous connections, the administrators grant must be scoped to
the Bondy admin namespaces, and the boot migration must remediate a legacy
master realm that predates these rules.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-compile([nowarn_export_all, export_all]).

all() ->
    [
        no_anonymous_authmethod,
        admin_grant_is_scoped,
        migration_removes_legacy_anon_and_is_idempotent
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

no_anonymous_authmethod(_Config) ->
    Methods = bondy_realm:authmethods(?MASTER_REALM_URI),
    ?assertNot(lists:member(?WAMP_ANON_AUTH, Methods)).

%% -----------------------------------------------------------------------------
%% The administrators grant must be scoped to `bondy.` and `wamp.`, not to
%% the empty prefix (which matches every URI).
%% -----------------------------------------------------------------------------

admin_grant_is_scoped(_Config) ->
    Grants = bondy_rbac:group_grants(
        ?MASTER_REALM_URI, <<"bondy.administrators">>
    ),
    %% group_grants/2 returns the collapsed form: [{Resource, Permissions}],
    %% where Resource is `any` | {Uri, MatchStrategy}.
    Uris = [Uri || {{Uri, _Match}, _Perms} <- Grants],

    ?assertNot(lists:member(<<"">>, Uris)),
    ?assert(lists:member(<<"bondy.">>, Uris)),
    ?assert(lists:member(<<"wamp.">>, Uris)),
    ?assert(
        lists:all(
            fun(U) -> U =:= <<"bondy.">> orelse U =:= <<"wamp.">> end, Uris
        )
    ).

migration_removes_legacy_anon_and_is_idempotent(_Config) ->
    Uri = ?MASTER_REALM_URI,

    Methods0 = bondy_realm:authmethods(Uri),
    ?assertNot(lists:member(?WAMP_ANON_AUTH, Methods0)),

    %% Simulate a legacy (pre-hardening) install by re-adding anonymous auth.
    _ = bondy_realm:update(Uri, #{
        <<"authmethods">> => Methods0 ++ [?WAMP_ANON_AUTH]
    }),
    ?assert(lists:member(?WAMP_ANON_AUTH, bondy_realm:authmethods(Uri))),
    ok = bondy_rbac:grant(Uri, #{
        ~"permissions" => [~"wamp.call"],
        ~"uri" => ~"",
        ~"match" => ~"prefix",
        ~"roles" => [~"anonymous"]
    }),
    ?assertEqual(
        ok,
        bondy_rbac:authorize(
            ~"wamp.call",
            ~"bondy.realm.list",
            bondy_rbac:get_anonymous_context(Uri, ~"anon_1")
        )
    ),

    ok = bondy_realm:harden_master_realm(),
    ?assertNot(lists:member(?WAMP_ANON_AUTH, bondy_realm:authmethods(Uri))),
    ?assertError(
        {not_authorized, _},
        bondy_rbac:authorize(
            ~"wamp.call",
            ~"bondy.realm.list",
            bondy_rbac:get_anonymous_context(Uri, ~"anon_2")
        )
    ),

    ok = bondy_realm:harden_master_realm(),
    ?assertNot(lists:member(?WAMP_ANON_AUTH, bondy_realm:authmethods(Uri))).
