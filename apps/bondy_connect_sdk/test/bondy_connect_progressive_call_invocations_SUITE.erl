%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_progressive_call_invocations_SUITE).

-moduledoc """
Conformance of Bondy and the SDK to the WAMP Progressive Call Invocations
specification (`rfc/text/advanced/rpc_progressive_call_invocations.md` in
wamp-proto).

A case that needs a peer the SDK will not impersonate, such as a caller that
never announced the feature, drives the router through the SDK's raw-socket
transport with hand-built messages.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, ~"com.example.bondy_connect.progressive_call_invocations").
-define(HOST, "127.0.0.1").
-define(PORT, 18082).

all() ->
    [
        the_dealer_announces_the_feature,
        a_caller_without_call_canceling_streams,
        a_callee_without_call_canceling_lacks_the_feature,
        a_callee_without_the_feature_lacks_it,
        a_reserved_procedure_lacks_the_feature,
        a_caller_without_the_feature_is_aborted,
        a_caller_without_the_feature_is_aborted_on_a_reserved_procedure,
        a_dealer_without_the_feature_aborts_a_progressive_call,
        call_stream_refuses_a_dealer_without_the_feature,
        a_request_id_gap_aborts_the_session,
        requests_of_every_type_share_the_sequence,
        a_reused_request_id_of_a_live_call_aborts_the_session,
        a_reused_request_id_on_another_procedure_is_discarded,
        a_continuation_of_a_completed_call_is_discarded,
        a_caller_without_the_feature_is_not_sequenced,
        a_callee_leaving_mid_stream_cancels_the_call,
        a_continuation_for_another_procedure_is_discarded,
        a_stream_is_authorized_once,
        a_continuation_cannot_change_the_details,
        no_chunk_follows_the_final_chunk,
        a_chunk_after_the_final_chunk_is_discarded,
        a_chunk_the_transport_refuses_is_reported,
        a_chunk_after_the_callee_replied_is_discarded,
        a_handler_streams_both_ways,
        a_local_caller_routes_nothing_after_an_abort
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    _ = bondy_realm:create(#{
        uri => ?REALM,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [~"wamp.register", ~"wamp.publish"],
                uri => ~"",
                match => ~"prefix",
                roles => [~"anonymous"]
            },
            call_grant()
        ],
        sources => [
            #{
                usernames => [~"anonymous"],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => ~"0.0.0.0/0"
            }
        ]
    }),
    Feature = [wamp, dealer, features, progressive_call_invocations],
    Observed = bondy_config:get(Feature, false),
    ok = bondy_config:set(Feature, true),
    [{observed_feature, Observed} | Config].

end_per_suite(Config) ->
    bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations],
        ?config(observed_feature, Config)
    ).

init_per_testcase(a_handler_streams_both_ways, Config) ->
    Feature = [wamp, dealer, features, progressive_call_results],
    Observed = bondy_config:get(Feature, false),
    ok = bondy_config:set(Feature, true),
    [{observed_results, Observed} | Config];
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(Case, _) when
    Case =:= a_dealer_without_the_feature_aborts_a_progressive_call;
    Case =:= call_stream_refuses_a_dealer_without_the_feature
->
    bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations], true
    );
end_per_testcase(a_handler_streams_both_ways, Config) ->
    bondy_config:set(
        [wamp, dealer, features, progressive_call_results],
        ?config(observed_results, Config)
    );
end_per_testcase(a_stream_is_authorized_once, _) ->
    bondy_rbac:grant(?REALM, call_grant());
end_per_testcase(_, _) ->
    ok.

%% =============================================================================
%% TESTS
%% =============================================================================

-doc """
The dealer announces the feature in WELCOME under the specification's key.
""".
the_dealer_announces_the_feature(_) ->
    {#welcome{details = Details}, T} = open(#{caller => #{features => #{}}}),
    #{roles := #{dealer := #{features := Features}}} = Details,
    ?assertMatch(#{progressive_call_invocations := true}, Features),
    ok = bondy_connect_transport_tcp:close(T).

-doc """
A caller needs no `call_canceling` to stream: the specification requires it of
a callee only.
""".
a_caller_without_call_canceling_streams(_) ->
    Proc = ~"com.example.pci.caller_without_canceling",
    Callee = connect(),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun sum_input/3),

    {#welcome{}, T0} = open(#{
        caller => #{features => #{progressive_call_invocations => true}}
    }),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    T2 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [2]), T1),
    T3 = send(bondy_wamp_message:call(1, #{}, Proc, [3]), T2),
    {Result, T4} = recv(T3),
    ?assertMatch(#result{request_id = 1, args = [6]}, Result),

    ok = bondy_connect_transport_tcp:close(T4),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A callee that announces the feature without `call_canceling` is treated as
not supporting it: the caller gets `wamp.error.feature_not_supported` and the
handler never runs.
""".
a_callee_without_call_canceling_lacks_the_feature(_) ->
    assert_unsupported_callee(
        ~"com.example.pci.callee_without_canceling",
        #{progressive_call_invocations => true}
    ).

