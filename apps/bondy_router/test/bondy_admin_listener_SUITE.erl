%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================
%% Drives the built-in Admin API over real sockets on a booted node.
%%
%% Two cases are a PAIR and only mean something together: the Admin API must be
%% reachable on a listener declaring `admin_api` and unreachable on one
%% declaring only `api_gateway`. Either alone is satisfied by a node that mounts
%% the specification nowhere, which is exactly the state this suite exists to
%% catch.
%%
%% The remaining cases are about `admin_local`, the internal Unix-domain
%% listener no `bondy.conf` can remove, disable or misconfigure. They assert it
%% BOUND — a completed request over the socket — rather than that it appears in
%% the inventory.
%% =============================================================================
-module(bondy_admin_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_security.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([admin_api_is_served_on_the_admin_listener/1]).
-export([admin_api_is_absent_from_the_public_listener/1]).
-export([stored_specs_are_absent_from_the_admin_listeners/1]).
-export([admin_local_is_injected_without_configuration/1]).
-export([admin_local_socket_is_bound_and_serves/1]).
-export([registry_routes_read_the_named_realm/1]).
-export([on_call/3]).
-export([malformed_bearer_token_is_unauthorized/1]).
-export([admin_api_cookie_is_subject_to_master_realm_sources/1]).
-export([admin_api_cookie_without_admin_role_is_forbidden/1]).
-export([admin_api_csrf_checks_the_authenticating_realms_pair/1]).
-export([named_source_matches_an_authid_in_any_case/1]).
-export([log/2]).

-define(ADMIN, admin).
-define(PUBLIC, api_gateway_http).

%% A stored API Gateway specification, loaded by this suite so the OTHER
%% direction of the split can be falsified.
-define(SPEC_ID, <<"com.example.adminsplit.api">>).
-define(SPEC_REALM, <<"com.example.adminsplit">>).
-define(SPEC_BASE_PATH, <<"/adminsplit/v1.0">>).
-define(SPEC_PATH, "/adminsplit/v1.0/things").

%% A path of the built-in Admin API specification
%% (`priv/specs/bondy_admin_api.json`). Its version's `base_path` is
%% `/[v1.0]` — an optional Cowboy segment — so the unprefixed form routes.
-define(ADMIN_API_PATH, "/realms").
%% An administrator the Admin API cases authenticate as, and a realm holding a
%% user of the same name, whose tokens the master realm must refuse.
-define(OPERATOR, ~"adminsplit-operator").
-define(OPERATOR_PASS, ~"adminsplit-Passw0rd").
-define(FOREIGN_REALM, ~"com.example.adminsplit.foreign").
-define(TRACED, [bondy_http_gateway_rest_handler, bondy_oauth_jwt]).

all() ->
    [
        admin_api_is_served_on_the_admin_listener,
        admin_api_is_absent_from_the_public_listener,
        stored_specs_are_absent_from_the_admin_listeners,
        admin_local_is_injected_without_configuration,
        admin_local_socket_is_bound_and_serves,
        http_requests_are_rate_limited,
        listener_scope_http_budget_is_enforced,
        realm_scope_http_budget_is_enforced,
        oauth2_draws_from_the_auth_class,
        the_ready_probe_follows_a_blocking_alarm,
        registry_routes_read_the_named_realm,
        admin_local_is_not_locked_out_by_rbac,
        only_admin_local_routes_run_as_the_local_operator,
        admin_api_requires_a_master_realm_bearer_token,
        admin_api_listeners_mount_the_oauth2_endpoints,
        admin_api_accepts_the_master_realm_ticket_cookie,
        only_admin_api_routes_accept_the_ticket_cookie,
        malformed_bearer_token_is_unauthorized,
        admin_api_cookie_is_subject_to_master_realm_sources,
        admin_api_cookie_without_admin_role_is_forbidden,
        admin_api_csrf_checks_the_authenticating_realms_pair,
        named_source_matches_an_authid_in_any_case,
        user_grant_applies_to_an_authid_in_any_case,
        wamp_cookie_session_user_grant_applies_to_an_authid_in_any_case
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    ok = load_stored_spec(),
    ok = add_operator(),
    Config.

end_per_suite(Config) ->
    try
        bondy_http_gateway:delete(?SPEC_ID)
    catch
        _:_ -> ok
    end,
    {save_config, Config}.

%% =============================================================================
%% CASES
%% =============================================================================

admin_api_is_served_on_the_admin_listener(_Config) ->
    {ok, Status, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH),
    assert_routed(Status).

admin_api_is_absent_from_the_public_listener(_Config) ->
    %% The public listener declares `api_gateway` and not `admin_api`, so realm
    %% administration is not reachable on it.
    {ok, Status, _, _} = get_path(?PUBLIC, ?ADMIN_API_PATH),
    ?assertEqual(404, Status).

stored_specs_are_absent_from_the_admin_listeners(_Config) ->
    %% The other direction of the split: a listener declaring `admin_api` must
    %% NOT serve the specifications in storage. Two mechanisms produce that:
    %% `bondy_http_gateway:rebuild_dispatch_tables/0` recompiles only
    %% `api_gateway` listeners, and a listener without an `api_gateway` carrier
    %% never asks the gateway for stored routes. The HTTP assertion alone tests
    %% only the first, because the admin table predates the stored spec; the
    %% recompile below falsifies the second.
    {ok, Public, _, _} = get_path(?PUBLIC, ?SPEC_PATH),
    ?assertNotEqual(404, Public),

    %% Mechanism 1.
    {ok, Admin, _, _} = get_path(?ADMIN, ?SPEC_PATH),
    ?assertEqual(404, Admin),
    ?assertEqual(404, uds_get(admin_local_path(), ?SPEC_PATH)),

    %% Mechanism 2: recompile the admin listeners' tables with the
    %% specification in storage — the state a node restart would produce — and
    %% assert the routes are still not there.
    ok = recompile(?ADMIN),
    ok = recompile(admin_local),

    {ok, AdminAfter, _, _} = get_path(?ADMIN, ?SPEC_PATH),
    ?assertEqual(404, AdminAfter),
    ?assertEqual(404, uds_get(admin_local_path(), ?SPEC_PATH)),

    %% Each still serves its OWN specification, so the assertions above are
    %% about the stored spec and not about a table that lost every route.
    assert_routed(element(2, get_path(?ADMIN, ?ADMIN_API_PATH))),
    assert_routed(uds_get(admin_local_path(), ?ADMIN_API_PATH)).

admin_local_is_injected_without_configuration(_Config) ->
    %% `admin_local` is in no inventory an operator or this harness can write:
    %% neither `bondy_ct`'s declared one nor the built-in default mentions it,
    %% and the manager appends it. All three halves are asserted, because the
    %% latter two are what make the first a guarantee rather than a coincidence —
    %% an operator cannot preempt the injected entry with one of their own, and
    %% `bondy_listener_config:resolve/2` rejects the name outright if they try.
    ?assertEqual(
        false, lists:keymember(admin_local, 1, bondy_config:get(listeners, []))
    ),
    ?assertEqual(
        false,
        lists:keymember(
            admin_local, 1, bondy_listener_config:default_inventory()
        )
    ),
    {ok, Listener} = bondy_listener_manager:listener(admin_local),
    ?assertMatch(#{transport := uds, bind := {path, _}}, Listener),
    ?assertEqual(true, lists:member(admin_api, maps:get(services, Listener))),

    ?assertMatch(
        {error, {invalid_listener, admin_local, reserved_name}},
        bondy_listener_config:resolve(
            [
                {admin_local, #{
                    transport => tcp,
                    protocol => http,
                    port => 0,
                    services => [admin]
                }}
            ],
            fun bondy_config:get/2
        )
    ).

admin_local_socket_is_bound_and_serves(_Config) ->
    Path = admin_local_path(),

    %% The socket node exists. `filelib:is_file/1` CANNOT express this: a bound
    %% Unix domain socket has `file_info.type = other`, and `filelib:is_file/1`
    %% answers true only for `regular` and `directory` — verified directly, it
    %% returns `false` for a socket this node is listening on.
    ?assertMatch(
        {ok, #file_info{type = other}}, file:read_file_info(Path)
    ),

    %% And it is owner-only. The socket file's mode is the only access control a
    %% Unix domain listener has, and `gen_tcp:listen/2` creates the node with
    %% the process umask — 0755 under the umask here, 0777 under a umask of 0.
    %% Asserting the low 9 bits rather than `=/= 0777` so a partial narrowing
    %% fails too.
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertEqual(8#600, Mode band 8#777),

    %% And it SERVES. File existence alone is not evidence of a listener: a
    %% socket file outlives the process that created it, so a stale one from a
    %% previous boot is indistinguishable by any filesystem predicate
    %% (`gen_tcp:connect/4` on such a file returns `econnrefused` — verified).
    %% Completing a request is what proves the bind, the accept and the handler.
    %%
    %% `/ping` comes from the `admin` service and replies 204 with no
    %% authentication (`bondy_admin_ping_http_handler:init/2`).
    ?assertEqual(204, uds_get(Path, "/ping")),

    %% The Admin API is mounted here too, which is the point of the safety net:
    %% a node whose every TCP listener failed to bind is still administrable.
    assert_routed(uds_get(Path, ?ADMIN_API_PATH)).

%% The gateway REST handler's `rate_limited` hook draws from the `http`
%% class per source IP. Enabling ONLY that class both trips it and PINS
%% it — a hook drawing from any other class would never see a 429 here.
%% Statuses are not asserted before exhaustion: the `{http, 127.0.0.1}`
%% bucket is shared with any other suite in a run, so only "rapid
%% requests trip 429" and "off means served" are contract. Cowboy calls
%% `rate_limited` after `is_authorized`, so this case and the next two
%% authenticate: a request without a token is refused before any budget.
http_requests_are_rate_limited(_) ->
    {ok, Before, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH, operator_token()),
    ?assertNotEqual(429, Before),
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        http => #{rate => 1, capacity => 2}
    }),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH, operator_token())
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    %% Off again: the same source IP serves immediately — the verdict is
    %% config-driven, no depleted bucket outlives the feature.
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH, operator_token()),
    ?assertNotEqual(429, After).

