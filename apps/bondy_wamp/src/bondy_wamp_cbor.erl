%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_cbor).

-moduledoc """
A utility module that offers partial encoding/decoding and some customisation
options over the `bondy_cbor` module.
""".

-include("bondy_wamp.hrl").

-define(DEFAULT_ENCODE_OPTS, []).
%% Map both CBOR null and undefined to Erlang undefined for JSON compatibility
-define(DECODERS, #{null => undefined, undefined => undefined}).
-define(DEFAULT_DECODE_OPTS, [{decoders, ?DECODERS}]).

%% CBOR major types
-define(CBOR_UINT, 0).
-define(CBOR_NEGINT, 1).
-define(CBOR_BYTES, 2).
-define(CBOR_TEXT, 3).
-define(CBOR_ARRAY, 4).
-define(CBOR_MAP, 5).
-define(CBOR_TAG, 6).
-define(CBOR_SIMPLE, 7).

-type encode_opt() :: {check_duplicate_keys, boolean()}.

-type decode_opt() :: {decoders, bondy_cbor:decoders()}.

-export([decode/1]).
-export([decode/2]).
-export([decode_opts/0]).
-export([decode_head/2]).
-export([decode_tail/1]).
-export([decode_tail/2]).
-export([encode/1]).
-export([encode/2]).
-export([encode_with_tail/2]).
-export([try_decode/1]).
-export([try_decode/2]).
-export([validate_opts/1]).

%% =============================================================================
%% API
%% =============================================================================

-spec encode(any()) -> binary().

encode(Term) ->
    Opts = bondy_wamp_config:get([cbor, encode_opts], ?DEFAULT_ENCODE_OPTS),
    encode(Term, Opts).

-spec encode(any(), [encode_opt()]) -> iodata() | binary().

encode(Term, Opts) ->
    do_encode(Term, Opts).

-doc """
Encodes a list of elements (WAMP message) together with a tail obtained
previously using `decode_head/2`.
""".
-spec encode_with_tail(Elements :: [term()], Tail :: binary()) -> iodata().

encode_with_tail(Elements, TailBin) when
    is_list(Elements), is_binary(TailBin)
->
    %% Returned as iodata: flattening would copy the (potentially large)
    %% tail payload once per subscriber, and every consumer accepts
    %% iodata.

    TailCount = count_cbor_elements(TailBin),
    TotalCount = length(Elements) + TailCount,

    HeaderBin = encode_array_header(TotalCount),

    EncodedElements = [bondy_cbor:encode(E) || E <- Elements],

    [HeaderBin, EncodedElements, TailBin].

-spec decode(binary()) -> term() | no_return().

decode(Term) ->
    decode(Term, ?DEFAULT_DECODE_OPTS).

-spec decode(binary(), [decode_opt()]) -> term() | no_return().

decode(Term, Opts) ->
    do_decode(Term, Opts).

-doc """
The options a WAMP message is decoded with. A null decodes as `undefined`,
as it does in `bondy_msgpack`.
""".
-spec decode_opts() -> [decode_opt()].

decode_opts() ->
    ?DEFAULT_DECODE_OPTS.

-doc """
Decodes only the first N control elements from WAMP messages containing payloads,
keeping the rest as binary.

The rest must complete the frame's array with the WAMP `Arguments` list and
`ArgumentsKw` map, each optional, and nothing may follow the array. Otherwise,
or if `Bin` is not one CBOR array, the call raises `badarg`. The router sends the rest on as received, so it parses it once
here and discards the result. The rest of an indefinite-length array is
returned without its break byte.
""".
-spec decode_head(binary(), pos_integer()) ->
    [term()] | {[term()], binary()}.

decode_head(Bin, NumElements) when
    is_binary(Bin), is_integer(NumElements), NumElements > 0
->
    case parse_array_header(Bin) of
        {ok, ArrayLen, Rest} ->
            decode_n_elements(Rest, NumElements, ArrayLen, []);
        {indefinite, Rest} ->
            decode_n_elements_indefinite(Rest, NumElements, []);
        error ->
            error(badarg)
    end;
decode_head(Bin, NumElements) ->
    error(
        bondy_connect_error:new(badarg, #{
            details => #{1 => Bin, 2 => NumElements}
        })
    ).

