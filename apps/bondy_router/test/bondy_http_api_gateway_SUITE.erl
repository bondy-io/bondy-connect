%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(COOKIE, ~"cookie").
-compile([nowarn_export_all, export_all]).

all() ->
    bondy_ct:all().

groups() ->
    [{main, [parallel], bondy_ct:tests(?MODULE)}].

%% The spec parser validates WAMP URIs through `bondy_wamp_config`, so the
%% suite starts Bondy itself rather than depend on an earlier suite in the
%% same run having started it.
init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    Config.

end_per_suite(Config) ->
    {save_config, Config}.

simple_1_test(_) ->
    Spec = #{
        <<"id">> => <<"com.myapi">>,
        <<"name">> => <<"com.myapi">>,
        <<"host">> => <<"[www.]myapi.com">>,
        <<"realm_uri">> => <<"com.myapi">>,
        <<"variables">> => #{
            <<"foo">> => 100,
            <<"schemes">> => [<<"http">>],
            <<"oauth2">> => #{
                <<"type">> => <<"oauth2">>,
                <<"flow">> => <<"resource_owner_password_credentials">>,
                <<"token_path">> => <<"/auth/token">>,
                <<"revoke_token_path">> => <<"/auth/revoke_token">>,
                <<"schemes">> => <<"{{variables.schemes}}">>
            }
        },
        <<"defaults">> => #{
            <<"timeout">> => 15000,
            <<"security">> => <<"{{variables.oauth2}}">>,
            <<"schemes">> => <<"{{variables.schemes}}">>
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"variables">> => #{
                    <<"foo">> => 200
                },
                <<"defaults">> => #{
                    <<"timeout">> => 20000
                },
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"variables">> => #{
                            <<"foo">> => 300
                        },
                        <<"defaults">> => #{
                            <<"timeout">> => 30000
                        },
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> =>
                                    <<"com.magenta.things.list">>,
                                <<"options">> => #{},
                                <<"args">> => [
                                    <<"{{request.query_params}}">>
                                ],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{
                                    <<"body">> => <<"{{action.result}}">>
                                }
                            }
                        }
                    },
                    <<"/agents">> => #{
                        <<"security">> => #{},
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.myapi.foo">>,
                                <<"options">> => #{},
                                <<"args">> => [<<"{{variables.foo}}">>],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    },
    bondy_http_gateway_api_spec_parser:parse(Spec).