%% The LISTENER scope of the rate-limit chain, on the wire: with the
%% NODE scope entirely off, a budget on this listener's own
%% `rate_limit.http` block throttles requests arriving through it — the
%% seat passes the cowboy `ref` (the listener name) as the listener
%% dimension. Same contract discipline as the node-scope case above:
%% only "rapid requests trip 429" and "off means served" are asserted.
listener_scope_http_budget_is_enforced(_) ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    ok = bondy_config:set(
        [?ADMIN, rate_limit], #{http => #{rate => 1, capacity => 2}}
    ),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH, operator_token())
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        ok = bondy_config:set([?ADMIN, rate_limit], undefined),
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH, operator_token()),
    ?assertNotEqual(429, After).

%% NODE and LISTENER scopes entirely off, a budget in the REALM's own
%% `rate_limit` property throttles requests the gateway serves on that
%% realm — the seat passes the API specification's realm as the realm
%% dimension. The Admin API runs on the master realm, so its property is
%% the one under test; clearing it must restore service (the chain no
%% longer consults the bucket).
realm_scope_http_budget_is_enforced(_) ->
    ok = bondy_config:set([security, rate_limit], #{enabled => false}),
    Master = <<"com.leapsight.bondy">>,
    _ = bondy_realm:update(Master, #{
        rate_limit => #{
            http => #{per_caller => #{rate => 1, capacity => 2}}
        }
    }),
    try
        Results = [
            get_path(?ADMIN, ?ADMIN_API_PATH, operator_token())
         || _ <- lists:seq(1, 6)
        ],
        {ok, Last, Headers, _} = lists:last(Results),
        ?assertEqual(429, Last),
        ?assertMatch({_, _}, lists:keyfind(<<"retry-after">>, 1, Headers))
    after
        _ = bondy_realm:update(Master, #{rate_limit => undefined}),
        ok = bondy_config:set([security, rate_limit], undefined)
    end,
    {ok, After, _, _} = get_path(?ADMIN, ?ADMIN_API_PATH, operator_token()),
    ?assertNotEqual(429, After).

%% The OAuth2 endpoints draw from the `auth` class — the shared per-IP
%% credential-guessing budget WAMP AUTHENTICATE consumes — while the
%% gateway hook does NOT: with only `auth` enabled, the OAuth2 callback
%% throttles and the gateway callback stays open. A distinct loopback
%% peer keys buckets no other suite touches.
oauth2_draws_from_the_auth_class(_) ->
    Req = #{ref => ?ADMIN, peer => {{127, 0, 0, 88}, 5000}, headers => #{}},
    %% The handler state is built by the handler itself — its
    %% `rate_limited` reads the realm dimension from it, so a hand-rolled
    %% stand-in would not exercise the real seat.
    {cowboy_rest, _, OauthSt} = bondy_oauth2_rest_handler:init(Req, #{
        realm_uri => <<"com.leapsight.bondy">>,
        token_path => <<"/token">>,
        revoke_path => <<"/revoke">>
    }),
    ok = bondy_config:set([security, rate_limit], #{
        enabled => true,
        auth => #{rate => 1, capacity => 1}
    }),
    try
        ?assertMatch(
            {false, _, _},
            bondy_oauth2_rest_handler:rate_limited(Req, OauthSt)
        ),
        ?assertMatch(
            {{true, _}, _, _},
            bondy_oauth2_rest_handler:rate_limited(Req, OauthSt)
        ),
        ?assertMatch(
            {false, _, _},
            bondy_http_gateway_rest_handler:rate_limited(Req, #{})
        )
    after
        ok = bondy_config:set([security, rate_limit], undefined)
    end.

%% =============================================================================
%% HELPERS
%% =============================================================================

%% The operator is configured as an operator would: `oauth2` added to the
%% master realm's methods, and a loopback `oauth2` source for the user.
add_operator() ->
    Master = ?MASTER_REALM_URI,
    Methods = bondy_realm:authmethods(Master),
    _ = bondy_realm:update(Master, #{
        ~"authmethods" => lists:usort([?OAUTH2_AUTH | Methods])
    }),
    ok = add_oauth2_user(Master, [~"bondy.administrators"]),
    _ = bondy_realm:create(#{
        uri => ?FOREIGN_REALM,
        authmethods => [?OAUTH2_AUTH, ?PASSWORD_AUTH]
    }),
    ok = add_oauth2_user(?FOREIGN_REALM, []).