-spec decode_tail(binary()) -> term() | no_return().

decode_tail(Term) ->
    decode_tail(Term, ?DEFAULT_DECODE_OPTS).

-doc "Decode the CBOR tail binary back into Erlang terms.".
-spec decode_tail(binary(), key_value:t()) -> term() | no_return().

decode_tail(<<>>, _) ->
    [];
decode_tail(Bin, Opts) when is_binary(Bin) ->
    %% The tail contains raw CBOR-encoded elements without array wrapper
    ElementCount = count_cbor_elements(Bin),

    case ElementCount of
        0 ->
            [];
        N ->
            HeaderBin = encode_array_header(N),
            WrappedBin = <<HeaderBin/binary, Bin/binary>>,
            do_decode(WrappedBin, Opts)
    end.

try_decode(Term) ->
    try_decode(Term, []).

try_decode(Term, Opts) ->
    try
        {ok, decode(Term, Opts)}
    catch
        error:Reason ->
            {error, Reason}
    end.

validate_opts(List) when is_list(List) ->
    lists:map(fun validate_opt/1, List).

%% =============================================================================
%% PRIVATE
%% =============================================================================

validate_opt({check_duplicate_keys, Arg} = Term) ->
    is_boolean(Arg) orelse
        error(badarg, {check_duplicate_keys, Arg}),
    Term;
validate_opt({datetime_format, _Opts} = Term) ->
    %% TODO
    Term;
validate_opt(Term) ->
    Term.

%% @private
do_encode(Term, Opts) ->
    ValidatedOpts = validate_opts(Opts),
    Checked = key_value:get(check_duplicate_keys, ValidatedOpts, false),

    Fun = fun
        (undefined, _Encode) ->
            %% Encode undefined as CBOR null for JSON compatibility
            <<16#F6>>;
        ({{Y, M, D}, {H, Mi, S}}, _Encode) when
            ?IS_DATETIME(Y, M, D, H, Mi, S)
        ->
            bondy_cbor:encode_string(
                bondy_wamp_encoding:format_datetime({{Y, M, D}, {H, Mi, S}})
            );
        ([{K, _} | _] = Value, Encode) when
            ?IS_KEY_VALUE_KEY(K), Checked == true
        ->
            bondy_cbor:encode_key_value_list_checked(Value, Encode);
        ([{K, _} | _] = Value, Encode) when
            ?IS_KEY_VALUE_KEY(K), Checked == false
        ->
            bondy_cbor:encode_key_value_list(Value, Encode);
        (Bin, _Encode) when is_binary(Bin) ->
            encode_binary(Bin);
        (Value, Encode) ->
            bondy_cbor:encode_value(Value, Encode)
    end,

    iolist_to_binary(bondy_cbor:encode(Term, Fun)).

