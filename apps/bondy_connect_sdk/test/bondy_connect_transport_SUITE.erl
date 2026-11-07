%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_transport_SUITE).

-moduledoc """
Integration tests for the raw-socket TCP transport against a live Bondy router
(the `wamp_tcp` listener). Exercises the transport and protocol stack
end-to-end: `bondy_connect_protocol` builds the HELLO record,
`bondy_connect_transport_tcp` encodes/frames/sends it and
reads/deframes/decodes the reply, and the protocol layer turns the WELCOME
record into an established session — no gen_statem.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_connect.hrl").

-compile([nowarn_export_all, export_all]).

-define(REALM, <<"com.example.bondy_connect.pr2">>).
-define(HOST, "127.0.0.1").
-define(PORT, 18082).
%% The LENGTH a small-limit client announces: 2^11 octets.
-define(SMALL_LIMIT, 2048).

all() ->
    [
        handshake_succeeds,
        serializer_negotiated,
        hello_welcome_round_trip,
        oversized_event_is_dropped_for_that_subscriber_only,
        oversized_call_result_is_a_payload_size_exceeded_error,
        oversized_call_error_is_a_payload_size_exceeded_error,
        oversized_invocation_is_a_payload_size_exceeded_error,
        oversized_progressive_result_ends_the_call,
        no_chunk_follows_an_oversized_progressive_result,
        an_oversized_input_chunk_ends_the_call,
        no_input_chunk_follows_an_oversized_one
    ].

init_per_suite(Config) ->
    bondy_ct:start_bondy(),
    {ok, _} = application:ensure_all_started(bondy_connect_sdk),
    ok = add_anon_realm(?REALM),
    [{transport, tcp} | Config].

end_per_suite(_) ->
    ok.

%% @private An anonymous-only realm reachable from any IP.
add_anon_realm(RealmUri) ->
    Cfg = #{
        uri => RealmUri,
        authmethods => [?WAMP_ANON_AUTH],
        security_enabled => true,
        grants => [
            #{
                permissions => [
                    <<"wamp.call">>,
                    <<"wamp.register">>,
                    <<"wamp.publish">>,
                    <<"wamp.subscribe">>
                ],
                uri => <<"">>,
                match => <<"prefix">>,
                roles => [<<"anonymous">>]
            }
        ],
        sources => [
            #{
                usernames => [<<"anonymous">>],
                authmethod => ?WAMP_ANON_AUTH,
                cidr => <<"0.0.0.0/0">>
            }
        ]
    },
    _ = bondy_realm:create(Cfg),
    ok.

%% @private Connect + raw handshake, returning the transport state.
connected(Enc) ->
    {ok, T0} = bondy_connect_transport_tcp:connect({?HOST, ?PORT}, #{}),
    {ok, Negotiated, T1} =
        bondy_connect_transport_tcp:handshake({raw, binary, Enc}, T0),
    {Negotiated, T1}.

%% @private Recv until at least one WAMP message record arrives (skip control
%% frames), or fail loudly.
recv_message(T, Timeout) ->
    case bondy_connect_transport_tcp:recv(Timeout, T) of
        {ok, Msgs, T1} ->
            case [M || M <- Msgs, bondy_wamp_message:is_message(M)] of
                [Msg | _] -> {Msg, T1};
                [] -> recv_message(T1, Timeout)
            end;
        {error, Reason} ->
            ct:fail({recv_failed, Reason})
    end.

%% =============================================================================
%% TESTS
%% =============================================================================

handshake_succeeds(_) ->
    {Negotiated, T} = connected(json),
    ?assertEqual({raw, binary, json}, Negotiated),
    ok = bondy_connect_transport_tcp:close(T).

serializer_negotiated(_) ->
    %% The router accepts and echoes our requested serializer.
    {Negotiated, T} = connected(msgpack),
    ?assertEqual({raw, binary, msgpack}, Negotiated),
    ok = bondy_connect_transport_tcp:close(T).

hello_welcome_round_trip(_) ->
    {ok, Cfg} = bondy_connect_config:validate(#{
        realm => ?REALM, auth => #{method => ?WAMP_ANON_AUTH}
    }),
    {ok, P0} = bondy_connect_protocol:init(Cfg),
    {ok, Hello, P1} = bondy_connect_protocol:start(P0),

    {_Negotiated, T1} = connected(json),
    ok = bondy_connect_transport_tcp:send(Hello, T1),

    {Reply, T2} = recv_message(T1, 5000),
    ?assertMatch(#welcome{}, Reply),

    {established, Session, P2} =
        bondy_connect_protocol:handle_message(Reply, P1),
    ?assertEqual(established, bondy_connect_protocol:state_name(P2)),
    ?assertEqual(?REALM, bondy_connect_session:realm_uri(Session)),
    ?assert(is_integer(bondy_connect_session:id(Session))),
    ?assert(bondy_connect_session:id(Session) > 0),
    ct:pal("Established session: ~p", [Session]),

    ok = bondy_connect_transport_tcp:close(T2).

-doc """
An EVENT larger than a subscriber's announced LENGTH is not sent to it.

