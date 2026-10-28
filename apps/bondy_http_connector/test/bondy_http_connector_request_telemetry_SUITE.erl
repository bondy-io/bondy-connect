%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_connector_request_telemetry_SUITE).

-moduledoc """
End-to-end tests for `bondy_http_connector_callee_handler:handle_wamp_call/3`
— the real WAMP-to-HTTP request/retry orchestration. The other suites either
test its pure helpers in isolation, per
`bondy_http_connector_callee_handler_SUITE`, or need a full Bondy
dealer/session boot to reach it, per
`bondy_http_connector_callee_lifecycle_SUITE`, which never issues a call.

Drives a real `bondy_http_connector_http_pool` against
`mock_auth_http_server` and asserts on the resulting
`bondy_http_connector_requests_total`, `..._request_duration_milliseconds`,
`..._retries_total` and `..._token_cache_total` metric values — the request
and retry orchestration's own telemetry. Uses `bondy_http_connector_mock_auth`
as the auth module so
these tests isolate the request/retry path from token-fetch/auth
concerns (already covered by `bondy_http_connector_auth_integration_SUITE`
and the token-cache suites).
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include("bondy_http_connector.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    successful_get_request_emits_ok_metrics/1,
    client_error_response_classified_correctly/1,
    retries_exhausted_emits_retries_total_and_bad_gateway/1,
    retry_attempt_numbers_are_correct_for_non_default_retries/1,
    pending_credentials_are_unavailable/1,
    a_failed_token_fetch_is_unavailable/1,
    a_handler_fault_raises/1,
    a_slow_upstream_is_a_gateway_timeout/1,
    a_timed_out_request_is_not_retried/1,
    retries_stop_at_the_procedure_timeout/1,
    a_down_pool_is_unavailable/1
]).

all() ->
    [
        successful_get_request_emits_ok_metrics,
        client_error_response_classified_correctly,
        retries_exhausted_emits_retries_total_and_bad_gateway,
        retry_attempt_numbers_are_correct_for_non_default_retries,
        pending_credentials_are_unavailable,
        a_failed_token_fetch_is_unavailable,
        a_handler_fault_raises,
        a_slow_upstream_is_a_gateway_timeout,
        a_timed_out_request_is_not_retried,
        retries_stop_at_the_procedure_timeout,
        a_down_pool_is_unavailable
    ].

%% ===================================================================
%% CT callbacks
%% ===================================================================

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(telemetry),
    %% `alarm_handler` (the registered gen_event manager) is started by
    %% `sasl`, not `kernel` — a bare CT run doesn't have it running
    %% otherwise, and the pool's `mark_up/1` unconditionally calls
    %% `alarm_handler:clear_alarm/1`.
    {ok, _} = application:ensure_all_started(sasl),
    %% start_link/0 links to the calling process — init_per_suite's process
    %% is transient (CT tears it down once this function returns), which
    %% would take bondy_metrics' ETS tables down with it. Unlink so the
    %% registry outlives init_per_suite for the rest of the suite.
    MetricsPid =
        case bondy_metrics:start_link() of
            {ok, Pid} -> Pid;
            {error, {already_started, Pid}} -> Pid
        end,
    true = unlink(MetricsPid),
    ok = bondy_http_connector_telemetry:init(),
    {ok, Port} = mock_auth_http_server:start(),
    BaseUrl = mock_auth_http_server:base_url(),
    [{port, Port}, {base_url, BaseUrl} | Config].

end_per_suite(_Config) ->
    mock_auth_http_server:stop(),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?config(port, Config),
    try ranch:get_port(mock_auth_http_listener) of
        Port -> ok;
        _ -> {ok, _} = mock_auth_http_server:start(#{port => Port})
    catch
        _:_ -> {ok, _} = mock_auth_http_server:start(#{port => Port})
    end,
    mock_auth_http_server:reset(),
    bondy_http_connector_mock_auth:reset_call_count(),
    bondy_http_connector_mock_auth:set_token(<<"test-token">>),

    {ok, CacheSup} = bondy_http_connector_token_cache_sup:start_link(),
    unlink(CacheSup),
    {ok, CacheReg} = bondy_http_connector_token_cache:start_link(),
    unlink(CacheReg),

    ServiceName = atom_to_binary(TC, utf8),
    PoolName = binary_to_atom(<<"pool_", ServiceName/binary>>),
    BaseUrl = ?config(base_url, Config),
    {ok, PoolPid} = bondy_http_connector_http_pool:start_link(
        PoolName, BaseUrl, #{service_name => ServiceName}
    ),
    wait_until(
        fun() -> bondy_http_connector_http_pool:status(PoolName) =:= up end, 40
    ),

    [
        {service_name, ServiceName},
        {pool_name, PoolName},
        {pool_pid, PoolPid},
        {cache_sup, CacheSup},
        {cache_reg, CacheReg}
        | Config
    ].

end_per_testcase(_TC, Config) ->
    PoolPid = ?config(pool_pid, Config),
    try
        gen_server:stop(PoolPid)
    catch
        _:_ -> ok
    end,
    CacheReg = ?config(cache_reg, Config),
    CacheSup = ?config(cache_sup, Config),
    try
        exit(CacheReg, shutdown)
    catch
        _:_ -> ok
    end,
    try
        exit(CacheSup, shutdown)
    catch
        _:_ -> ok
    end,
    timer:sleep(50),
    lists:foreach(
        fun(Key) ->
            try
                persistent_term:erase(Key)
            catch
                _:_ -> ok
            end
        end,
        [
            {bondy_http_connector_mock_auth, result},
            {bondy_http_connector_mock_auth, fetch_fun},
            {bondy_http_connector_mock_auth, call_count}
        ]
    ),
    ok.

%% ===================================================================
%% Errors the connector raises itself
%% ===================================================================

%% A gateway `wamp_call` answers with the status the error URI maps to
%% (`bondy_http_api_gateway_SUITE:call_error_without_a_status_keeps_the_error_status_test`),
%% so these conditions must not name the upstream.
pending_credentials_are_unavailable(Config) ->
    ServiceName = ?config(service_name, Config),
    Tab = ets:new(bondy_http_connector_manager, [named_table, set]),
    true = ets:insert(Tab, {ServiceName, not_ready}),
    try
        ProcConf = base_proc_conf(Config, <<"com.example.pending">>),
        ?assertMatch(
            {error, <<"bondy.error.unavailable">>, _, _, #{
                <<"status">> := 503
            }},
            bondy_http_connector_callee_handler:handle_wamp_call(
                ProcConf#http_connector_proc_conf{vars_resolved = false},
                #{},
                #{}
            )
        )
    after
        ets:delete(Tab)
    end.

a_failed_token_fetch_is_unavailable(Config) ->
    bondy_http_connector_mock_auth:set_error(token_endpoint_down),
    ?assertMatch(
        {error, <<"bondy.error.unavailable">>, _, _, #{<<"status">> := 503}},
        bondy_http_connector_callee_handler:handle_wamp_call(
            base_proc_conf(Config, <<"com.example.no_token">>), #{}, #{}
        )
    ).

%% A fault raises out of the handler, and the dealer answers the caller with
%% `internal_error`
%% (`bondy_registry_SUITE:local_call_to_a_crashing_callback_is_answered`).
a_handler_fault_raises(Config) ->
    ProcConf = base_proc_conf(Config, <<"com.example.fault">>),
    ?assertError(
        function_clause,
        bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf#http_connector_proc_conf{method = trace}, #{}, #{}
        )
    ).

%% An upstream that answers after the procedure's timeout did not fail: it was
%% too slow, which HTTP reports as 504 (RFC 9110 15.6.5), not 502.
a_slow_upstream_is_a_gateway_timeout(Config) ->
    mock_auth_http_server:set_latency(upstream, 1000),
    ProcConf = base_proc_conf(Config, <<"com.example.slow">>),
    ?assertMatch(
        {error, ~"bondy.error.gateway_timeout", #{}, [], #{~"status" := 504}},
        bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf#http_connector_proc_conf{timeout = 100, retries = 0},
            #{},
            #{}
        )
    ).

a_timed_out_request_is_not_retried(Config) ->
    mock_auth_http_server:set_latency(upstream, 2000),
    ServiceName = ?config(service_name, Config),
    ProcUri = ~"com.example.slow",
    ProcConf = (base_proc_conf(Config, ProcUri))#http_connector_proc_conf{
        timeout = 200, retries = 3
    },
    Start = erlang:monotonic_time(millisecond),
    ?assertMatch(
        {error, ~"bondy.error.gateway_timeout", #{}, [], #{~"status" := 504}},
        bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf, #{}, #{}
        )
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(Elapsed < 400, {elapsed, Elapsed}),
    ?assertEqual(0, retries_total(ServiceName, ProcUri)).

retries_stop_at_the_procedure_timeout(Config) ->
    ServiceName = ?config(service_name, Config),
    ProcUri = ServiceName,
    ProcConf = (base_proc_conf(Config, ProcUri))#http_connector_proc_conf{
        base_url = ~"http://localhost:1", timeout = 100, retries = 20
    },
    Start = erlang:monotonic_time(millisecond),
    ?assertMatch(
        {error, ~"bondy.error.bad_gateway", #{}, [], #{~"status" := 502}},
        bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf, #{}, #{}
        )
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(Elapsed < 200, {elapsed, Elapsed}),
    ?assert(retries_total(ServiceName, ProcUri) < 20).

a_down_pool_is_unavailable(Config) ->
    ok = bondy_http_connector_http_pool:mark_down(?config(pool_name, Config)),
    ProcConf = base_proc_conf(Config, ~"com.example.down"),
    ?assertMatch(
        {error, ~"wamp.error.unavailable", #{}, [], #{~"status" := 503}},
        bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf, #{}, #{}
        )
    ).

%% ===================================================================
%% Helpers
%% ===================================================================

collect_attempts(Ref, N, Timeout) ->
    lists:sort([
        receive
            {Ref, Attempt} -> Attempt
        after Timeout -> ct:fail(missing_retry_event)
        end
     || _ <- lists:seq(1, N)
    ]).

wait_until(Fun, Retries) when Retries > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Retries - 1)
    end;
wait_until(Fun, 0) ->
    ?assert(Fun()).

base_proc_conf(Config, ProcUri) ->
    ServiceName = ?config(service_name, Config),
    PoolName = ?config(pool_name, Config),
    BaseUrl = ?config(base_url, Config),
    #http_connector_proc_conf{
        service_name = ServiceName,
        base_url = BaseUrl,
        auth_mod = bondy_http_connector_mock_auth,
        auth_conf = #{},
        timeout = 5000,
        retries = ?DEFAULT_RETRIES,
        pool = PoolName,
        method = get,
        path = <<"/api/echo">>,
        path_vars = [],
        uri = ProcUri,
        realm = <<"com.example.test">>,
        vars_resolved = true
    }.

metric_or_zero(Name, Label) ->
    case bondy_metrics:value(#{name => Name, label => Label}) of
        undefined -> 0;
        N -> N
    end.

requests_total(Service, ProcUri, Outcome) ->
    metric_or_zero(bondy_http_connector_requests_total, #{
        service => Service, procedure_uri => ProcUri, outcome => Outcome
    }).

request_duration_count(Service, ProcUri) ->
    metric_or_zero(bondy_http_connector_request_duration_milliseconds, #{
        service => Service, procedure_uri => ProcUri
    }).

retries_total(Service, ProcUri) ->
    metric_or_zero(bondy_http_connector_retries_total, #{
        service => Service, procedure_uri => ProcUri
    }).

token_cache_total(Service, Result) ->
    metric_or_zero(bondy_http_connector_token_cache_total, #{
        service => Service, result => Result
    }).

%% ===================================================================
%% Tests
%% ===================================================================

successful_get_request_emits_ok_metrics(Config) ->
    ServiceName = ?config(service_name, Config),
    ProcUri = ServiceName,
    ProcConf = base_proc_conf(Config, ProcUri),

    Result1 = bondy_http_connector_callee_handler:handle_wamp_call(
        ProcConf, #{}, #{}
    ),
    ?assertMatch({ok, #{}, [], #{<<"status">> := 200}}, Result1),

    %% Second call for the same service/procedure: the token is now cached
    %% (a hit), the request itself is independent per-call.
    Result2 = bondy_http_connector_callee_handler:handle_wamp_call(
        ProcConf, #{}, #{}
    ),
    ?assertMatch({ok, #{}, [], #{<<"status">> := 200}}, Result2),

    ?assertEqual(2, requests_total(ServiceName, ProcUri, ok)),
    ?assert(request_duration_count(ServiceName, ProcUri) >= 2),
    ?assertEqual(1, token_cache_total(ServiceName, miss)),
    ?assertEqual(1, token_cache_total(ServiceName, hit)).

client_error_response_classified_correctly(Config) ->
    ServiceName = ?config(service_name, Config),
    ProcUri = ServiceName,
    mock_auth_http_server:set_upstream_response(
        404, iolist_to_binary(json:encode(#{<<"error">> => <<"nope">>}))
    ),
    ProcConf = base_proc_conf(Config, ProcUri),

    Result = bondy_http_connector_callee_handler:handle_wamp_call(
        ProcConf, #{}, #{}
    ),
    ?assertMatch(
        {error, ~"bondy.error.not_found", #{}, [], #{<<"status">> := 404}},
        Result
    ),
    ?assertEqual(1, requests_total(ServiceName, ProcUri, client_error)).

retries_exhausted_emits_retries_total_and_bad_gateway(Config) ->
    ServiceName = ?config(service_name, Config),
    ProcUri = ServiceName,
    %% The pool itself was started (and is `up`) against the real mock
    %% server -- but the URL used for THIS call is per-call, constructed
    %% from ProcConf.base_url, independently of the pool's own endpoint
    %% (the pool's Name only selects hackney's connection pool, it does
    %% not pin the destination host). Pointing it at an unreachable port
    %% makes every attempt fail deterministically with a fast
    %% `econnrefused`, without needing to touch the pool's own liveness
    %% state.
    ProcConf = (base_proc_conf(Config, ProcUri))#http_connector_proc_conf{
        base_url = <<"http://localhost:1">>
    },

    Result = bondy_http_connector_callee_handler:handle_wamp_call(
        ProcConf, #{}, #{}
    ),
    ?assertMatch(
        {error, ~"bondy.error.bad_gateway", #{}, [], #{<<"status">> := 502}},
        Result
    ),
    %% retries = ?DEFAULT_RETRIES(3): 3 retry attempts fire (the 4th and
    %% final attempt, at RetriesLeft=0, gives up without another retry
    %% telemetry event).
    ?assertEqual(?DEFAULT_RETRIES, retries_total(ServiceName, ProcUri)),
    ?assertEqual(1, requests_total(ServiceName, ProcUri, server_error)).

retry_attempt_numbers_are_correct_for_non_default_retries(Config) ->
    %% `retries_total` alone (used above) can't catch a mislabelled
    %% `attempt` — it isn't part of the metric's label set, only its
    %% event metadata — so this attaches directly to the telemetry event
    %% to observe the reported sequence. With a `retries` value other
    %% than the module's `?DEFAULT_RETRIES`, a formula anchored on the
    %% wrong constant reports the wrong attempt number on every retry.
    ServiceName = ?config(service_name, Config),
    ProcUri = ServiceName,
    ProcConf = (base_proc_conf(Config, ProcUri))#http_connector_proc_conf{
        base_url = <<"http://localhost:1">>,
        retries = 2
    },

    Self = self(),
    Ref = make_ref(),
    HandlerId = {?MODULE, Ref},
    telemetry:attach(
        HandlerId,
        [bondy, http_connector, retry],
        fun(_, _, Meta, _) -> Self ! {Ref, maps:get(attempt, Meta)} end,
        []
    ),
    try
        Result = bondy_http_connector_callee_handler:handle_wamp_call(
            ProcConf, #{}, #{}
        ),
        ?assertMatch(
            {error, ~"bondy.error.bad_gateway", #{}, [], #{<<"status">> := 502}},
            Result
        ),
        ?assertEqual([1, 2], collect_attempts(Ref, 2, 2000))
    after
        telemetry:detach(HandlerId)
    end.
