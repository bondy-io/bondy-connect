%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oauth_jwt_test).
-moduledoc """
`bondy_oauth_jwt:decode/1` on untrusted input: one malformed token per error
shape `jose_jwt:peek/1` raises with OTP's `json` as jose's JSON adapter, each
answered `{error, invalid}`.
""".

-include_lib("eunit/include/eunit.hrl").

b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).

with_payload(Json) ->
    <<"e30.", (b64(Json))/binary, ".sig">>.

decodes_a_json_object_payload_test() ->
    ?assertEqual(
        {ok, #{~"sub" => ~"x"}},
        bondy_oauth_jwt:decode(with_payload(~"{\"sub\":\"x\"}"))
    ).

malformed_tokens_are_invalid_test_() ->
    Cases = [
        {"not three segments (badarg)", ~"not-a-token"},
        {"payload one base64url character (case_clause)", ~"a.b.c"},
        {"payload not base64url (case_clause)", ~"e30.@@@.sig"},
        {"payload not a JSON object (function_clause)", with_payload(~"1")},
        {"payload truncated JSON (unexpected_end)", with_payload(~"{")},
        {"payload trailing bytes (invalid_byte)", with_payload(~"{}x")},
        {"payload bad escape (unexpected_sequence)",
            with_payload(~"\"\\ud800\\u0041\"")}
    ],
    [
        {Name, ?_assertEqual({error, invalid}, bondy_oauth_jwt:decode(Token))}
     || {Name, Token} <- Cases
    ].
