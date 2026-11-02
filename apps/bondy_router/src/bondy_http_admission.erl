%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_admission).
-moduledoc """
Cowboy middleware that charges a request to its route's rate-limit class
before the handler runs.

A route opts in by naming a class under `rate_limit_class` in its handler
options; its `realm_uri`, when present, adds the realm scope. Routes that name
no class are not charged here. A throttled request is answered `429` with a
`retry-after` of one second, the class's refill granularity, and never
reaches the handler.

A charged route's `route` option, its path template, becomes the `route`
label of its HTTP metrics. The middleware sets it before charging, so a
throttled request carries it too (`bondy_admin_listener_SUITE:
throttled_requests_keep_their_route_label`). The label is the template because
raw paths are unbounded.

The charge precedes authentication, so requests that authentication refuses
spend the budget too (`bondy_admin_listener_SUITE:
refused_requests_draw_from_the_budget`). A `cowboy_rest` `rate_limited`
callback cannot do this: `cowboy_rest` calls it after `is_authorized`.
""".

-behaviour(cowboy_middleware).

-export([execute/2]).

-doc """
Charges the request to the class its route names, if any, and sets its
`route` metrics label.
""".
-spec execute(Req, Env) -> {ok, Req, Env} | {stop, Req} when
    Req :: cowboy_req:req(), Env :: cowboy_middleware:env().

execute(Req, #{handler_opts := #{rate_limit_class := Class} = Opts} = Env) ->
    ok = label_route(Opts, Req),
    Dims = #{realm => maps:get(realm_uri, Opts, undefined)},
    case bondy_http_utils:throttle(Class, Req, Dims) of
        ok ->
            {ok, Req, Env};
        throttled ->
            {stop, cowboy_req:reply(429, #{~"retry-after" => ~"1"}, Req)}
    end;
execute(Req, #{handler_opts := _} = Env) ->
    {ok, Req, Env}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

label_route(#{route := Route}, Req) ->
    cowboy_req:cast(
        {set_options, #{metrics_user_data => #{route => Route}}}, Req
    );
label_route(#{}, _Req) ->
    ok.