add_oauth2_user(Uri, Groups) ->
    {ok, _} = bondy_rbac_user:add(
        Uri,
        bondy_rbac_user:new(#{
            username => ?OPERATOR,
            password => ?OPERATOR_PASS,
            groups => Groups
        })
    ),
    {ok, _} = bondy_rbac_source:add(Uri, #{
        ~"usernames" => [?OPERATOR],
        ~"authmethod" => ?OAUTH2_AUTH,
        ~"cidr" => ~"127.0.0.0/8",
        ~"meta" => #{}
    }),
    ok.

operator_token() ->
    issue_token(?MASTER_REALM_URI).

issue_token(Uri) ->
    {ok, Ctxt} = bondy_auth:init(
        bondy_session_id:new(), Uri, ?OPERATOR, all, {127, 0, 0, 1}
    ),
    {ok, Token} = bondy_oauth_token:issue(password, Ctxt, #{}),
    {ok, {JWT, _}} = bondy_oauth_token:to_access_token(Token),
    JWT.

get_path(Listener, Path, JWT) ->
    hackney:request(
        get,
        url(Listener, Path),
        [{~"authorization", <<"Bearer ", JWT/binary>>}],
        <<>>,
        []
    ).

post_path(Listener, Path) ->
    hackney:request(
        post,
        url(Listener, Path),
        [{~"content-type", ~"application/x-www-form-urlencoded"}],
        <<>>,
        []
    ).

url(Listener, Path) ->
    {ok, #{bind := {port, Port}}} = bondy_listener_manager:listener(Listener),
    iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), Path]).

