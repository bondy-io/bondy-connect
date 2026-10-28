%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_wamp_cbor).

-include_lib("proper/include/proper.hrl").

-export([prop_decode_raises_only_badarg/0]).

%% =============================================================================
%% Properties
%% =============================================================================

%% Prefixes of an encoded WAMP-shaped message, the message with one byte
%% replaced or one byte appended, and random bytes either decode or raise
%% `badarg`, through every decoding entry point of `bondy_wamp_cbor`.
prop_decode_raises_only_badarg() ->
    ?FORALL(
        {Message, Edits, Random},
        {message(), list({nat(), byte()}), binary()},
        begin
            Bin = iolist_to_binary(bondy_cbor:encode(Message)),
            Size = byte_size(Bin),
            Inputs =
                [Random] ++
                    [binary:part(Bin, 0, Pos rem Size) || {Pos, _} <- Edits] ++
                    [replace(Bin, Pos rem Size, Byte) || {Pos, Byte} <- Edits] ++
                    [<<Bin/binary, Byte>> || {_, Byte} <- Edits],
            lists:all(fun decodes_or_raises_badarg/1, Inputs)
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

message() ->
    ?LET(
        {Type, Id, Details, Uri, Payload},
        {
            oneof([1, 8, 16, 36, 48, 50, 68, 70]),
            non_neg_integer(),
            map(binary(), value()),
            binary(),
            oneof([[], [list(value())], [list(value()), map(binary(), value())]])
        },
        [Type, Id, Details, Uri | Payload]
    ).

value() ->
    oneof([integer(), float(), binary(), boolean(), null, list(integer())]).

%% =============================================================================
%% Helpers
%% =============================================================================

replace(Bin, Pos, Byte) ->
    <<Prefix:Pos/binary, _, Suffix/binary>> = Bin,
    <<Prefix/binary, Byte, Suffix/binary>>.

decodes_or_raises_badarg(Bin) ->
    lists:all(
        fun(Decode) -> raises_badarg(fun() -> Decode(Bin) end) end,
        [
            fun(B) -> bondy_wamp_cbor:decode(B, []) end,
            fun(B) -> bondy_wamp_cbor:decode(B, [{decoders, #{}}]) end,
            fun(B) -> bondy_wamp_cbor:decode_head(B, 2) end,
            fun(B) -> bondy_wamp_cbor:decode_head(B, 4) end
        ]
    ).

raises_badarg(Decode) ->
    try Decode() of
        _ -> true
    catch
        error:badarg -> true
    end.
