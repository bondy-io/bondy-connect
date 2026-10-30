%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

%% Falsifiers for the explicit trace-context surface: `attach/2` / `extract/1`
%% are inverses over the wire keys, for a full and a traceparent-only context;
%% `tracestate` and `baggage` are never surfaced without a `traceparent` (the
%% W3C rule), and never invented; `attach(Opts, undefined)` is exactly `Opts`,
%% and attach never disturbs unrelated option keys; `ensure_wamp_extensions/0`
%% sets the `wamp` environment to the constants `bondy_config` also sets in a
%% router node, which declare the trace keys, and a second run changes nothing.
-module(bondy_connect_trace_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

-define(TP, <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>).
-define(TS, <<"congo=t61rcWkgMzE">>).
-define(BG, <<"userId=alice,serverNode=DF%2028">>).

-define(EXT_PATHS, [
    [extended_options, call],
    [extended_options, publish],
    [extended_details, invocation],
    [extended_details, event]
]).

attach_extract_round_trip_test() ->
    Full = #{traceparent => ?TP, tracestate => ?TS, baggage => ?BG},
    ?assertEqual(
        Full, bondy_connect_trace:extract(bondy_connect_trace:attach(#{}, Full))
    ),
    Min = #{traceparent => ?TP},
    ?assertEqual(
        Min, bondy_connect_trace:extract(bondy_connect_trace:attach(#{}, Min))
    ).

attach_test() ->
    ?assertEqual(#{}, bondy_connect_trace:attach(#{}, undefined)),
    Opts = #{timeout => 5000},
    ?assertEqual(Opts, bondy_connect_trace:attach(Opts, undefined)),
    ?assertEqual(
        #{timeout => 5000, '_traceparent' => ?TP},
        bondy_connect_trace:attach(Opts, #{traceparent => ?TP})
    ),
    %% A partial context attaches only its own keys.
    Attached = bondy_connect_trace:attach(#{}, #{
        traceparent => ?TP, baggage => ?BG
    }),
    ?assertEqual(#{'_traceparent' => ?TP, '_baggage' => ?BG}, Attached).

extract_test() ->
    ?assertEqual(undefined, bondy_connect_trace:extract(#{})),
    ?assertEqual(
        undefined, bondy_connect_trace:extract(#{procedure => <<"com.x.y">>})
    ),
    %% The W3C rule: tracestate/baggage without a traceparent are not a
    %% context.
    ?assertEqual(
        undefined,
        bondy_connect_trace:extract(#{'_tracestate' => ?TS, '_baggage' => ?BG})
    ),
    ?assertEqual(
        #{traceparent => ?TP, baggage => ?BG},
        bondy_connect_trace:extract(#{
            '_traceparent' => ?TP,
            '_baggage' => ?BG,
            procedure => <<"com.x.y">>
        })
    ).

ensure_wamp_extensions_test() ->
    ok = bondy_wamp_config:init(),
    Keys = [extended_options, extended_details],
    Saved = [{K, bondy_wamp_config:get(K, [])} || K <- Keys],
    try
        _ = [ok = bondy_wamp_config:set(K, []) || K <- Keys],
        ok = bondy_connect_config:ensure_wamp_extensions(),
        ?assertEqual(
            ?WAMP_EXT_OPTIONS, bondy_wamp_config:get(extended_options)
        ),
        ?assertEqual(
            ?WAMP_EXT_DETAILS, bondy_wamp_config:get(extended_details)
        ),
        ?assert(
            lists:member(
                '_deadline', bondy_wamp_config:get([extended_options, call])
            )
        ),
        ok = lists:foreach(
            fun(P) ->
                Declared = bondy_wamp_config:get(P),
                lists:foreach(
                    fun(K) -> ?assert(lists:member(K, Declared)) end,
                    ['_traceparent', '_tracestate', '_baggage']
                )
            end,
            ?EXT_PATHS
        ),
        Before = [bondy_wamp_config:get(K) || K <- Keys],
        ok = bondy_connect_config:ensure_wamp_extensions(),
        ?assertEqual(Before, [bondy_wamp_config:get(K) || K <- Keys])
    after
        lists:foreach(
            fun({K, V}) -> bondy_wamp_config:set(K, V) end, Saved
        )
    end.
