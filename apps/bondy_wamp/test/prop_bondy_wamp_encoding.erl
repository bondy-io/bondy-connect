%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_wamp_encoding).

-include_lib("proper/include/proper.hrl").

-export([prop_decode_raises_only_recognised_errors/0]).

%% =============================================================================
%% Properties
%% =============================================================================

%% A valid message of each WAMP type, with any one field after the type
%% replaced by an arbitrary JSON value, either decodes or raises one of the
%% errors `bondy_wamp_protocol:handle_inbound/2` answers with an ABORT or an
%% ERROR, in JSON and in CBOR, with partial decoding on and off.
prop_decode_raises_only_recognised_errors() ->
    {ok, _} = application:ensure_all_started(bondy_wamp),
    ?FORALL(
        {Message, Pos, Value},
        ?LET(M, oneof(messages()), {M, choose(2, length(M)), json_value()}),
        begin
            Mutated = replace(Message, Pos, Value),
            Codecs = [
                {{ws, text, json}, fun(M) ->
                    iolist_to_binary(json:encode(M))
                end},
                {{ws, binary, cbor}, fun(M) ->
                    iolist_to_binary(bondy_cbor:encode(M))
                end}
            ],
            lists:all(
                fun({{Subprotocol, Encode}, Opts}) ->
                    decodes(Subprotocol, Encode(Message), Opts) andalso
                        decodes_or_raises_recognised(
                            Subprotocol, Encode(Mutated), Opts
                        )
                end,
                [{C, O} || C <- Codecs, O <- [[], [{partial_decode, false}]]]
            )
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

messages() ->
    Uri = ~"com.example.p",
    Hello = #{~"roles" => #{~"caller" => #{}}},
    Welcome = #{
        ~"realm" => ~"com.example",
        ~"roles" => #{~"broker" => #{}},
        ~"authid" => ~"alice",
        ~"authrole" => ~"user"
    },
    Payloads = [[], [[1]], [[1], #{~"a" => 1}]],
    [[1, Uri, Hello], [2, 1, Welcome], [3, #{}, ~"wamp.close.x"]] ++
        [[4, ~"ticket", #{}], [5, ~"signature", #{}]] ++
        [[6, #{}, ~"wamp.close.x"], [17, 1, 2], [32, 1, #{}, Uri]] ++
        [[33, 1, 2], [34, 1, 2], [35, 1], [49, 1, #{}], [64, 1, #{}, Uri]] ++
        [[65, 1, 2], [66, 1, 2], [67, 1], [67, 1, #{}], [69, 1, #{}]] ++
        [[8, 48, 1, #{}, ~"wamp.error.x" | P] || P <- Payloads] ++
        [[16, 1, #{}, Uri | P] || P <- Payloads] ++
        [[36, 1, 2, #{} | P] || P <- Payloads] ++
        [[48, 1, #{}, Uri | P] || P <- Payloads] ++
        [[50, 1, #{} | P] || P <- Payloads] ++
        [[68, 1, 2, #{} | P] || P <- Payloads] ++
        [[70, 1, #{} | P] || P <- Payloads].

json_value() ->
    ?SIZED(Size, json_value(min(Size, 8))).

json_value(0) ->
    oneof([integer(), float(), utf8(), boolean(), null]);
json_value(Size) ->
    Smaller = ?LAZY(json_value(Size div 2)),
    frequency([
        {4, json_value(0)},
        {1, list(Smaller)},
        {1, map(utf8(), Smaller)}
    ]).

%% =============================================================================
%% Helpers
%% =============================================================================

replace(List, Pos, Value) ->
    lists:sublist(List, Pos - 1) ++ [Value | lists:nthtail(Pos, List)].

decodes(Subprotocol, Bin, Opts) ->
    {[_], <<>>} = bondy_wamp_encoding:decode(Subprotocol, Bin, Opts),
    true.

decodes_or_raises_recognised(Subprotocol, Bin, Opts) ->
    try bondy_wamp_encoding:decode(Subprotocol, Bin, Opts) of
        {[_], <<>>} -> true
    catch
        error:badarg -> true;
        error:{invalid_message, _} -> true;
        error:{validation_failed, _, #{}} -> true;
        error:{invalid_uri, Uri, #{}} when is_binary(Uri) -> true
    end.