admin_local_path() ->
    {ok, #{transport := uds, bind := {path, Path}}} =
        bondy_listener_manager:listener(admin_local),
    Path.

%% Rebuilds one listener's dispatch table from its current services and the
%% current contents of storage — what `bondy_listener_ranch:start/1` does. A
%% running listener reads its table through `{persistent_term, Key}`, so this
%% takes effect without restarting it.
recompile(Name) ->
    {ok, Listener} = bondy_listener_manager:listener(Name),
    bondy_listener_ranch:recompile_dispatch(Listener).

%% A minimal stored specification with a static action, so the public listener
%% answers it without authentication and the assertion turns purely on whether
%% the route is mounted.
load_stored_spec() ->
    _ = bondy_realm:create(#{
        uri => ?SPEC_REALM,
        description => <<"Admin/public exposure split">>,
        security_enabled => false
    }),
    ok = bondy_http_gateway:load(#{
        <<"id">> => ?SPEC_ID,
        <<"name">> => ?SPEC_ID,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => ?SPEC_REALM,
        <<"variables">> => #{<<"schemes">> => [<<"http">>]},
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"schemes">> => <<"{{variables.schemes}}">>,
            %% Empty map = no security scheme, so the public listener
            %% answers without credentials and the assertion turns purely on
            %% whether the route is mounted.
            <<"security">> => #{}
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => ?SPEC_BASE_PATH,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"is_collection">> => false,
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"static">>
                            },
                            <<"response">> => #{
                                <<"on_result">> => #{<<"body">> => <<>>},
                                <<"on_error">> => #{<<"body">> => <<>>}
                            }
                        }
                    }
                }
            }
        }
    }),
    _ = bondy_http_gateway:rebuild_dispatch_tables(),
    ok.

%% Routed AND served. Not 404 means the route exists; not 5xx means the handler
%% ran to completion. 200, 401 and 403 all satisfy this, and which one is
%% returned depends on authentication, which this suite does not exercise.
%% A handler crash is a 500 on a route that exists, which a not-404 assertion
%% alone passes.
%% The Admin API calls its procedures from the master realm. A `wamp.*` meta
%% procedure reads only the caller's realm, so these routes reach a tenant
%% realm's registry only through the realm-first `bondy.*` procedures. The
%% operator holds `bondy.administrators`, whose grants cover `wamp.` too, so a
%% route still calling a `wamp.*` procedure fails on its arguments rather than
%% on authorisation.
registry_routes_read_the_named_realm(_Config) ->
    Realm = ~"com.example.adminsplit.registry",
    _ = bondy_realm:create(Realm),
    {ok, Id} = bondy_dealer:register(
        ~"com.example.adminsplit.registry.proc",
        #{},
        Realm,
        bondy_ref:new(internal, {?MODULE, on_call})
    ),
    Token = operator_token(),
    Path = ["/realms/", Realm, "/registrations/", integer_to_list(Id)],
    ?assertMatch(#{~"id" := Id}, json_body(get_path(?ADMIN, Path, Token))),
    ?assertEqual(
        [], json_body(get_path(?ADMIN, [Path, "/callees"], Token))
    ),
    ?assertMatch(
        {ok, 404, _, _},
        get_path(
            ?ADMIN, ["/realms/", Realm, "/registrations_summary"], Token
        )
    ).

%% With every grant of `bondy.administrators` revoked, and none for
%% `anonymous`, no RBAC identity can administer the master realm. The socket
%% must still serve the Admin API, and the TCP listener must not.
admin_local_is_not_locked_out_by_rbac(_Config) ->
    Uri = ?MASTER_REALM_URI,
    Group = ~"bondy.administrators",
    Requests = [
        bondy_rbac:request(#{
            roles => [Group],
            permissions => Permissions,
            uri => ResourceUri,
            match => Match
        })
     || {{ResourceUri, Match}, Permissions} <- bondy_rbac:group_grants(
            Uri, Group
        )
    ],
    ?assertNotEqual([], Requests),
    [ok = bondy_rbac:revoke(Uri, R) || R <- Requests],
    try
        ?assertEqual([], bondy_rbac:group_grants(Uri, Group)),
        ?assertEqual(200, uds_get(admin_local_path(), ?ADMIN_API_PATH)),
        ?assertMatch(
            {ok, 403, _, _},
            get_path(?ADMIN, ?ADMIN_API_PATH, operator_token())
        )
    after
        [ok = bondy_rbac:grant(Uri, R) || R <- Requests]
    end.

