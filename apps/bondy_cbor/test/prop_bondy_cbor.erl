%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_cbor).

-include_lib("proper/include/proper.hrl").

-export([prop_decode_raises_only_documented_errors/0]).

%% =============================================================================
%% Properties
%% =============================================================================

%% Prefixes of an encoding, the encoding with one byte replaced or one byte
%% appended, and random bytes either decode or raise one of the reasons the
%% `bondy_cbor:decode/1` doc lists.
prop_decode_raises_only_documented_errors() ->
    ?FORALL(
        {Term, Edits, Random},
        {cbor_term(), list({nat(), byte()}), binary()},
        begin
            Bin = iolist_to_binary(bondy_cbor:encode(Term)),
            Size = byte_size(Bin),
            Inputs =
                [Random] ++
                    [binary:part(Bin, 0, Pos rem Size) || {Pos, _} <- Edits] ++
                    [replace(Bin, Pos rem Size, Byte) || {Pos, Byte} <- Edits] ++
                    [<<Bin/binary, Byte>> || {_, Byte} <- Edits],
            lists:all(fun decodes_or_raises_documented/1, Inputs)
        end
    ).

%% =============================================================================
%% Generators
%% =============================================================================

cbor_term() ->
    ?SIZED(Size, cbor_term(min(Size, 12))).

cbor_term(0) ->
    scalar();
cbor_term(Size) ->
    frequency([
        {3, scalar()},
        {1, ?LAZY(list(cbor_term(Size div 3)))},
        {1, ?LAZY(map(binary(), cbor_term(Size div 3)))}
    ]).

scalar() ->
    oneof([
        integer(),
        oneof([power_of_two(), ?LET(N, power_of_two(), -N)]),
        float(),
        binary(),
        utf8(),
        boolean(),
        null
    ]).

power_of_two() ->
    ?LET(N, integer(0, 64), 1 bsl N).

%% =============================================================================
%% Helpers
%% =============================================================================

replace(Bin, Pos, Byte) ->
    <<Prefix:Pos/binary, _, Suffix/binary>> = Bin,
    <<Prefix/binary, Byte, Suffix/binary>>.

decodes_or_raises_documented(Bin) ->
    raises_documented(fun() -> bondy_cbor:decode(Bin) end) andalso
        raises_documented(fun() -> bondy_cbor:decode(Bin, ok, #{}) end).

raises_documented(Decode) ->
    try Decode() of
        _ -> true
    catch
        error:incomplete -> true;
        error:trailing_bytes -> true;
        error:unexpected_break -> true;
        error:{invalid_ai, AI} when AI >= 28 -> true;
        error:{invalid_indefinite_chunk, MT} when is_integer(MT) -> true;
        error:{invalid_simple_value, V} when V < 32 -> true
    end.
