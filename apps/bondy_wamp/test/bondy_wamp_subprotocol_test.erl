%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_subprotocol_test).

-include_lib("eunit/include/eunit.hrl").
-include("bondy_wamp.hrl").

batched_ids_are_refused_test_() ->
    [
        ?_assertEqual(
            {error, invalid_subprotocol}, bondy_wamp_subprotocol:validate(Id)
        )
     || Id <- [
            ?WAMP2_JSON_BATCHED,
            ?WAMP2_CBOR_BATCHED,
            ?WAMP2_MSGPACK_BATCHED,
            ?WAMP2_ERL_BATCHED
        ]
    ].

unbatched_ids_are_accepted_test_() ->
    [
        ?_assertMatch({ok, _}, bondy_wamp_subprotocol:validate(Id))
     || Id <- [?WAMP2_JSON, ?WAMP2_CBOR, ?WAMP2_MSGPACK, ?WAMP2_ERL]
    ].