call_timeout_merge_test(_) ->
    Merge = fun(Timeout, Opts) ->
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"timeout">>, timeout], Timeout, Opts
        )
    end,

    %% The action timeout is merged when options define no timeout
    ?assertEqual(#{<<"timeout">> => 90000}, Merge(90000, #{})),

    %% Per WAMP, options.timeout = 0 means the Call Timeout feature is
    %% disabled, so the action timeout applies
    ?assertEqual(
        #{<<"timeout">> => 90000},
        Merge(90000, #{<<"timeout">> => 0})
    ),

    %% An explicit non-zero options.timeout wins over the action timeout
    ?assertEqual(
        #{<<"timeout">> => 120000},
        Merge(90000, #{<<"timeout">> => 120000})
    ),
    ?assertEqual(
        #{timeout => 120000},
        Merge(90000, #{timeout => 120000})
    ),

    %% An unset or invalid action timeout leaves the options untouched
    ?assertEqual(#{}, Merge(0, #{})),
    ?assertEqual(#{}, Merge(undefined, #{})).

call_retries_merge_test(_) ->
    Merge = fun(Retries, Opts) ->
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"_retries">>, '_retries'], Retries, Opts
        )
    end,
    ?assertEqual(#{<<"_retries">> => 2}, Merge(2, #{})),
    ?assertEqual(#{<<"_retries">> => 2}, Merge(2, #{<<"_retries">> => 0})),
    ?assertEqual(#{<<"_retries">> => 5}, Merge(2, #{<<"_retries">> => 5})),
    ?assertEqual(#{'_retries' => 5}, Merge(2, #{'_retries' => 5})),
    ?assertEqual(#{}, Merge(0, #{})),
    ?assertEqual(#{}, Merge(-1, #{})).

%% The action `timeout` and `retries` (inherited from `defaults`) must survive
%% parsing and, once merged, govern the WAMP call options.
call_timeout_spec_flow_test(_) ->
    Spec = #{
        <<"id">> => <<"com.timeout_api">>,
        <<"name">> => <<"com.timeout_api">>,
        <<"host">> => <<"timeout-api.com">>,
        <<"realm_uri">> => <<"com.timeout_api">>,
        <<"defaults">> => #{
            <<"timeout">> => 95000,
            <<"retries">> => 2,
            <<"security">> => #{},
            <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => <<"com.timeout_api.get">>,
                                <<"options">> => #{},
                                <<"args">> => [],
                                <<"kwargs">> => #{}
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    },
    Parsed = bondy_http_gateway_api_spec_parser:parse(Spec),
    Action = maps_utils:get_path(
        [
            <<"versions">>,
            <<"1.0.0">>,
            <<"paths">>,
            <<"/things">>,
            <<"get">>,
            <<"action">>
        ],
        Parsed
    ),
    #{
        <<"timeout">> := Timeout,
        <<"retries">> := Retries,
        <<"options">> := Opts
    } = Action,
    ?assertEqual({95000, 2}, {Timeout, Retries}),
    ?assertEqual(
        #{<<"timeout">> => 95000, <<"_retries">> => 2},
        bondy_http_gateway_rest_handler:merge_call_option(
            [<<"_retries">>, '_retries'],
            Retries,
            bondy_http_gateway_rest_handler:merge_call_option(
                [<<"timeout">>, timeout], Timeout, Opts
            )
        )
    ).

publish_rejects_retries_test(_) ->
    ?assertError(
        {unsupported_keys, {action, <<"wamp_publish">>}, [<<"retries">>]},
        parse_action(publish_action(#{<<"retries">> => 2}), #{})
    ).

call_rejects_retry_timeout_test(_) ->
    ?assertError(
        {unsupported_keys, {action, <<"wamp_call">>}, [<<"retry_timeout">>]},
        parse_action(call_action(#{<<"retry_timeout">> => 2000}), #{})
    ).

forward_rejects_an_unbounded_retry_timeout_test(_) ->
    ?assertError(
        #{key := <<"retry_timeout">>},
        parse_action(
            #{
                <<"type">> => <<"forward">>,
                <<"host">> => <<"http://localhost:1">>,
                <<"retry_timeout">> => infinity
            },
            #{}
        )
    ).

call_accepts_an_alias_test(_) ->
    Action = parse_action(
        maps:remove(<<"args">>, call_action(#{<<"arguments">> => [1]})), #{}
    ),
    ?assertMatch(#{<<"args">> := [1]}, Action).

publish_does_not_inherit_retries_test(_) ->
    Action = parse_action(publish_action(#{}), #{<<"retries">> => 2}),
    ?assertNot(maps:is_key(<<"retries">>, Action)).

call_action(Extra) ->
    maps:merge(
        #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => <<"com.actions_api.call">>,
            <<"args">> => []
        },
        Extra
    ).

publish_action(Extra) ->
    maps:merge(
        #{
            <<"type">> => <<"wamp_publish">>,
            <<"topic">> => <<"com.actions_api.topic">>
        },
        Extra
    ).

%% A key the parser does not declare is refused at every level, or a misspelt
%% setting would be dropped and its default applied in its place.
unknown_key_is_refused_at_every_level_test(_) ->
    Levels = [
        {host, []},
        {version, [<<"versions">>, <<"1.0.0">>]},
        {path, [<<"versions">>, <<"1.0.0">>, <<"paths">>, <<"/things">>]},
        {method, [
            <<"versions">>, <<"1.0.0">>, <<"paths">>, <<"/things">>, <<"post">>
        ]},
        {response, [
            <<"versions">>,
            <<"1.0.0">>,
            <<"paths">>,
            <<"/things">>,
            <<"post">>,
            <<"response">>,
            <<"on_result">>
        ]}
    ],
    _ = [
        ?assertError(
            {unsupported_keys, Level, [<<"timout">>]},
            bondy_http_gateway_api_spec_parser:parse(
                with_key(
                    Path, <<"timout">>, 1, actions_spec(call_action(#{}), #{})
                )
            )
        )
     || {Level, Path} <- Levels
    ],
    ok.

info_is_free_form_test(_) ->
    VersionInfo = #{~"title" => ~"Things", ~"contact" => ~"ops@example.com"},
    MethodInfo = #{
        ~"description" => ~"Creates a thing",
        ~"parameters" => [
            #{~"name" => ~"id", ~"in" => ~"path"},
            #{~"name" => ~"q", ~"in" => ~"query"}
        ],
        ~"deprecated" => false
    },
    Version = [~"versions", ~"1.0.0"],
    Method = Version ++ [~"paths", ~"/things", ~"post"],
    Spec = with_key(
        Method,
        ~"info",
        MethodInfo,
        with_key(
            Version, ~"info", VersionInfo, actions_spec(call_action(#{}), #{})
        )
    ),
    Parsed = bondy_http_gateway_api_spec_parser:parse(Spec),
    ?assertEqual(
        VersionInfo, maps_utils:get_path(Version ++ [~"info"], Parsed)
    ),
    ?assertEqual(MethodInfo, maps_utils:get_path(Method ++ [~"info"], Parsed)).

%% A key the security scheme does not declare is refused. The gateway checks
%% no OAuth2 scope, so a `scopes` key would parse and never be enforced.
unknown_security_key_is_refused_test(_) ->
    OAuth2 = #{
        <<"type">> => <<"oauth2">>,
        <<"flow">> => <<"resource_owner_password_credentials">>,
        <<"token_path">> => <<"/oauth/token">>,
        <<"revoke_token_path">> => <<"/oauth/revoke">>,
        <<"schemes">> => [<<"http">>]
    },
    WithSecurity = fun(Security) ->
        #{<<"defaults">> := Defaults} =
            Spec = actions_spec(call_action(#{}), #{}),
        Spec#{<<"defaults">> := Defaults#{<<"security">> := Security}}
    end,
    ?assertMatch(
        #{<<"versions">> := #{}},
        bondy_http_gateway_api_spec_parser:parse(WithSecurity(OAuth2))
    ),
    ?assertError(
        {unsupported_keys, {security, <<"oauth2">>}, [<<"scopes">>]},
        bondy_http_gateway_api_spec_parser:parse(
            WithSecurity(OAuth2#{<<"scopes">> => [<<"admin">>]})
        )
    ).

%% A misspelt default is refused at every level that declares `defaults`,
%% or the setting it names would keep its built-in value.
unknown_defaults_key_is_refused_at_every_level_test(_) ->
    Version = [~"versions", ~"1.0.0"],
    Path = Version ++ [~"paths", ~"/things"],
    Spec = with_key(
        Path,
        ~"defaults",
        #{},
        with_key(
            Version, ~"defaults", #{}, actions_spec(call_action(#{}), #{})
        )
    ),
    ?assertMatch(
        #{~"versions" := #{}}, bondy_http_gateway_api_spec_parser:parse(Spec)
    ),
    _ = [
        ?assertError(
            {unsupported_keys, {defaults, Level}, [~"timout"]},
            bondy_http_gateway_api_spec_parser:parse(
                with_key(At ++ [~"defaults"], ~"timout", 1, Spec)
            )
        )
     || {Level, At} <- [{host, []}, {version, Version}, {path, Path}]
    ],
    ok.

%% An API that omits `defaults` gets every built-in default, as one that
%% declares it empty does.
absent_host_defaults_parse_as_empty_test(_) ->
    Empty = with_key([], ~"defaults", #{}, actions_spec(call_action(#{}), #{})),
    ?assertEqual(
        bondy_http_gateway_api_spec_parser:parse(Empty),
        bondy_http_gateway_api_spec_parser:parse(
            maps:remove(~"defaults", Empty)
        )
    ).

%% Every node serves this specification; one it failed to parse would be logged
%% and left unserved.
admin_api_spec_parses_test(_) ->
    File = filename:join(
        code:priv_dir(bondy_router), "specs/bondy_admin_api.json"
    ),
    {ok, Spec} = bondy_router_utils:json_consult(File),
    ?assertMatch(
        #{<<"versions">> := #{}},
        bondy_http_gateway_api_spec_parser:parse(Spec)
    ).

load_refuses_an_unknown_key_and_keeps_serving_test(_) ->
    Gateway = whereis(bondy_http_gateway),
    Spec = actions_spec(call_action(#{<<"retry_timeout">> => 2000}), #{}),
    ?assertEqual(
        {error,
            {unsupported_keys, {action, <<"wamp_call">>}, [<<"retry_timeout">>]}},
        bondy_http_gateway:load(Spec)
    ),
    ?assertEqual(Gateway, whereis(bondy_http_gateway)).

with_key([], Key, Value, Map) ->
    Map#{Key => Value};
with_key([H | T], Key, Value, Map) ->
    Map#{H := with_key(T, Key, Value, maps:get(H, Map))}.

%% Parses an API whose one path runs `Action`, and returns the parsed action.
parse_action(Action, Defaults) ->
    maps_utils:get_path(
        [
            <<"versions">>,
            <<"1.0.0">>,
            <<"paths">>,
            <<"/things">>,
            <<"post">>,
            <<"action">>
        ],
        bondy_http_gateway_api_spec_parser:parse(
            actions_spec(Action, Defaults)
        )
    ).

%% An API whose one path runs `Action`.
actions_spec(Action, Defaults) ->
    #{
        <<"id">> => <<"com.actions_api">>,
        <<"name">> => <<"com.actions_api">>,
        <<"host">> => <<"actions-api.com">>,
        <<"realm_uri">> => <<"com.actions_api">>,
        <<"defaults">> => Defaults#{
            <<"security">> => #{}, <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/v1.0">>,
                <<"paths">> => #{
                    <<"/things">> => #{
                        <<"post">> => #{
                            <<"action">> => Action,
                            <<"response">> => #{
                                <<"on_error">> => #{}, <<"on_result">> => #{}
                            }
                        }
                    }
                }
            }
        }
    }.

%% The response spec sets no `status_code`, and its body is the parser's
%% default, an empty binary.
call_error_without_a_status_keeps_the_error_status_test(_) ->
    Realm = <<"com.example.test.call_error_status">>,
    Api = <<"com.example.test.call_error_status.api">>,
    _ = bondy_realm:create(#{
        uri => Realm,
        authmethods => [<<"anonymous">>],
        security_enabled => false
    }),
    Get = #{
        <<"action">> => #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => <<"com.example.test.call_error_status.none">>
        },
        <<"response">> => #{<<"on_error">> => #{}, <<"on_result">> => #{}}
    },
    ok = bondy_http_gateway:load(#{
        <<"id">> => Api,
        <<"name">> => Api,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => Realm,
        <<"defaults">> => #{
            <<"security">> => #{}, <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/call_error_status/v1.0">>,
                <<"paths">> => #{<<"/none">> => #{<<"get">> => Get}}
            }
        }
    }),
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        ?assertEqual(
            bondy_http_utils:http_status(<<"wamp.error.no_such_procedure">>),
            http_status(
                get,
                <<"http://localhost:18080/call_error_status/v1.0/none">>,
                <<>>
            )
        )
    after
        bondy_http_gateway:delete(Api)
    end.

invalid_json_body_is_a_bad_request_test(_) ->
    Realm = <<"com.example.test.invalid_body">>,
    Api = <<"com.example.test.invalid_body.api">>,
    _ = bondy_realm:create(#{
        uri => Realm,
        authmethods => [<<"anonymous">>],
        security_enabled => false
    }),
    Post = #{
        <<"action">> => #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => <<"com.example.test.invalid_body.none">>
        },
        <<"response">> => #{<<"on_error">> => #{}, <<"on_result">> => #{}}
    },
    ok = bondy_http_gateway:load(#{
        <<"id">> => Api,
        <<"name">> => Api,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => Realm,
        <<"defaults">> => #{
            <<"security">> => #{}, <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/invalid_body/v1.0">>,
                <<"paths">> => #{<<"/none">> => #{<<"post">> => Post}}
            }
        }
    }),
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        ?assertEqual(
            400,
            http_status(
                post,
                <<"http://localhost:18080/invalid_body/v1.0/none">>,
                <<"{">>
            )
        )
    after
        bondy_http_gateway:delete(Api)
    end.

http_status(Method, Url, Body) ->
    http_status(Method, Url, [], Body).

http_status(Method, Url, Headers, Body) ->
    http_status(Method, Url, Headers, Body, 50).

%% Dispatch table rebuilds are debounced, so the route answers 404 until it is
%% mounted; a 404 never reaches the action.
http_status(_, _, _, _, 0) ->
    ct:fail(route_not_mounted);
http_status(Method, Url, Headers0, Body, N) ->
    Headers = [{<<"content-type">>, <<"application/json">>} | Headers0],
    {ok, Status, _, Ref} = hackney:request(Method, Url, Headers, Body, []),
    {ok, _} = hackney:body(Ref),
    case Status of
        404 ->
            timer:sleep(100),
            http_status(Method, Url, Headers0, Body, N - 1);
        _ ->
            Status
    end.

%% A route whose scheme the gateway does not enforce at runtime, `basic` or
%% `api_key`, refuses every request with 401, whatever credential it carries.
unenforced_schemes_answer_unauthorized_test(_) ->
    Realm = ~"com.example.test.unenforced_schemes",
    _ = bondy_realm:create(#{uri => Realm, security_enabled => true}),
    Schemes = [
        {~"basic", #{<<"type">> => <<"basic">>}},
        {~"api_key", #{
            <<"type">> => <<"api_key">>, <<"header_name">> => <<"x-api-key">>
        }}
    ],
    Statuses = [
        begin
            Api = <<"com.example.test.unenforced_schemes.", Name/binary>>,
            ok = bondy_http_gateway:load(#{
                <<"id">> => Api,
                <<"name">> => Api,
                <<"host">> => <<"_">>,
                <<"realm_uri">> => Realm,
                <<"defaults">> => #{
                    <<"security">> => Security,
                    <<"schemes">> => [<<"http">>]
                },
                <<"versions">> => #{
                    <<"1.0.0">> => #{
                        <<"base_path">> => <<"/", Name/binary, "_scheme/v1.0">>,
                        <<"paths">> => #{
                            <<"/thing">> => #{
                                <<"get">> => #{
                                    <<"action">> => call_action(#{}),
                                    <<"response">> => #{
                                        <<"on_error">> => #{},
                                        <<"on_result">> => #{}
                                    }
                                }
                            }
                        }
                    }
                }
            }),
            Url =
                <<"http://localhost:18080/", Name/binary,
                    "_scheme/v1.0/thing">>,
            try
                _ = bondy_http_gateway:rebuild_dispatch_tables(),
                {Name, http_status(get, Url, [], <<>>)}
            after
                bondy_http_gateway:delete(Api)
            end
        end
     || {Name, Security} <- Schemes
    ],
    ?assertEqual([{~"basic", 401}, {~"api_key", 401}], Statuses).