%% The route state that exempts a request from RBAC is set from the
%% listener's name alone. Every other listener, including an operator's own
%% Unix domain listener carrying `admin_api`, gets Admin API routes without
%% it, and stored specifications never carry it.
only_admin_local_routes_run_as_the_local_operator(_Config) ->
    Listeners = bondy_listener_manager:listeners(),
    {ok, AdminLocal} = bondy_listener_manager:listener(admin_local),
    OperatorUds = AdminLocal#{name => operator_uds},
    Others = [L || #{name := N} = L <- Listeners, N =/= admin_local],
    ?assertNotEqual([], Others),

    LocalStates = rest_states(bondy_http_gateway:admin_api_routes(AdminLocal)),
    ?assertNotEqual([], LocalStates),
    ?assertEqual(
        [], [
            St
         || St <- LocalStates, maps:get(local_operator, St, false) =/= true
        ]
    ),
    ?assertNotEqual(
        [], rest_states(bondy_http_gateway:routes(AdminLocal))
    ),
    [
        ?assertEqual(
            [],
            [
                St
             || St <- rest_states(bondy_http_gateway:admin_api_routes(L)),
                maps:is_key(local_operator, St)
            ],
            maps:get(name, L)
        )
     || L <- [OperatorUds | Others]
    ],
    [
        ?assertEqual(
            [],
            [
                St
             || St <- rest_states(bondy_http_gateway:routes(L)),
                maps:is_key(local_operator, St)
            ],
            maps:get(name, L)
        )
     || L <- [AdminLocal | Listeners]
    ].

rest_states(Rules) ->
    [
        St
     || {_Host, Paths} <- Rules,
        {_Path, bondy_http_gateway_rest_handler, St} <- Paths
    ].

%% The built-in Admin API accepts a bearer token the master realm issued, the
%% same way a stored API Gateway specification with an `oauth2` scheme does.
%% A request without one, or with a token another realm issued to a user of
%% the same name, is refused. `admin_local` needs no token.
admin_api_requires_a_master_realm_bearer_token(_Config) ->
    ?assertMatch({ok, 401, _, _}, get_path(?ADMIN, ?ADMIN_API_PATH)),
    ?assertMatch(
        {ok, 200, _, _}, get_path(?ADMIN, ?ADMIN_API_PATH, operator_token())
    ),
    ?assertMatch(
        {ok, 401, _, _},
        get_path(?ADMIN, ?ADMIN_API_PATH, issue_token(?FOREIGN_REALM))
    ),
    ?assertEqual(200, uds_get(admin_local_path(), ?ADMIN_API_PATH)).

%% The `oauth2` scheme mounts its token and revocation endpoints next to the
%% Admin API, so a client of a listener carrying `admin_api` can obtain a
%% token from it. The public listener carries neither.
admin_api_listeners_mount_the_oauth2_endpoints(_Config) ->
    [
        ?assertMatch(
            {ok, Status, _, _} when Status =/= 404,
            post_path(?ADMIN, Path)
        )
     || Path <- ["/oauth/token", "/oauth/revoke"]
    ],
    ?assertMatch({ok, 404, _, _}, post_path(?PUBLIC, "/oauth/token")).

%% A request without `Authorization` may authenticate with the master realm's
%% OIDC ticket cookie, checked as on an `oidc` route: the master realm's
%% `authmethods` must include `cookie`, a source must allow it from the
%% client's address, and a request that changes state needs the CSRF token. A
%% bearer token, when sent, is the credential used.
admin_api_accepts_the_master_realm_ticket_cookie(_Config) ->
    Master = ?MASTER_REALM_URI,
    Ticket = admin_ticket(~"oidc-admin@example.com"),
    Csrf = ~"admin-csrf-token",
    Cookie = cookie_header(<<>>, Ticket, Csrf),
    Post = fun(Headers) ->
        {ok, Status, _, _} = hackney:request(
            post,
            url(?ADMIN, ?ADMIN_API_PATH),
            [{~"content-type", ~"application/json"}, Cookie | Headers],
            <<"{}">>,
            []
        ),
        Status
    end,
    with_cookie_source(fun() ->
        with_cookie_method(fun() ->
            ?assertEqual(200, cookie_get(Ticket, [])),
            ?assertEqual(403, Post([])),
            ?assertNotEqual(403, Post([{~"x-csrf-token", Csrf}])),
            ?assertNotEqual(401, Post([{~"x-csrf-token", Csrf}])),
            Foreign = issue_token(?FOREIGN_REALM),
            ?assertEqual(
                401,
                cookie_get(Ticket, [
                    {~"authorization", <<"Bearer ", Foreign/binary>>}
                ])
            )
        end),
        ?assertNot(
            lists:member(?WAMP_COOKIE_AUTH, bondy_realm:authmethods(Master))
        ),
        ?assertEqual(401, cookie_get(Ticket, []))
    end).

%% The route state that lets a request authenticate with the ticket cookie
%% instead of its specification's scheme is set by `admin_api_routes/1` alone:
%% every Admin API REST route carries it, and no stored specification's route
%% does.
only_admin_api_routes_accept_the_ticket_cookie(_Config) ->
    Listeners = bondy_listener_manager:listeners(),
    AdminStates = lists:append([
        rest_states(bondy_http_gateway:admin_api_routes(L))
     || L <- Listeners
    ]),
    ?assertNotEqual([], AdminStates),
    ?assertEqual(
        [],
        [
            St
         || St <- AdminStates,
            maps:get(accepts_ticket_cookie, St, false) =/= true
        ]
    ),
    ?assertEqual(
        [],
        [
            maps:get(name, L)
         || L <- Listeners,
            St <- rest_states(bondy_http_gateway:routes(L)),
            maps:is_key(accepts_ticket_cookie, St)
        ]
    ).

%% A bearer value that is not a JWT is an invalid credential, answered 401
%% without an error report. `bondy_oauth_jwt:verify/2` serves the WAMP `oauth2`
%% method, and is held to the same. Each error shape of the decode is covered
%% by `bondy_oauth_jwt_test`.
malformed_bearer_token_is_unauthorized(_Config) ->
    Short = ~"not-a-token",
    Long = binary:copy(~"x", 48),
    Self = self(),
    Errors = capture_errors(fun() ->
        Self !
            {results,
                [
                    {http, T, element(2, get_path(?ADMIN, ?ADMIN_API_PATH, T))}
                 || T <- [Short, Long]
                ] ++
                    [
                        {verify, T,
                            bondy_oauth_jwt:verify(?MASTER_REALM_URI, T)}
                     || T <- [Short, Long]
                    ]}
    end),
    Results =
        receive
            {results, R} -> R
        end,
    ?assertEqual(
        {
            [
                {http, Short, 401},
                {http, Long, 401},
                {verify, Short, {error, oauth2_invalid_grant}},
                {verify, Long, {error, oauth2_invalid_grant}}
            ],
            []
        },
        {Results, [maps:get(msg, E) || E <- Errors]}
    ).

%% An OIDC identity is held to the master realm's sources like any other
%% administrator: with no source allowing `cookie` from loopback, its cookie
%% is refused, whether or not a local user record exists for it. A realm-wide
%% `all` source admits an identity Bondy holds no record for.
admin_api_cookie_is_subject_to_master_realm_sources(_Config) ->
    Master = ?MASTER_REALM_URI,
    External = ~"oidc-external@example.com",
    Stored = ~"oidc-stored@example.com",
    {ok, _} = bondy_rbac_user:add(
        Master,
        bondy_rbac_user:new(#{
            username => Stored, groups => [~"bondy.administrators"]
        })
    ),
    [
        ?assertEqual(
            [],
            [
                S
             || S <- bondy_rbac_source:match(Master, Id, {127, 0, 0, 1}),
                bondy_rbac_source:authmethod(S) =:= ?WAMP_COOKIE_AUTH
            ]
        )
     || Id <- [External, Stored]
    ],
    with_cookie_method(fun() ->
        ?assertEqual(401, cookie_get(admin_ticket(Stored), [])),
        ?assertEqual(401, cookie_get(admin_ticket(External), [])),
        with_cookie_source(fun() ->
            ?assertEqual(200, cookie_get(admin_ticket(External), [])),
            ?assertEqual(200, cookie_get(admin_ticket(Stored), []))
        end)
    end).