%% @private
%% WAMP's CBOR serialization carries strings as CBOR text strings (major type
%% 3), and clients look values up by them -- a CHALLENGE's AuthMethod, a dict
%% key. Erlang has one type for both text and bytes, so a binary that is valid
%% UTF-8 is sent as text, and anything else as a byte string (major type 2).
%% This matches what a JSON client sees, where every binary is a string.
encode_binary(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> bondy_cbor:encode_string(Bin);
        _ -> bondy_cbor:encode_binary(Bin)
    end.

%% @private
do_decode(Term, []) ->
    well_formed(fun() -> bondy_cbor:decode(Term) end);
do_decode(Term, Opts) ->
    Decoders = key_value:get(decoders, Opts, #{}),
    case well_formed(fun() -> bondy_cbor:decode(Term, ok, Decoders) end) of
        {Value, ok, <<>>} -> Value;
        {_, ok, <<_, _/binary>>} -> error(badarg)
    end.

%% @private
%% `bondy_cbor` raises only these on input that is not one well-formed CBOR
%% item (`bondy_cbor:decode/1` doc, `prop_bondy_cbor`).
well_formed(Decode) ->
    try
        Decode()
    catch
        error:incomplete -> error(badarg);
        error:trailing_bytes -> error(badarg);
        error:unexpected_break -> error(badarg);
        error:{invalid_ai, _} -> error(badarg);
        error:{invalid_indefinite_chunk, _} -> error(badarg);
        error:{invalid_simple_value, _} -> error(badarg)
    end.

%% =============================================================================
%% PRIVATE: CBOR PARSING HELPERS
%% =============================================================================

%% @private
parse_array_header(<<?CBOR_ARRAY:3, Info:5, Rest/binary>>) when Info < 24 ->
    {ok, Info, Rest};
parse_array_header(<<?CBOR_ARRAY:3, 24:5, Len:8, Rest/binary>>) ->
    {ok, Len, Rest};
parse_array_header(<<?CBOR_ARRAY:3, 25:5, Len:16, Rest/binary>>) ->
    {ok, Len, Rest};
parse_array_header(<<?CBOR_ARRAY:3, 26:5, Len:32, Rest/binary>>) ->
    {ok, Len, Rest};
parse_array_header(<<?CBOR_ARRAY:3, 27:5, Len:64, Rest/binary>>) ->
    {ok, Len, Rest};
parse_array_header(<<?CBOR_ARRAY:3, 31:5, Rest/binary>>) ->
    {indefinite, Rest};
parse_array_header(Bin) when is_binary(Bin) ->
    error.

%% @private
encode_array_header(Len) when Len < 24 ->
    Byte = (?CBOR_ARRAY bsl 5) bor Len,
    <<Byte>>;
encode_array_header(Len) when Len < 256 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 24,
    <<Byte, Len:8>>;
encode_array_header(Len) when Len < 65536 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 25,
    <<Byte, Len:16>>;
encode_array_header(Len) when Len < 4294967296 ->
    Byte = (?CBOR_ARRAY bsl 5) bor 26,
    <<Byte, Len:32>>;
encode_array_header(Len) ->
    Byte = (?CBOR_ARRAY bsl 5) bor 27,
    <<Byte, Len:64>>.

%% @private
decode_n_elements(<<>>, _N, 0, Acc) ->
    lists:reverse(Acc);
decode_n_elements(Rest, 0, Remaining, Acc) ->
    ok = check_tail(encode_array_header(Remaining), Rest),
    {lists:reverse(Acc), Rest};
decode_n_elements(<<>>, _N, _ArrayLen, _Acc) ->
    error(badarg);
decode_n_elements(Bin, N, ArrayLen, Acc) when N > 0, ArrayLen > 0 ->
    {Element, Rest} = decode_element(Bin),
    decode_n_elements(Rest, N - 1, ArrayLen - 1, [Element | Acc]);
decode_n_elements(<<_, _/binary>>, _N, 0, _Acc) ->
    error(badarg).

%% @private
decode_n_elements_indefinite(<<16#ff>>, _N, Acc) ->
    lists:reverse(Acc);
decode_n_elements_indefinite(<<16#ff, _, _/binary>>, _N, _Acc) ->
    error(badarg);
decode_n_elements_indefinite(Rest, 0, Acc) ->
    ok = check_tail(<<16#9f>>, Rest),
    {lists:reverse(Acc), binary:part(Rest, 0, byte_size(Rest) - 1)};
decode_n_elements_indefinite(Bin, N, Acc) when N > 0 ->
    {Element, Rest} = decode_element(Bin),
    decode_n_elements_indefinite(Rest, N - 1, [Element | Acc]).

%% @private
decode_element(Bin) ->
    {Element, ok, Rest} = well_formed(fun() ->
        bondy_cbor:decode(Bin, ok, ?DECODERS)
    end),
    {Element, Rest}.

%% @private
check_tail(Header, Tail) ->
    case
        well_formed(fun() ->
            bondy_cbor:decode(<<Header/binary, Tail/binary>>, ok, #{})
        end)
    of
        {Payload, ok, <<>>} ->
            check_payload(Payload);
        {_, ok, <<_, _/binary>>} ->
            error(badarg)
    end.

%% @private
check_payload([]) -> ok;
check_payload([Args]) when is_list(Args) -> ok;
check_payload([Args, KwArgs]) when is_list(Args), is_map(KwArgs) -> ok;
check_payload(L) when is_list(L) -> error(badarg).

%% @private
skip_cbor_value(<<>>) ->
    error;
skip_cbor_value(<<MajorAndInfo, Rest/binary>> = Bin) ->
    Major = MajorAndInfo bsr 5,
    Info = MajorAndInfo band 16#1f,

    case Major of
        ?CBOR_UINT ->
            skip_uint(Bin, Info, Rest);
        ?CBOR_NEGINT ->
            skip_uint(Bin, Info, Rest);
        ?CBOR_BYTES ->
            skip_bytes_or_text(Bin, Info, Rest);
        ?CBOR_TEXT ->
            skip_bytes_or_text(Bin, Info, Rest);
        ?CBOR_ARRAY ->
            skip_array(Bin, Info, Rest);
        ?CBOR_MAP ->
            skip_map(Bin, Info, Rest);
        ?CBOR_TAG ->
            skip_tag(Bin, Info, Rest);
        ?CBOR_SIMPLE ->
            skip_simple(Bin, Info, Rest)
    end.

%% @private
skip_uint(Bin, Info, Rest) when Info < 24 ->
    {ok, binary:part(Bin, 0, 1), Rest};
skip_uint(Bin, 24, Rest) ->
    <<_:8, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 2), Rest2};
skip_uint(Bin, 25, Rest) ->
    <<_:16, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 3), Rest2};
skip_uint(Bin, 26, Rest) ->
    <<_:32, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 5), Rest2};
