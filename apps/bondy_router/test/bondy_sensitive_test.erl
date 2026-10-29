%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_sensitive_test).

-include_lib("eunit/include/eunit.hrl").

%% The three modules raise `function_clause`, `{badmatch, _}` and `{badmap, _}`
%% on an unset state.
format_status_keeps_an_unset_state_test_() ->
    [
        {atom_to_list(Mod), fun() ->
            {module, Mod} = code:ensure_loaded(Mod),
            ?assertEqual(
                undefined, bondy_sensitive:format_status(Mod, undefined)
            )
        end}
     || Mod <- [bondy_session, bondy_auth, bondy_context]
    ].