A second subscriber with the default limit receives the large event, so the
router did route it. Both events come from one publisher, and WAMP delivers
them to a subscriber in publication order, so the small-limit subscriber
receiving the second event and never the first means the first was dropped
rather than delayed. Before the fix the router sent the large frame and the
SDK codec, which enforces its own receive limit, failed the connection.
""".
oversized_event_is_dropped_for_that_subscriber_only(Config) ->
    Topic = <<"com.example.transport.oversized_event">>,
    Self = self(),
    ok = attach_dropped(Self),
    Small = client(Config, #{
        max_message_length => ?SMALL_LIMIT
    }),
    Large = client(Config, #{}),
    Pub = client(Config, #{}),

    {ok, _} = bondy_connect_client:subscribe(Small, Topic, tagged(small, Self)),
    {ok, _} = bondy_connect_client:subscribe(Large, Topic, tagged(large, Self)),
    ok = bondy_connect_client:publish(Pub, Topic, [oversized()]),
    ok = bondy_connect_client:publish(Pub, Topic, [<<"small">>]),

    ?assertEqual([oversized()], recv_event(large)),
    ?assertEqual([<<"small">>], recv_event(large)),
    ?assertEqual([<<"small">>], recv_event(small)),
    receive
        {dropped, #{reason := payload_size_exceeded, family := event}} -> ok
    after 5000 ->
        ct:fail(no_dropped_telemetry)
    end,
    ?assertEqual(established, bondy_connect_client:status(Small)),

    ok = detach_dropped(),
    ok = bondy_connect_client:disconnect(Small),
    ok = bondy_connect_client:disconnect(Large),
    ok = bondy_connect_client:disconnect(Pub).

-doc """
A final RESULT larger than the caller's announced LENGTH reaches the caller as
ERROR `wamp.error.payload_size_exceeded`, and the caller's connection stays
usable: the follow-up call on the same connection succeeds.
""".
oversized_call_result_is_a_payload_size_exceeded_error(Config) ->
    Handler = fun(_, _, _) -> {ok, #{args => [oversized()]}} end,
    oversized_reply_is_an_error(
        Config,
        <<"com.example.transport.big_result">>,
        Handler
    ).

-doc """
A callee ERROR larger than the caller's announced LENGTH is replaced the same
way as an oversized RESULT.
""".
oversized_call_error_is_a_payload_size_exceeded_error(Config) ->
    Handler = fun(_, _, _) ->
        {error, #{
            uri => <<"com.example.business_error">>,
            args => [oversized()]
        }}
    end,
    oversized_reply_is_an_error(
        Config,
        <<"com.example.transport.big_error">>,
        Handler
    ).

-doc """
An INVOCATION larger than the callee's announced LENGTH is not sent: the caller
gets ERROR `wamp.error.payload_size_exceeded`, the handler never runs, and the
same callee then serves a small call.
""".
oversized_invocation_is_a_payload_size_exceeded_error(Config) ->
    Uri = <<"com.example.transport.big_invocation">>,
    Echo = <<Uri/binary, ".echo">>,
    Self = self(),
    Callee = client(Config, #{max_message_length => ?SMALL_LIMIT}),
    Invoked = fun(_, _, _) ->
        Self ! invoked,
        {ok, #{args => []}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Invoked),
    {ok, _} = bondy_connect_client:register(
        Callee, Echo, bondy_connect_ct:echo_handler()
    ),
    Caller = client(Config, #{}),

    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PAYLOAD_SIZE_EXCEEDED}},
        bondy_connect_client:call(Caller, Uri, [oversized()])
    ),
    receive
        invoked -> ct:fail(oversized_invocation_delivered)
    after 0 -> ok
    end,
    {ok, Result} = bondy_connect_client:call(Caller, Echo, [<<"hi">>]),
    ?assertEqual([<<"hi">>], maps:get(args, Result)),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
A progressive RESULT larger than the caller's announced LENGTH ends the call:
the caller gets the chunk before it, then ERROR
`wamp.error.payload_size_exceeded`, and nothing after it.

The caller alone cannot show the call ended, because the SDK discards a RESULT
for a call it has already settled. The callee shows it: the INTERRUPT makes the
SDK kill the handler during its wait, so it never reports `callee_continued`.
The wait also means this covers a chunk yielded after the call ended, not one
already on its way when it ended; that race is the same one a caller's own
`killnowait` CANCEL has.
""".
oversized_progressive_result_ends_the_call(Config) ->
    Features = bondy_connect_ct:dealer_features(),
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_results], true
    ),
    Uri = <<"com.example.transport.big_progressive">>,
    Self = self(),
    Callee = client(Config, #{}),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        ok = Progress([<<"first">>], #{}),
        ok = Progress([oversized()], #{}),
        timer:sleep(1000),
        Self ! callee_continued,
        _ = Progress([<<"after">>], #{}),
        {ok, #{args => [<<"final">>]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),
    Caller = client(Config, #{max_message_length => ?SMALL_LIMIT}),

    {ok, Token} = bondy_connect_client:call_async(
        Caller, Uri, [], #{}, #{receive_progress => true}
    ),
    ?assertMatch({progress, #{args := [<<"first">>]}}, next_reply(Token)),
    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PAYLOAD_SIZE_EXCEEDED}},
        next_reply(Token)
    ),
    receive
        {bondy_connect_client, Token, Extra} -> ct:fail({extra_reply, Extra});
        callee_continued -> ct:fail(call_not_ended)
    after 2000 -> ok
    end,
    ?assertEqual(established, bondy_connect_client:status(Caller)),

    ok = bondy_connect_ct:restore_dealer_features(Features),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
After a progressive RESULT the caller cannot receive, the caller receives no
further chunk of that call, only the ERROR.

The callee yields its chunks back to back, so chunks after the oversized one
are already on their way to the caller when the call ends. The SDK client
discards a RESULT for a call it has settled, so the caller here is a raw
socket client that reads every frame and records each message for the call.
It announces the small LENGTH, so its codec also fails the read if the router
sends it an oversized frame.
""".
no_chunk_follows_an_oversized_progressive_result(Config) ->
    Features = bondy_connect_ct:dealer_features(),
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_results], true
    ),
    Uri = <<"com.example.transport.in_flight_progressive">>,
    Callee = client(Config, #{}),
    Handler = fun(_, _, Details) ->
        Progress = maps:get(progress, Details),
        ok = Progress([<<"first">>], #{}),
        ok = Progress([oversized()], #{}),
        lists:foreach(
            fun(N) -> _ = Progress([N], #{}) end, lists:seq(1, 200)
        ),
        {ok, #{args => [<<"final">>]}}
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),

    T0 = raw_session(?SMALL_LIMIT),
    CallId = 1,
    Call = bondy_wamp_message:call(
        CallId, #{receive_progress => true}, Uri, []
    ),
    ok = bondy_connect_transport_tcp:send(Call, T0),
    {Received, T1} = recv_all(T0, 2000, []),

    ?assertMatch(
        [
            #result{
                request_id = CallId,
                args = [<<"first">>],
                details = #{progress := true}
            },
            #error{
                request_type = ?CALL,
                request_id = CallId,
                error_uri = ?WAMP_PAYLOAD_SIZE_EXCEEDED
            }
        ],
        Received
    ),

    ok = bondy_connect_ct:restore_dealer_features(Features),
    ok = bondy_connect_transport_tcp:close(T1),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
An input chunk of a progressive call that is larger than the callee's LENGTH
ends the call: the caller gets one ERROR `wamp.error.payload_size_exceeded`,
the callee's handler sees the chunks before it and none after it, and the
handler is interrupted rather than left waiting for input.
""".
an_oversized_input_chunk_ends_the_call(Config) ->
    Features = bondy_connect_ct:dealer_features(),
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations], true
    ),
    Uri = <<"com.example.transport.big_input_chunk">>,
    Self = self(),
    Callee = client(Config, #{max_message_length => ?SMALL_LIMIT}),
    Handler = fun([First], _, #{input := Input}) ->
        Self ! {worker, self()},
        Self ! {chunk, First},
        Pull = fun Pull() ->
            case Input() of
                {more, [N], _} ->
                    Self ! {chunk, N},
                    Pull();
                {last, [N], _} ->
                    Self ! {chunk, N},
                    {ok, #{args => []}}
            end
        end,
        Pull()
    end,
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),
    Caller = client(Config, #{}),

    {ok, Token} = bondy_connect_client:call_stream(Caller, Uri, [1], #{}, #{}),
    Worker =
        receive
            {worker, W} -> W
        after 5000 -> ct:fail(handler_not_running)
        end,
    MRef = monitor(process, Worker),
    ?assertEqual(1, recv_chunk()),
    ok = bondy_connect_client:send_input(Caller, Token, [oversized()], #{}),
    ok = bondy_connect_client:send_input(Caller, Token, [3], #{}),
    ok = bondy_connect_client:finish_input(Caller, Token, [4], #{}),

    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PAYLOAD_SIZE_EXCEEDED}},
        next_reply(Token)
    ),
    receive
        {'DOWN', MRef, process, Worker, _} -> ok;
        {chunk, N} -> ct:fail({chunk_after_oversized, N})
    after 5000 ->
        ct:fail(callee_not_interrupted)
    end,
    receive
        {chunk, Late} -> ct:fail({chunk_after_oversized, Late});
        {bondy_connect_client, Token, Extra} -> ct:fail({extra_reply, Extra})
    after 1000 -> ok
    end,
    ?assertEqual(established, bondy_connect_client:status(Callee)),

    ok = bondy_connect_ct:restore_dealer_features(Features),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

-doc """
After an input chunk the callee cannot receive, the callee receives no further
chunk of that call, only the INTERRUPT.

The caller sends its chunks back to back, so chunks after the oversized one are
already on their way to the callee when the call ends. An SDK callee discards
input for an invocation it has interrupted, so the callee here is a raw socket
client that reads every frame and records each message. It announces the small
LENGTH, so its codec also fails the read if the router sends it an oversized
frame.
""".
no_input_chunk_follows_an_oversized_one(Config) ->
    Features = bondy_connect_ct:dealer_features(),
    ok = bondy_config:set(
        [wamp, dealer, features, progressive_call_invocations], true
    ),
    Uri = <<"com.example.transport.in_flight_input">>,
    T0 = raw_session(?SMALL_LIMIT),
    ok = bondy_connect_transport_tcp:send(
        bondy_wamp_message:register(1, #{}, Uri), T0
    ),
    {#registered{}, T1} = recv_message(T0, 5000),
    Caller = client(Config, #{}),

    {ok, Token} = bondy_connect_client:call_stream(Caller, Uri, [0], #{}, #{}),
    ok = bondy_connect_client:send_input(Caller, Token, [oversized()], #{}),
    %% Once the caller has the ERROR its SDK refuses further input
    %% (`unknown_token'); until then each chunk goes out.
    lists:foreach(
        fun(N) ->
            _ = bondy_connect_client:send_input(Caller, Token, [N], #{})
        end,
        lists:seq(1, 200)
    ),

    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PAYLOAD_SIZE_EXCEEDED}},
        next_reply(Token)
    ),
    {Received, T2} = recv_all(T1, 2000, []),
    ?assertMatch(
        [#invocation{args = [0]}, #interrupt{}],
        Received
    ),
    [#invocation{request_id = InvocationId}, #interrupt{request_id = Id}] =
        Received,
    ?assertEqual(InvocationId, Id),

    ok = bondy_connect_ct:restore_dealer_features(Features),
    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_transport_tcp:close(T2).

%% =============================================================================
%% HELPERS
%% =============================================================================

%% @private
recv_chunk() ->
    receive
        {chunk, N} -> N
    after 5000 ->
        ct:fail(no_chunk)
    end.

%% @private A raw-socket session on this suite's realm, announcing `Limit' as
%% its LENGTH.
raw_session(Limit) ->
    {ok, Cfg} = bondy_connect_config:validate(#{
        realm => ?REALM, auth => #{method => ?WAMP_ANON_AUTH}
    }),
    {ok, P0} = bondy_connect_protocol:init(Cfg),
    {ok, Hello, _} = bondy_connect_protocol:start(P0),
    {ok, T0} = bondy_connect_transport_tcp:connect(
        {?HOST, ?PORT}, #{max_message_length => Limit}
    ),
    {ok, _, T1} = bondy_connect_transport_tcp:handshake(
        {raw, binary, json}, T0
    ),
    ok = bondy_connect_transport_tcp:send(Hello, T1),
    {#welcome{}, T2} = recv_message(T1, 5000),
    T2.

%% @private Every WAMP message that arrives until none has for `Quiet' ms, in
%% arrival order. A read error, such as the codec refusing an oversized frame,
%% fails the case.
recv_all(T, Quiet, Acc) ->
    case bondy_connect_transport_tcp:recv(Quiet, T) of
        {ok, Msgs, T1} ->
            Wamp = [M || M <- Msgs, bondy_wamp_message:is_message(M)],
            recv_all(T1, Quiet, lists:reverse(Wamp, Acc));
        {error, timeout} ->
            {lists:reverse(Acc), T};
        {error, Reason} ->
            ct:fail({recv_failed, Reason, lists:reverse(Acc)})
    end.

%% @private
oversized_reply_is_an_error(Config, Uri, Handler) ->
    Echo = <<Uri/binary, ".echo">>,
    Callee = client(Config, #{}),
    {ok, _} = bondy_connect_client:register(Callee, Uri, Handler),
    {ok, _} = bondy_connect_client:register(
        Callee, Echo, bondy_connect_ct:echo_handler()
    ),
    Caller = client(Config, #{
        max_message_length => ?SMALL_LIMIT
    }),

    ?assertMatch(
        {error, #{kind := wamp, uri := ?WAMP_PAYLOAD_SIZE_EXCEEDED}},
        bondy_connect_client:call(Caller, Uri, [])
    ),
    {ok, Result} = bondy_connect_client:call(Caller, Echo, [<<"hi">>]),
    ?assertEqual([<<"hi">>], maps:get(args, Result)),

    ok = bondy_connect_client:disconnect(Caller),
    ok = bondy_connect_client:disconnect(Callee).

%% @private An established SDK client on this suite's realm, over raw TCP.
client(Config, Extra) ->
    bondy_connect_ct:connect(Config, Extra#{realm => ?REALM}).

%% @private Larger than `?SMALL_LIMIT' once encoded, in any serializer.
oversized() ->
    binary:copy(<<"x">>, 2 * ?SMALL_LIMIT).

%% @private
tagged(Tag, Pid) ->
    fun(Args, _, _) ->
        Pid ! {event, Tag, Args},
        ok
    end.

%% @private
next_reply(Token) ->
    receive
        {bondy_connect_client, Token, Reply} -> Reply
    after 5000 ->
        ct:fail(no_reply)
    end.

%% @private
recv_event(Tag) ->
    receive
        {event, Tag, Args} -> Args
    after 5000 ->
        ct:fail({no_event, Tag})
    end.

%% @private
attach_dropped(Pid) ->
    telemetry:attach(
        {?MODULE, dropped},
        [bondy, wamp, dropped],
        fun ?MODULE:handle_dropped/4,
        Pid
    ).

%% @private
detach_dropped() ->
    telemetry:detach({?MODULE, dropped}).

%% @private
handle_dropped(_Event, _Measurements, Meta, Pid) ->
    Pid ! {dropped, Meta},
    ok.