skip_uint(Bin, 27, Rest) ->
    <<_:64, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 9), Rest2};
skip_uint(_, _, _) ->
    error.

%% @private
skip_bytes_or_text(Bin, Info, Rest) when Info < 24 ->
    case Rest of
        <<_:Info/binary, Rest2/binary>> ->
            Len = 1 + Info,
            {ok, binary:part(Bin, 0, Len), Rest2};
        _ ->
            error
    end;
skip_bytes_or_text(Bin, 24, Rest) ->
    <<DataLen:8, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 2 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};
        _ ->
            error
    end;
skip_bytes_or_text(Bin, 25, Rest) ->
    <<DataLen:16, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 3 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};
        _ ->
            error
    end;
skip_bytes_or_text(Bin, 26, Rest) ->
    <<DataLen:32, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 5 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};
        _ ->
            error
    end;
skip_bytes_or_text(Bin, 27, Rest) ->
    <<DataLen:64, Data/binary>> = Rest,
    case Data of
        <<_:DataLen/binary, Rest2/binary>> ->
            Len = 9 + DataLen,
            {ok, binary:part(Bin, 0, Len), Rest2};
        _ ->
            error
    end;
skip_bytes_or_text(Bin, 31, Rest) ->
    skip_until_break(Rest, 1, Bin);
skip_bytes_or_text(_, _, _) ->
    error.

%% @private
skip_array(Bin, Info, Rest) when Info < 24 ->
    skip_n_values(Rest, Info, 1, Bin);
skip_array(Bin, 24, Rest) ->
    <<ArrayLen:8, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 2, Bin);
skip_array(Bin, 25, Rest) ->
    <<ArrayLen:16, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 3, Bin);
skip_array(Bin, 26, Rest) ->
    <<ArrayLen:32, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 5, Bin);