%% The Admin API's permissions apply to a cookie-authenticated caller: a
%% ticket that carries no role is authenticated and then refused.
admin_api_cookie_without_admin_role_is_forbidden(_Config) ->
    {ok, Ticket, _} = bondy_oidc_ticket:issue(
        ?MASTER_REALM_URI, ~"oidc-nobody@example.com", ~"idp", #{}, #{
            authroles => []
        }
    ),
    with_cookie_auth(fun() -> ?assertEqual(403, cookie_get(Ticket, [])) end).

%% A browser keeps the cookie pair of every realm it signed in to. The CSRF
%% token is checked against the pair of the realm whose cookie authenticated,
%% even when another realm's pair arrives first.
admin_api_csrf_checks_the_authenticating_realms_pair(_Config) ->
    Other = ?FOREIGN_REALM,
    Csrf = ~"master-csrf",
    Others = iolist_to_binary([
        bondy_http_utils:ticket_cookie_name(Other),
        "=other-ticket; ",
        bondy_http_utils:csrf_cookie_name(Other),
        "=other-csrf; "
    ]),
    with_cookie_auth(fun() ->
        {ok, Status, _, _} = hackney:request(
            post,
            url(?ADMIN, ?ADMIN_API_PATH),
            [
                {~"content-type", ~"application/json"},
                {~"x-csrf-token", Csrf},
                cookie_header(
                    Others,
                    admin_ticket(~"oidc-admin@example.com"),
                    Csrf
                )
            ],
            <<"{}">>,
            []
        ),
        ?assertNotEqual(403, Status),
        ?assertNotEqual(401, Status)
    end).

%% An IdP names a subject in whatever case it stores, and Bondy stores the
%% user casefolded. A source naming the stored user admits its cookie whatever
%% the case of the ticket's authid; no `all` source allows `cookie` here.
named_source_matches_an_authid_in_any_case(_Config) ->
    Master = ?MASTER_REALM_URI,
    Username = ~"oidc-case@example.com",
    Cidr = ~"127.0.0.1/32",
    {ok, _} = bondy_rbac_user:add(
        Master,
        bondy_rbac_user:new(#{
            username => Username, groups => [~"bondy.administrators"]
        })
    ),
    {ok, _} = bondy_rbac_source:add(Master, #{
        ~"usernames" => [Username],
        ~"authmethod" => ?WAMP_COOKIE_AUTH,
        ~"cidr" => Cidr,
        ~"meta" => #{}
    }),
    try
        with_cookie_method(fun() ->
            ?assertEqual(
                {200, 200},
                {
                    cookie_get(admin_ticket(Username), []),
                    cookie_get(admin_ticket(~"OIDC-Case@Example.com"), [])
                }
            )
        end)
    after
        ok = bondy_rbac_source:remove(Master, [Username], Cidr)
    end.

