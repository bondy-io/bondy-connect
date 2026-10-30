%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_details_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_wamp.hrl").

progressive_call_invocations_test_() ->
    {setup,
        fun() ->
            _ = application:ensure_all_started(bondy_wamp),
            ok
        end,
        fun(_) -> ok end, [
            {"progressive_call_invocations does not need call_canceling",
                fun without_call_canceling/0},
            {"a HELLO needs at least one role", fun no_roles/0},
            {"CALL.Options.progress is a valid option",
                fun call_progress_option/0}
        ]}.

%% The WAMP specification requires a callee without `call_canceling` to be
%% treated as not supporting the feature, so HELLO is accepted either way and
%% the dealer decides per call.
without_call_canceling() ->
    lists:foreach(
        fun(Role) ->
            Details = hello(Role, #{progressive_call_invocations => true}),
            ?assertMatch(
                #{
                    roles := #{
                        Role := #{
                            features := #{
                                progressive_call_invocations := true
                            }
                        }
                    }
                },
                bondy_wamp_details:new(hello, Details)
            )
        end,
        [caller, callee]
    ).

no_roles() ->
    ?assertError(
        {validation_failed, #{type := missing_required_value}},
        bondy_wamp_details:new(hello, #{roles => #{}})
    ).

%% The new CALL.Options.progress marker (a progressive-call chunk) validates and
%% is carried through, rather than being stripped as an unknown option.
call_progress_option() ->
    M = bondy_wamp_message:call(1, #{progress => true}, <<"com.example.p">>),
    ?assertEqual(true, maps:get(progress, M#call.options)).

%% @private
hello(Role, Features) ->
    #{roles => #{Role => #{features => Features}}}.