skip_array(Bin, 27, Rest) ->
    <<ArrayLen:64, Rest2/binary>> = Rest,
    skip_n_values(Rest2, ArrayLen, 9, Bin);
skip_array(Bin, 31, Rest) ->
    skip_until_break(Rest, 1, Bin);
skip_array(_, _, _) ->
    error.

%% @private
skip_map(Bin, Info, Rest) when Info < 24 ->
    %% Map has Info pairs, so 2*Info values
    skip_n_values(Rest, Info * 2, 1, Bin);
skip_map(Bin, 24, Rest) ->
    <<MapLen:8, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 2, Bin);
skip_map(Bin, 25, Rest) ->
    <<MapLen:16, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 3, Bin);
skip_map(Bin, 26, Rest) ->
    <<MapLen:32, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 5, Bin);
skip_map(Bin, 27, Rest) ->
    <<MapLen:64, Rest2/binary>> = Rest,
    skip_n_values(Rest2, MapLen * 2, 9, Bin);
skip_map(Bin, 31, Rest) ->
    skip_until_break(Rest, 1, Bin);
skip_map(_, _, _) ->
    error.

%% @private
skip_tag(Bin, Info, Rest) ->
    {_HeaderLen, Rest2} =
        case Info of
            I when I < 24 ->
                {1, Rest};
            24 ->
                <<_:8, R/binary>> = Rest,
                {2, R};
            25 ->
                <<_:16, R/binary>> = Rest,
                {3, R};
            26 ->
                <<_:32, R/binary>> = Rest,
                {5, R};
            27 ->
                <<_:64, R/binary>> = Rest,
                {9, R};
            _ ->
                {0, error}
        end,

    case Rest2 of
        error ->
            error;
        _ ->
            case skip_cbor_value(Rest2) of
                {ok, _ValueBin, Rest3} ->
                    TotalLen = byte_size(Bin) - byte_size(Rest3),
                    {ok, binary:part(Bin, 0, TotalLen), Rest3};
                error ->
                    error
            end
    end.

%% @private
skip_simple(Bin, Info, Rest) when Info < 24 ->
    {ok, binary:part(Bin, 0, 1), Rest};
skip_simple(Bin, 24, Rest) ->
    <<_:8, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 2), Rest2};
skip_simple(Bin, 25, Rest) ->
    <<_:16, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 3), Rest2};
skip_simple(Bin, 26, Rest) ->
    <<_:32, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 5), Rest2};
skip_simple(Bin, 27, Rest) ->
    <<_:64, Rest2/binary>> = Rest,
    {ok, binary:part(Bin, 0, 9), Rest2};
skip_simple(_, _, _) ->
    error.

%% @private
skip_n_values(Rest, 0, _HeaderLen, OrigBin) ->
    TotalLen = byte_size(OrigBin) - byte_size(Rest),
    {ok, binary:part(OrigBin, 0, TotalLen), Rest};
skip_n_values(Bin, N, HeaderLen, OrigBin) when N > 0 ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            skip_n_values(Rest, N - 1, HeaderLen, OrigBin);
        error ->
            error
    end.

%% @private
skip_until_break(<<16#ff, Rest/binary>>, _HeaderLen, OrigBin) ->
    TotalLen = byte_size(OrigBin) - byte_size(Rest),
    {ok, binary:part(OrigBin, 0, TotalLen), Rest};
skip_until_break(Bin, HeaderLen, OrigBin) ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            skip_until_break(Rest, HeaderLen, OrigBin);
        error ->
            error
    end.

%% @private
%% Count the number of CBOR elements in a binary (raw elements, no array wrapper)
count_cbor_elements(<<>>) ->
    0;
count_cbor_elements(Bin) ->
    count_cbor_elements(Bin, 0).

count_cbor_elements(<<>>, Count) ->
    Count;
count_cbor_elements(Bin, Count) ->
    case skip_cbor_value(Bin) of
        {ok, _ValueBin, Rest} ->
            count_cbor_elements(Rest, Count + 1);
        error ->
            Count
    end.