-doc """
A callee that does not announce the feature gets no progressive call: the
caller gets `wamp.error.feature_not_supported` and the handler never runs.
""".
a_callee_without_the_feature_lacks_it(_) ->
    assert_unsupported_callee(
        ~"com.example.pci.callee_without_feature",
        #{call_canceling => true}
    ).

-doc """
Bondy serves the reserved namespaces itself and reads no progressive input
there, so a progressive call to one gets `wamp.error.feature_not_supported`.
""".
a_reserved_procedure_lacks_the_feature(_) ->
    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(
        Caller, ?WAMP_REG_LIST, [], #{}, #{}
    ),
    ?assertMatch(
        {error, #{uri := ?WAMP_FEATURE_NOT_SUPPORTED}}, next_reply(Token)
    ),
    ok = bondy_connect_client:disconnect(Caller).

-doc """
A progressive CALL from a caller that did not announce the feature aborts the
session with `wamp.error.protocol_violation`. The session process stops at that
CALL, so the plain CALL sent after it is never routed.
""".
a_caller_without_the_feature_is_aborted(_) ->
    Proc = ~"com.example.pci.caller_without_feature",
    TestPid = self(),
    Callee = connect(),
    Handler = fun(_, _, _) ->
        TestPid ! handler_ran,
        {ok, #{args => []}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Proc, Handler),

    {#welcome{}, T0} = open(#{caller => #{features => #{}}}),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    T2 = send(bondy_wamp_message:call(2, #{}, Proc, [2]), T1),
    ok = assert_aborted(T2),
    receive
        handler_ran -> ct:fail(handler_ran)
    after 300 -> ok
    end,

    ok = bondy_connect_client:disconnect(Callee).

-doc """
The caller check precedes the reserved-namespace dispatch, which otherwise
runs on the router worker pool where the session cannot be aborted.
""".
a_caller_without_the_feature_is_aborted_on_a_reserved_procedure(_) ->
    {#welcome{}, T0} = open(#{caller => #{features => #{}}}),
    T1 = send(
        bondy_wamp_message:call(1, #{progress => true}, ?WAMP_REG_LIST), T0
    ),
    ok = assert_aborted(T1).

-doc """
A dealer that does not announce the feature aborts a progressive CALL even
from a caller that announced it.
""".
a_dealer_without_the_feature_aborts_a_progressive_call(_) ->
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations], false
    ),
    Proc = ~"com.example.pci.dealer_without_feature",
    Callee = connect(),
    {ok, _} = bondy_connect_client:register(Callee, Proc, fun sum_input/3),

    {#welcome{details = Details}, T0} = open(#{
        caller => #{features => #{progressive_call_invocations => true}}
    }),
    #{roles := #{dealer := #{features := Features}}} = Details,
    ?assertMatch(#{progressive_call_invocations := false}, Features),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    ok = assert_aborted(T1),

    ok = bondy_connect_client:disconnect(Callee).

-doc """
An SDK caller connected to a dealer that does not announce the feature gets
`feature_not_supported` from `call_stream/5` instead of a CALL the dealer would
answer with ABORT. A plain call on the same connection then succeeds.
""".
call_stream_refuses_a_dealer_without_the_feature(_) ->
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations], false
    ),
    Proc = ~"com.example.pci.sdk_dealer_without_feature",
    Callee = serve(Proc, fun reply_empty/3),
    Caller = connect(),
    ?assertEqual(
        {error, #{kind => client, reason => feature_not_supported}},
        bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{})
    ),
    ?assertMatch({ok, _}, bondy_connect_client:call(Caller, Proc)),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A CALL whose request id skips ahead of the session's sequence aborts the
session.
""".
a_request_id_gap_aborts_the_session(_) ->
    Proc = ~"com.example.pci.gap",
    Callee = serve(Proc, fun reply_empty/3),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(2, #{}, Proc), T0),
    ok = assert_aborted(T1),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
PUBLISH draws from the same request id sequence as CALL, so a CALL that follows
a PUBLISH is no gap.
""".
requests_of_every_type_share_the_sequence(_) ->
    Proc = ~"com.example.pci.shared_sequence",
    Callee = serve(Proc, fun reply_empty/3),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:publish(1, #{}, ~"com.example.pci.topic"), T0),
    T2 = send(bondy_wamp_message:call(2, #{}, Proc), T1),
    {Result, T3} = recv(T2),
    ?assertMatch(#result{request_id = 2}, Result),
    ok = bondy_connect_transport_tcp:close(T3),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A CALL that reuses the request id of a live call that is not a progressive
stream aborts the session.
""".
a_reused_request_id_of_a_live_call_aborts_the_session(_) ->
    Proc = ~"com.example.pci.reuse",
    {Handler, Callee, T0} = start_held_call(Proc),
    T1 = send(bondy_wamp_message:call(1, #{}, Proc), T0),
    ok = assert_aborted(T1),
    Handler ! release,
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A CALL that reuses the id of a live call under another procedure, here a
reserved one, is not that call's continuation: it is discarded without running,
and the live call completes.
""".
a_reused_request_id_on_another_procedure_is_discarded(_) ->
    {Handler, Callee, T0} = start_held_call(~"com.example.pci.reuse_other"),
    T1 = send(bondy_wamp_message:call(1, #{}, ?WAMP_REG_LIST), T0),
    ?assertEqual({error, timeout}, bondy_connect_transport_tcp:recv(500, T1)),
    Handler ! release,
    {Result, T2} = recv(T1),
    ?assertMatch(#result{request_id = 1, args = [~"released"]}, Result),
    ok = bondy_connect_transport_tcp:close(T2),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A chunk for a call that has completed is discarded without a reply, and the
session goes on.
""".
a_continuation_of_a_completed_call_is_discarded(_) ->
    Proc = ~"com.example.pci.completed",
    Callee = serve(Proc, fun sum_input/3),
    Echo = ~"com.example.pci.completed.echo",
    {ok, _} = bondy_connect_client:register(Callee, Echo, fun reply_empty/3),

    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    T2 = send(bondy_wamp_message:call(1, #{}, Proc, [2]), T1),
    {Result, T3} = recv(T2),
    ?assertMatch(#result{request_id = 1, args = [3]}, Result),

    T4 = send(bondy_wamp_message:call(1, #{}, Proc, [3]), T3),
    ?assertEqual({error, timeout}, bondy_connect_transport_tcp:recv(500, T4)),
    T5 = send(bondy_wamp_message:call(2, #{}, Echo), T4),
    {Next, T6} = recv(T5),
    ?assertMatch(#result{request_id = 2}, Next),

    ok = bondy_connect_transport_tcp:close(T6),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A caller that did not announce the feature is not held to the request id
sequence.
""".
a_caller_without_the_feature_is_not_sequenced(_) ->
    Proc = ~"com.example.pci.unsequenced",
    Callee = serve(Proc, fun reply_empty/3),
    {#welcome{}, T0} = open(#{caller => #{features => #{}}}),
    T1 = send(bondy_wamp_message:call(7, #{}, Proc), T0),
    {Result, T2} = recv(T1),
    ?assertMatch(#result{request_id = 7}, Result),
    ok = bondy_connect_transport_tcp:close(T2),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A callee that leaves during a stream cancels the call: the caller gets
`wamp.error.canceled`, as for a callee leaving any call.
""".
a_callee_leaving_mid_stream_cancels_the_call(_) ->
    Proc = ~"com.example.pci.callee_leaves",
    TestPid = self(),
    Callee = serve(Proc, fun(_, _, _) ->
        TestPid ! running,
        receive
            release -> {ok, #{args => []}}
        after 5000 -> {ok, #{args => []}}
        end
    end),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    receive
        running -> ok
    after 5000 -> ct:fail(handler_not_running)
    end,
    ok = bondy_connect_client:disconnect(Callee),
    {Error, T2} = recv(T1),
    ?assertMatch(
        #error{
            request_type = ?CALL, request_id = 1, error_uri = ?WAMP_CANCELLED
        },
        Error
    ),
    ok = bondy_connect_transport_tcp:close(T2).

-doc """
A CALL that reuses the request id of a stream but names another procedure is
not part of the stream: the dealer discards it, since the specification matches
a continuation on both the request id and the procedure.
""".
a_continuation_for_another_procedure_is_discarded(_) ->
    Proc = ~"com.example.pci.stream_procedure",
    Other = ~"com.example.pci.other_procedure",
    Callee = serve(Proc, fun sum_input/3),
    {ok, _} = bondy_connect_client:register(Callee, Other, fun reply_empty/3),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    T2 = send(
        bondy_wamp_message:call(1, #{progress => true}, Other, [100]), T1
    ),
    T3 = send(bondy_wamp_message:call(1, #{}, Proc, [2]), T2),
    {Result, T4} = recv(T3),
    ?assertMatch(#result{request_id = 1, args = [3]}, Result),
    ok = bondy_connect_transport_tcp:close(T4),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A stream is authorized by its first chunk. Revoking the caller's permission
mid-stream refuses the caller's next call, not the open stream.
""".
a_stream_is_authorized_once(_) ->
    Proc = ~"com.example.pci.authorized_once",
    TestPid = self(),
    Callee = serve(Proc, fun(Args, KWArgs, Details) ->
        TestPid ! running,
        sum_input(Args, KWArgs, Details)
    end),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    receive
        running -> ok
    after 5000 -> ct:fail(handler_not_running)
    end,
    ok = bondy_rbac:revoke(?REALM, call_grant()),

    T2 = send(bondy_wamp_message:call(1, #{}, Proc, [2]), T1),
    {Result, T3} = recv(T2),
    ?assertMatch(#result{request_id = 1, args = [3]}, Result),
    T4 = send(bondy_wamp_message:call(2, #{}, Proc, [1]), T3),
    {Refused, T5} = recv(T4),
    ?assertMatch(
        #error{request_id = 2, error_uri = ?WAMP_NOT_AUTHORIZED}, Refused
    ),
    ok = bondy_connect_transport_tcp:close(T5),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
Options on a later chunk do not reach the callee: every INVOCATION of a stream
carries the details of the first, apart from `progress`.
""".
a_continuation_cannot_change_the_details(_) ->
    Proc = ~"com.example.pci.frozen_details",
    {#welcome{}, C0} = open(#{
        callee => #{
            features => #{
                progressive_call_invocations => true, call_canceling => true
            }
        }
    }),
    C1 = send(bondy_wamp_message:register(1, #{}, Proc), C0),
    {#registered{}, C2} = recv(C1),

    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    {#invocation{details = First} = Inv, C3} = recv(C2),
    Later = #{progress => true, disclose_me => true, '_extension' => 1},
    T2 = send(bondy_wamp_message:call(1, Later, Proc, [2]), T1),
    {#invocation{details = Second}, C4} = recv(C3),
    T3 = send(
        bondy_wamp_message:call(1, #{disclose_me => true}, Proc, [3]), T2
    ),
    {#invocation{details = Last}, C5} = recv(C4),

    ?assertEqual(First, Second),
    ?assertEqual(maps:remove(progress, First), Last),
    C6 = send(
        bondy_wamp_message:yield(Inv#invocation.request_id, #{}, []), C5
    ),
    {#result{request_id = 1}, T4} = recv(T3),
    ok = bondy_connect_transport_tcp:close(T4),
    ok = bondy_connect_transport_tcp:close(C6).

-doc """
After `finish_input/4` the SDK refuses further chunks of the stream with
`input_finished`, while the call is still live, and the callee gets only the
chunks sent before it.
""".
no_chunk_follows_the_final_chunk(_) ->
    Proc = ~"com.example.pci.final_chunk",
    TestPid = self(),
    Callee = serve(Proc, fun(Args, KWArgs, Details) ->
        Reply = sum_input(Args, KWArgs, Details),
        TestPid ! {summed, self()},
        receive
            release -> Reply
        end
    end),
    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    ok = bondy_connect_client:finish_input(Caller, Token, [2], #{}),
    Worker =
        receive
            {summed, Pid} -> Pid
        after 5000 -> ct:fail(handler_not_summed)
        end,
    ?assertEqual(
        {error, input_finished},
        bondy_connect_client:send_input(Caller, Token, [10], #{})
    ),
    ?assertEqual(
        {error, input_finished},
        bondy_connect_client:finish_input(Caller, Token, [10], #{})
    ),
    Worker ! release,
    ?assertMatch({ok, #{args := [3]}}, next_reply(Token)),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A CALL that reuses the id of a stream after its final chunk, while the callee
is still working, is discarded: the callee gets no further INVOCATION, and the
caller gets the call's RESULT.
""".
a_chunk_after_the_final_chunk_is_discarded(_) ->
    Proc = ~"com.example.pci.after_final",
    {#welcome{}, C0} = open(#{
        callee => #{
            features => #{
                progressive_call_invocations => true, call_canceling => true
            }
        }
    }),
    C1 = send(bondy_wamp_message:register(1, #{}, Proc), C0),
    {#registered{}, C2} = recv(C1),

    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{progress => true}, Proc, [1]), T0),
    {#invocation{} = Inv, C3} = recv(C2),
    T2 = send(bondy_wamp_message:call(1, #{}, Proc, [2]), T1),
    {#invocation{details = Final}, C4} = recv(C3),
    ?assertNot(maps:is_key(progress, Final)),

    T3 = send(bondy_wamp_message:call(1, #{}, Proc, [3]), T2),
    ?assertEqual({error, timeout}, bondy_connect_transport_tcp:recv(500, C4)),

    C5 = send(
        bondy_wamp_message:yield(Inv#invocation.request_id, #{}, [3]), C4
    ),
    {Result, T4} = recv(T3),
    ?assertMatch(#result{request_id = 1, args = [3]}, Result),
    ok = bondy_connect_transport_tcp:close(T4),
    ok = bondy_connect_transport_tcp:close(C5).

-doc """
A chunk the transport refuses to send is reported to the caller, and the stream
stays open: the refused chunk does not count as sent. The case covers the
transport's size check before sending (raw socket frames carry at most 2^24
bytes), not a dead link.
""".
a_chunk_the_transport_refuses_is_reported(_) ->
    Proc = ~"com.example.pci.refused_chunk",
    Callee = serve(Proc, fun sum_input/3),
    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    Oversized = binary:copy(~"x", 1 bsl 24),
    ?assertMatch(
        {error, {message_too_large, _, _}},
        bondy_connect_client:send_input(Caller, Token, [Oversized], #{})
    ),
    ok = bondy_connect_client:finish_input(Caller, Token, [2], #{}),
    ?assertMatch({ok, #{args := [3]}}, next_reply(Token)),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A chunk that reaches the callee after it replied is discarded, not run as a new
invocation. The callee's connection is suspended while its handler replies, so
the reply is queued before the caller's next chunk is forwarded; the case covers
a non-final late chunk, not a late final one.
""".
a_chunk_after_the_callee_replied_is_discarded(_) ->
    Proc = ~"com.example.pci.late_chunk",
    TestPid = self(),
    {bondy_connect_client, CalleePid} =
        Callee = serve(Proc, fun(Args, _, _) ->
            TestPid ! {worker, self(), Args},
            receive
                release -> {ok, #{args => Args}}
            end
        end),
    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    Worker =
        receive
            {worker, Pid, [1]} -> Pid
        after 5000 -> ct:fail(handler_not_running)
        end,
    MRef = monitor(process, Worker),
    ok = sys:suspend(CalleePid),
    Worker ! release,
    receive
        {'DOWN', MRef, process, Worker, _} -> ok
    after 5000 -> ct:fail(handler_not_done)
    end,
    ok = bondy_connect_client:send_input(Caller, Token, [2], #{}),
    timer:sleep(200),
    ok = sys:resume(CalleePid),
    ?assertMatch({ok, #{args := [1]}}, next_reply(Token)),
    receive
        {worker, _, Late} -> ct:fail({late_chunk_invoked, Late})
    after 500 -> ok
    end,
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A handler of a call that streams its input and asks for progressive results
gets both the `input` fun and the `progress` fun: it emits a progressive result
for each chunk it pulls, then the sum.
""".
a_handler_streams_both_ways(_) ->
    Proc = ~"com.example.pci.both_ways",
    Callee = serve(Proc, fun(
        [First], _, #{input := Input, progress := Progress}
    ) ->
        ok = Progress([First], #{}),
        {ok, #{args => [echo_input(Input, Progress, First)]}}
    end),
    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(
        Caller, Proc, [1], #{}, #{receive_progress => true}
    ),
    ok = bondy_connect_client:send_input(Caller, Token, [2], #{}),
    ok = bondy_connect_client:finish_input(Caller, Token, [3], #{}),
    ?assertMatch({progress, #{args := [1]}}, next_reply(Token)),
    ?assertMatch({progress, #{args := [2]}}, next_reply(Token)),
    ?assertMatch({progress, #{args := [3]}}, next_reply(Token)),
    ?assertMatch({ok, #{args := [6]}}, next_reply(Token)),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
An in-VM caller whose progressive CALL aborts the session gets nothing routed
that it sent after that CALL, as over a socket. The connection is suspended
while a second caller process queues a plain call behind the aborting one, so
the plain call reaches the transport before the connection handles the ABORT.
""".
a_local_caller_routes_nothing_after_an_abort(_) ->
    Proc = ~"com.example.pci.local_abort",
    Other = ~"com.example.pci.local_abort.other",
    TestPid = self(),
    Callee = serve(Other, fun(_, _, _) ->
        TestPid ! routed_after_abort,
        {ok, #{args => []}}
    end),
    {ok, {bondy_connect_client, ConnPid} = Caller} =
        bondy_connect_client:connect(#{
            transport => local,
            endpoint => local,
            realm => ?REALM,
            roles => #{caller => #{features => #{}}}
        }),
    MRef = monitor(process, ConnPid),
    ok = sys:suspend(ConnPid),
    _ = spawn(fun() ->
        bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{})
    end),
    ok = await_queue_len(ConnPid, 1),
    _ = spawn(fun() -> bondy_connect_client:call(Caller, Other) end),
    ok = await_queue_len(ConnPid, 2),
    ok = sys:resume(ConnPid),
    receive
        {'DOWN', MRef, process, ConnPid, _} -> ok
    after 5000 -> ct:fail(connection_not_stopped)
    end,
    receive
        routed_after_abort -> ct:fail(routed_after_abort)
    after 500 -> ok
    end,
    ok = bondy_connect_client:disconnect(Callee).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% Opens a caller whose CALL 1 to `Proc` stays live until its handler gets
%% `release`.
start_held_call(Proc) ->
    TestPid = self(),
    Callee = serve(Proc, fun(_, _, _) ->
        TestPid ! {running, self()},
        receive
            release -> {ok, #{args => [~"released"]}}
        after 5000 -> {ok, #{args => []}}
        end
    end),
    {#welcome{}, T0} = open(feature_caller()),
    T1 = send(bondy_wamp_message:call(1, #{}, Proc), T0),
    receive
        {running, Handler} -> {Handler, Callee, T1}
    after 5000 -> ct:fail(handler_not_running)
    end.

call_grant() ->
    #{
        ~"permissions" => [~"wamp.call"],
        ~"uri" => ~"",
        ~"match" => ~"prefix",
        ~"roles" => ~"all"
    }.

feature_caller() ->
    #{caller => #{features => #{progressive_call_invocations => true}}}.

serve(Proc, Handler) ->
    Callee = connect(),
    {ok, _} = bondy_connect_client:register(Callee, Proc, Handler),
    Callee.

reply_empty(_, _, _) ->
    {ok, #{args => []}}.

assert_aborted(T0) ->
    {Abort, T1} = recv(T0),
    ?assertMatch(#abort{reason_uri = ?WAMP_PROTOCOL_VIOLATION}, Abort),
    ?assertEqual({error, closed}, bondy_connect_transport_tcp:recv(5000, T1)),
    ok.

assert_unsupported_callee(Proc, CalleeFeatures) ->
    TestPid = self(),
    Callee = connect(#{roles => #{callee => #{features => CalleeFeatures}}}),
    Handler = fun(_, _, _) ->
        TestPid ! handler_ran,
        {ok, #{args => []}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Proc, Handler),

    Caller = connect(),
    {ok, Token} = bondy_connect_client:call_stream(Caller, Proc, [1], #{}, #{}),
    ?assertMatch(
        {error, #{uri := ?WAMP_FEATURE_NOT_SUPPORTED}}, next_reply(Token)
    ),
    receive
        handler_ran -> ct:fail(handler_ran)
    after 300 -> ok
    end,

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

sum_input([First], _, #{input := Input}) ->
    {ok, #{args => [sum_input(Input, First)]}}.

sum_input(Input, Acc) ->
    case Input() of
        {more, [N], _} -> sum_input(Input, Acc + N);
        {last, [N], _} -> Acc + N
    end.

echo_input(Input, Progress, Acc) ->
    case Input() of
        {more, [N], _} ->
            ok = Progress([N], #{}),
            echo_input(Input, Progress, Acc + N);
        {last, [N], _} ->
            ok = Progress([N], #{}),
            Acc + N
    end.

await_queue_len(Pid, N) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Len} when Len >= N ->
            ok;
        {message_queue_len, _} ->
            timer:sleep(10),
            await_queue_len(Pid, N)
    end.

connect() ->
    connect(#{}).

connect(Extra) ->
    {ok, Conn} = bondy_connect_client:connect(Extra#{
        transport => tcp,
        endpoint => {?HOST, ?PORT},
        realm => ?REALM,
        auth => #{method => ?WAMP_ANON_AUTH},
        serializers => [json]
    }),
    Conn.

next_reply(Token) ->
    receive
        {bondy_connect_client, Token, Reply} -> Reply
    after 5000 ->
        ct:fail(no_reply)
    end.

%% =============================================================================
%% RAW PEER
%% =============================================================================

open(Roles) ->
    {ok, T0} = bondy_connect_transport_tcp:connect({?HOST, ?PORT}, #{}),
    {ok, _, T1} = bondy_connect_transport_tcp:handshake(
        {raw, binary, json}, T0
    ),
    Hello = bondy_wamp_message:hello(?REALM, #{
        roles => Roles, authmethods => [?WAMP_ANON_AUTH]
    }),
    recv(send(Hello, T1)).

send(Msg, T) ->
    ok = bondy_connect_transport_tcp:send(Msg, T),
    T.

recv(T) ->
    {ok, Msgs, T1} = bondy_connect_transport_tcp:recv(5000, T),
    case [M || M <- Msgs, bondy_wamp_message:is_message(M)] of
        [] ->
            recv(T1);
        [Msg] ->
            {Msg, T1}
    end.