%% A ticket in the cookie of an `oidc` route needs `cookie` and its own
%% method. A ticket from `bondy.ticket.issue` is refused until a source allows
%% `ticket`. The two tickets name different users: a user's second ticket in a
%% realm replaces the first.
oidc_scheme_checks_a_wamp_ticket_cookie_under_ticket_test(_) ->
    Realm = ~"com.example.test.oidc_cookie_kind",
    Api = ~"com.example.test.oidc_cookie_kind.api",
    Proc = ~"com.example.test.oidc_cookie_kind.thing",
    User = ~"frank@example.com",
    OidcUser = ~"oidc-frank@example.com",
    _ = bondy_realm:create(#{
        uri => Realm,
        authmethods => [?COOKIE, ~"oidcrp", ~"ticket", ~"wampcra"],
        security_enabled => true,
        sources => [
            #{
                usernames => ~"all",
                authmethod => ?COOKIE,
                cidr => ~"127.0.0.0/8",
                meta => #{}
            }
        ],
        users => [#{username => User, password => ~"frank-secret"}],
        grants => [
            #{
                permissions => [~"bondy.issue", ~"wamp.call"],
                uri => ~"",
                match => ~"prefix",
                roles => ~"all"
            }
        ]
    }),
    {ok, _} = bondy_dealer:register(
        Proc, #{}, Realm, bondy_ref:new(internal, {?MODULE, on_call})
    ),
    ok = bondy_http_gateway:load(#{
        <<"id">> => Api,
        <<"name">> => Api,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => Realm,
        <<"defaults">> => #{
            <<"security">> => #{
                <<"type">> => <<"oidc">>, <<"provider">> => <<"idp">>
            },
            <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/oidc_cookie_kind/v1.0">>,
                <<"paths">> => #{
                    <<"/thing">> => #{
                        <<"get">> => #{
                            <<"action">> => #{
                                <<"type">> => <<"wamp_call">>,
                                <<"procedure">> => Proc
                            },
                            <<"response">> => #{
                                <<"on_error">> => #{},
                                <<"on_result">> => #{<<"status_code">> => 200}
                            }
                        }
                    }
                }
            }
        }
    }),
    {ok, OidcTicket, _} = bondy_oidc_ticket:issue(
        Realm, OidcUser, ~"idp", #{}, #{authroles => []}
    ),
    Session = bondy_session:new(Realm, #{
        peer => {{127, 0, 0, 1}, 0},
        authrealm => Realm,
        authid => User,
        authmethod => ~"wampcra",
        security_enabled => true,
        authroles => [],
        roles => #{caller => #{}}
    }),
    true = ets:insert(
        bondy_session:table(bondy_session:external_id(Session)), Session
    ),
    {ok, WampTicket, #{authmethod := ~"wampcra"}} = bondy_ticket:issue(
        Session, #{}
    ),
    Cookie = fun(Ticket) ->
        {<<"cookie">>,
            iolist_to_binary([
                bondy_http_utils:ticket_cookie_name(Realm), "=", Ticket
            ])}
    end,
    Url = <<"http://localhost:18080/oidc_cookie_kind/v1.0/thing">>,
    Statuses = fun() ->
        {
            http_status(get, Url, [Cookie(OidcTicket)], <<>>),
            http_status(get, Url, [Cookie(WampTicket)], <<>>)
        }
    end,
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        Before = Statuses(),
        {ok, _} = bondy_rbac_source:add(Realm, #{
            ~"usernames" => ~"all",
            ~"authmethod" => ~"ticket",
            ~"cidr" => ~"127.0.0.0/8",
            ~"meta" => #{}
        }),
        ?assertEqual({{200, 401}, {200, 200}}, {Before, Statuses()})
    after
        bondy_http_gateway:delete(Api)
    end.