%% A permission granted to the stored user by name applies to its cookie
%% whatever the case of the ticket's authid. The ticket carries no role, so
%% the grant is the only permission the caller holds.
user_grant_applies_to_an_authid_in_any_case(_Config) ->
    Master = ?MASTER_REALM_URI,
    Username = ~"oidc-grant@example.com",
    {ok, _} = bondy_rbac_user:add(
        Master, bondy_rbac_user:new(#{username => Username})
    ),
    ok = bondy_rbac:grant(Master, #{
        ~"permissions" => [~"wamp.call"],
        ~"uri" => ~"bondy.realm.list",
        ~"match" => ~"exact",
        ~"roles" => [Username]
    }),
    Get = fun(Authid) ->
        {ok, Ticket, _} = bondy_oidc_ticket:issue(
            Master, Authid, ~"idp", #{}, #{authroles => []}
        ),
        cookie_get(Ticket, [])
    end,
    with_cookie_auth(fun() ->
        ?assertEqual(
            {200, 200}, {Get(Username), Get(~"OIDC-Grant@Example.com")}
        )
    end).

%% The same for a WAMP session opened with the cookie over HTTP long-poll: the
%% session's authid is the stored username, and the user's grant applies.
wamp_cookie_session_user_grant_applies_to_an_authid_in_any_case(_Config) ->
    Master = ?MASTER_REALM_URI,
    Username = ~"oidc-wamp-grant@example.com",
    {ok, _} = bondy_rbac_user:add(
        Master, bondy_rbac_user:new(#{username => Username})
    ),
    ok = bondy_rbac:grant(Master, #{
        ~"permissions" => [~"wamp.call"],
        ~"uri" => ~"bondy.realm.list",
        ~"match" => ~"exact",
        ~"roles" => [Username]
    }),
    with_cookie_auth(fun() ->
        ?assertEqual(
            [{Username, result}, {Username, result}],
            [
                cookie_session_call(Authid, ~"bondy.realm.list")
             || Authid <- [Username, ~"OIDC-WAMP-Grant@Example.com"]
            ]
        )
    end).

%% The internal callee registered by `registry_routes_read_the_named_realm/1`;
%% the case never calls it.
on_call(_Arg, _KWArgs, _Details) ->
    {ok, #{}, [], #{}}.

%% Opens a long-poll WAMP session on the master realm with the claims of a
%% roleless OIDC ticket for `Authid`, calls `Procedure` once, and returns the
%% session's authid and the reply's message type.
cookie_session_call(Authid, Procedure) ->
    Master = ?MASTER_REALM_URI,
    {ok, Ticket, _} = bondy_oidc_ticket:issue(
        Master, Authid, ~"idp", #{}, #{authroles => []}
    ),
    {ok, Claims} = bondy_ticket:verify(Ticket),
    TransportId = iolist_to_binary([
        "admin-suite-",
        integer_to_binary(erlang:unique_integer([positive]))
    ]),
    {ok, Pid} = bondy_http_transport_session_sup:start_child(
        TransportId, Master, bondy_session_id:new()
    ),
    try
        ok = bondy_http_transport_session:init_protocol(
            Pid, {http_longpoll, text, json}, {{127, 0, 0, 1}, 12345}
        ),
        ok = bondy_http_transport_session:set_auth_claims(Pid, Claims),
        #welcome{details = #{authid := SessionAuthid}} = longpoll_exchange(
            Pid,
            #hello{
                realm_uri = Master,
                details = #{~"roles" => #{~"caller" => #{}}}
            }
        ),
        Reply = longpoll_exchange(
            Pid,
            #call{request_id = 1, options = #{}, procedure_uri = Procedure}
        ),
        {SessionAuthid, element(1, Reply)}
    after
        ok = bondy_http_transport_session:close(Pid)
    end.

longpoll_exchange(Pid, Message) ->
    ok = bondy_http_transport_session:handle_client_message(
        Pid, bondy_wamp_encoding:encode(Message, json)
    ),
    case bondy_http_transport_session:poll_receive(Pid, 5000) of
        {ok, {messages, [Reply]}} ->
            Reply;
        {ok, {replies, [Bin]}} ->
            {[Reply], <<>>} = bondy_wamp_encoding:decode(
                {http_longpoll, text, json}, Bin
            ),
            Reply
    end.

admin_ticket(Authid) ->
    {ok, Ticket, _} = bondy_oidc_ticket:issue(
        ?MASTER_REALM_URI, Authid, ~"idp", #{}, #{
            authroles => [~"bondy.administrators"]
        }
    ),
    Ticket.

cookie_header(Prefix, Ticket, Csrf) ->
    Master = ?MASTER_REALM_URI,
    {
        ~"cookie",
        iolist_to_binary([
            Prefix,
            bondy_http_utils:ticket_cookie_name(Master),
            "=",
            Ticket,
            "; ",
            bondy_http_utils:csrf_cookie_name(Master),
            "=",
            Csrf
        ])
    }.

cookie_get(Ticket, Headers) ->
    {ok, Status, _, _} = hackney:request(
        get,
        url(?ADMIN, ?ADMIN_API_PATH),
        [cookie_header(<<>>, Ticket, ~"csrf") | Headers],
        <<>>,
        []
    ),
    Status.

%% The configuration an operator writes for OIDC administration: `cookie` among
%% the master realm's methods, and a source allowing it to every user from the
%% client's network.
with_cookie_auth(Fun) ->
    with_cookie_method(fun() -> with_cookie_source(Fun) end).

