%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_subprotocol).
-moduledoc """
Parses and validates WAMP subprotocol identifiers, mapping their binary
representations (e.g. `wamp.2.json`) to the internal
`{Transport, Frame, Encoding}` subprotocol tuples and back.
""".
-include("bondy_wamp.hrl").

-define(IS_WAMP_TRANSPORT(X), (T =:= ws orelse T =:= raw)).

-export([from_binary/1]).
-export([validate/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec from_binary(binary()) -> subprotocol() | {error, invalid_subprotocol}.

from_binary(?WAMP2_JSON) -> {ws, text, json};
from_binary(?WAMP2_CBOR) -> {ws, binary, cbor};
from_binary(?WAMP2_MSGPACK) -> {ws, binary, msgpack};
from_binary(?WAMP2_JSON_BATCHED) -> {ws, text, json_batched};
from_binary(?WAMP2_CBOR_BATCHED) -> {ws, binary, cbor_batched};
from_binary(?WAMP2_MSGPACK_BATCHED) -> {ws, binary, msgpack_batched};
%% NOTE: wamp.2.bert / wamp.2.bert.batched are intentionally NOT accepted — the
%% BERT decoder is bert:decode/1 => binary_to_term/1 WITHOUT [safe], reachable
%% pre-authentication (atom-table exhaustion / node crash). `erl` is retained
%% because it decodes with binary_to_term(_, [safe]). See
%% bondy_wamp_encoding:decode_message/4.
from_binary(?WAMP2_ERL) -> {ws, binary, erl};
from_binary(?WAMP2_ERL_BATCHED) -> {ws, binary, erl_batched};
from_binary(_) -> {error, invalid_subprotocol}.

-spec validate(binary() | subprotocol()) ->
    {ok, subprotocol()} | {error, invalid_subprotocol}.

validate(T) when is_binary(T) ->
    validate(from_binary(T));
validate({ws, text, json} = S) ->
    {ok, S};
validate({raw, binary, json} = S) ->
    {ok, S};
validate({T, binary, erl} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate({T, binary, cbor} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate({T, binary, msgpack} = S) when ?IS_WAMP_TRANSPORT(T) ->
    {ok, S};
validate(_) ->
    {error, invalid_subprotocol}.
