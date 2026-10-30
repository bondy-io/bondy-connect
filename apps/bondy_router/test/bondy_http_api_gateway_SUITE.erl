%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_api_gateway_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
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
    http_status(Method, Url, Body, 50).

%% Dispatch table rebuilds are debounced, so the route answers 404 until it is
%% mounted; a 404 never reaches the action.
http_status(_, _, _, 0) ->
    ct:fail(route_not_mounted);
http_status(Method, Url, Body, N) ->
    Headers = [{<<"content-type">>, <<"application/json">>}],
    {ok, Status, _, Ref} = hackney:request(Method, Url, Headers, Body, []),
    {ok, _} = hackney:body(Ref),
    case Status of
        404 ->
            timer:sleep(100),
            http_status(Method, Url, Body, N - 1);
        _ ->
            Status
    end.