with_cookie_method(Fun) ->
    Master = ?MASTER_REALM_URI,
    Methods = bondy_realm:authmethods(Master),
    _ = bondy_realm:update(Master, #{
        ~"authmethods" => lists:usort([?WAMP_COOKIE_AUTH | Methods])
    }),
    try
        Fun()
    after
        _ = bondy_realm:update(Master, #{~"authmethods" => Methods})
    end.

%% A /32, so removing it leaves the master realm's default `127.0.0.0/8`
%% sources in place.
with_cookie_source(Fun) ->
    Master = ?MASTER_REALM_URI,
    Cidr = ~"127.0.0.1/32",
    {ok, _} = bondy_rbac_source:add(Master, #{
        ~"usernames" => ~"all",
        ~"authmethod" => ?WAMP_COOKIE_AUTH,
        ~"cidr" => Cidr,
        ~"meta" => #{}
    }),
    try
        Fun()
    after
        ok = bondy_rbac_source:remove(Master, all, Cidr)
    end.

%% Error-level reports logged while `Fun` runs whose stack trace passes through
%% the gateway handler or the JWT module. The handler logs through
%% `logger:log/3`, so its events carry no `mfa`.
capture_errors(Fun) ->
    Id = admin_listener_suite_errors,
    ok = logger:add_handler(Id, ?MODULE, #{
        level => error, config => #{pid => self()}
    }),
    try
        _ = Fun(),
        collect_errors([])
    after
        ok = logger:remove_handler(Id)
    end.

collect_errors(Acc) ->
    receive
        {logged, #{msg := {report, #{stacktrace := Trace}}} = Event} ->
            case [M || {M, _, _, _} <- Trace, lists:member(M, ?TRACED)] of
                [] -> collect_errors(Acc);
                [_ | _] -> collect_errors([Event | Acc])
            end;
        {logged, #{}} ->
            collect_errors(Acc)
    after 200 ->
        lists:reverse(Acc)
    end.

log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Event},
    ok.

%% @private
json_body({ok, Status, _, Ref}) ->
    {ok, Body} = hackney:body(Ref),
    ?assertEqual(200, Status, Body),
    json:decode(Body).

assert_routed(Status) ->
    ct:pal("status ~p", [Status]),
    ?assertNotEqual(404, Status),
    ?assert(Status < 500).

-doc """
`/ready` answers 503 while an alarm declaring `affects_ready` is raised, and
204 once it clears.

This is the only hop between `bondy_router_app:is_ready/0` and a load balancer.
`bondy_router_app_readiness_test` drives the real `alarm_handler` manager and
the published `atomics` cell, but stops at the boolean. The mapping below it —
true to 204, false to 503 — is
four lines with one branch, and inverting them would take every node out of
rotation permanently or keep every failed node in it.

The alarm carries an EXPLICIT `affects_ready => true` because no catalogue
entry declares one. That is the residual gap and it is structural: the
catalogue is a literal table, so the "the entry declared it" resolution can
only be exercised by shipping an entry that does. See
`bondy_alarm_catalogue:list/0`'s own note.
""".
the_ready_probe_follows_a_blocking_alarm(_) ->
    Id = {test_ready_probe_alarm, ~"drain this node"},
    Saved = bondy_config:get(status, undefined),
    ok = bondy_config:set(status, ready),
    try
        %% The baseline matters as much as the 503: without it a handler that
        %% answered 503 unconditionally would pass the interesting assertion.
        ?assertEqual(204, element(2, get_path(?ADMIN, "/ready"))),

        ok = bondy_alarm_handler:set_alarm(
            {Id, ~"raised by bondy_admin_listener_SUITE"},
            #{affects_ready => true}
        ),
        ok = await_ready_flag(false),
        ?assertEqual(503, element(2, get_path(?ADMIN, "/ready"))),

        ok = alarm_handler:clear_alarm(Id),
        ok = await_ready_flag(true),
        ?assertEqual(204, element(2, get_path(?ADMIN, "/ready")))
    after
        ok = alarm_handler:clear_alarm(Id),
        ok = bondy_config:set(status, Saved)
    end.

%% @private
%% Raising and clearing are CASTS to the shared `alarm_handler` manager, so a
%% probe taken the instant `set_alarm/2` returns is racing the mailbox. Any
%% `gen_event:call` to the handler is the barrier; `list/0` is the cheapest.
await_ready_flag(Expected) ->
    _ = bondy_alarm_handler:list(),
    ?assertEqual(Expected, bondy_router_app:is_ready()),
    ok.

%% The port comes from the resolved inventory rather than a literal, so the case
%% follows a listener whose configured port changes.
get_path(Listener, Path) ->
    hackney:request(get, url(Listener, Path), [], <<>>, []).

%% A Unix domain socket needs a client that can address one, and hackney takes a
%% URL. `{packet, http_bin}` makes the emulator parse the status line, so this
%% is a complete HTTP/1.1 exchange with no dependency.
uds_get(Path, Target) ->
    {ok, Sock} = gen_tcp:connect(
        {local, Path}, 0, [binary, {active, false}, {packet, http_bin}], 5000
    ),
    Request = [
        "GET ",
        Target,
        " HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Connection: close\r\n\r\n"
    ],
    ok = gen_tcp:send(Sock, Request),
    Status =
        case gen_tcp:recv(Sock, 0, 5000) of
            {ok, {http_response, _Vsn, Code, _Reason}} -> Code;
            Other -> Other
        end,
    ok = gen_tcp:close(Sock),
    Status.
