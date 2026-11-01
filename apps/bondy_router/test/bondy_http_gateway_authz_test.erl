%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_http_gateway_authz_test).
-moduledoc """
The API gateway `is_authorized/3` anonymous case: only an endpoint declaring an
empty security map is served without authentication. The unenforced schemes
answer `401`, which `bondy_http_api_gateway_SUITE`'s
`unenforced_schemes_answer_unauthorized_test` checks over HTTP.
""".

-include_lib("eunit/include/eunit.hrl").

-define(H, bondy_http_gateway_rest_handler).

empty_security_is_anonymous_test() ->
    %% The anonymous clause never inspects the Req, so a stub suffices.
    ?assertMatch(
        {true, _, #{is_anonymous := true}},
        ?H:is_authorized(~"GET", #{stub_req => true}, #{security => #{}})
    ).