%% An `oidc` route authenticates with the realm's OIDC ticket cookie, through
%% the realm's own rules: the `cookie` method must be allowed, the ticket must
%% be scoped to the realm, and a request that changes state must echo the CSRF
%% cookie in `x-csrf-token`. The subject has no local user, so its roles come
%% from the ticket, and the realm's `all` source admits it from loopback.
oidc_scheme_authenticates_with_the_realm_cookie_test(_) ->
    Realm = ~"com.example.test.oidc_scheme",
    Other = ~"com.example.test.oidc_scheme.other",
    Api = ~"com.example.test.oidc_scheme.api",
    Proc = ~"com.example.test.oidc_scheme.thing",
    Group = ~"oidc_readers",
    Methods = [?COOKIE, ~"oidcrp"],
    [
        _ = bondy_realm:create(#{
            uri => R,
            authmethods => Methods,
            security_enabled => true,
            sources => [
                #{
                    usernames => ~"all",
                    authmethod => ?COOKIE,
                    cidr => ~"127.0.0.0/8",
                    meta => #{}
                }
            ],
            groups => [#{name => Group}],
            grants => [
                #{
                    permissions => [~"wamp.call"],
                    uri => Proc,
                    match => ~"exact",
                    roles => [Group]
                }
            ]
        })
     || R <- [Realm, Other]
    ],
    {ok, _} = bondy_dealer:register(
        Proc, #{}, Realm, bondy_ref:new(internal, {?MODULE, on_call})
    ),
    Action = #{
        <<"action">> => #{
            <<"type">> => <<"wamp_call">>,
            <<"procedure">> => Proc
        },
        <<"response">> => #{
            <<"on_error">> => #{
                <<"status_code">> => <<"{{action.error.status_code}}">>,
                <<"body">> => <<"{{action.error.error_uri}}">>
            },
            <<"on_result">> => #{<<"status_code">> => 200}
        }
    },
    ok = bondy_http_gateway:load(#{
        <<"id">> => Api,
        <<"name">> => Api,
        <<"host">> => <<"_">>,
        <<"realm_uri">> => Realm,
        <<"defaults">> => #{
            <<"security">> => #{
                <<"type">> => <<"oidc">>, <<"provider">> => <<"idp">>
            },
            <<"schemes">> => [<<"http">>]
        },
        <<"versions">> => #{
            <<"1.0.0">> => #{
                <<"base_path">> => <<"/oidc_scheme/v1.0">>,
                <<"paths">> => #{
                    <<"/thing">> => #{<<"get">> => Action, <<"post">> => Action}
                }
            }
        }
    }),
    Url = <<"http://localhost:18080/oidc_scheme/v1.0/thing">>,
    Csrf = ~"csrf-token-value",
    Cookie = fun(TicketRealm) ->
        {ok, Ticket, _} = bondy_oidc_ticket:issue(
            TicketRealm, ~"alice@example.com", ~"idp", #{}, #{
                authroles => [Group]
            }
        ),
        {<<"cookie">>,
            iolist_to_binary([
                bondy_http_utils:ticket_cookie_name(Realm),
                "=",
                Ticket,
                "; ",
                bondy_http_utils:csrf_cookie_name(Realm),
                "=",
                Csrf
            ])}
    end,
    CsrfHeader = {<<"x-csrf-token">>, Csrf},
    try
        _ = bondy_http_gateway:rebuild_dispatch_tables(),
        ?assertEqual(401, http_status(get, Url, [], <<>>)),
        ?assertEqual(200, http_status(get, Url, [Cookie(Realm)], <<>>)),
        ?assertEqual(
            403, http_status(post, Url, [Cookie(Realm)], <<"{}">>)
        ),
        ?assertEqual(
            204,
            http_status(post, Url, [Cookie(Realm), CsrfHeader], <<"{}">>)
        ),
        ?assertEqual(401, http_status(get, Url, [Cookie(Other)], <<>>)),
        _ = bondy_realm:update(Realm, #{~"authmethods" => [~"oidcrp"]}),
        ?assertEqual(401, http_status(get, Url, [Cookie(Realm)], <<>>))
    after
        bondy_http_gateway:delete(Api)
    end.

%% The dealer applies an internal callee to the call's arguments, so it answers
%% at each arity the gateway's calls produce.
on_call() ->
    {ok, #{}, [], #{}}.

on_call(_) ->
    on_call().

on_call(_, _) ->
    on_call().
