%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_uri).
-moduledoc """
Validation and matching of WAMP URIs.

Provides validation against the loose and strict URI rules (including their
prefix and empty-component variants) and matching of a ground URI against a
pattern using the exact, prefix and wildcard match strategies.
""".
-include("bondy_wamp.hrl").

-define(STRICT_CHAR(C),
    ((C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_)
).
%% Any byte above space except the separator, `#' and DEL: whitespace and the
%% control characters (`\x00-\x1F') are all at or below space. NUL is
%% excluded because `bondy_db' separates storage-key components with it (see
%% its moduledoc), so a URI that carried NUL would cross a tenant boundary.
-define(LOOSE_CHAR(C),
    (C > $\s andalso C =/= $. andalso C =/= $# andalso C =/= 16#7F)
).

-type t() :: binary().
-type rule() ::
    loose
    | loose_prefix
    | loose_allow_empty
    | prefix
    | allow_empty
    | strict
    | strict_prefix
    | strict_allow_empty.
-type match_strategy() :: binary().

-export_type([t/0]).
-export_type([rule/0]).

-export([is_valid/1]).
-export([is_valid/2]).
-export([validate/1]).
-export([validate/2]).
-export([components/1]).
-export([match/3]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Sames as `is_valid(Uri, bondy_wamp_config:get(uri_strictness))`.
""".
-spec is_valid(uri()) -> boolean().

is_valid(Uri) ->
    is_valid(Uri, bondy_wamp_config:get(uri_strictness)).

-spec is_valid(Uri :: uri(), RuleOrStrategy :: rule() | match_strategy()) ->
    boolean() | no_return().

is_valid(Uri, Strategy) when is_binary(Strategy) ->
    is_valid(Uri, rule_for_strategy(Strategy));
is_valid(<<>>, Rule) when is_atom(Rule) ->
    loose_prefix == Rule;
is_valid(Uri, Rule) when is_binary(Uri), is_atom(Rule) ->
    scan(Uri, Rule);
is_valid(_, _) ->
    false.

-spec validate(Uri :: binary()) -> Uri :: t().

validate(Uri) ->
    maybe_error(is_valid(Uri), Uri).

-spec validate(Uri :: binary(), Arg :: rule() | match_strategy()) ->
    Uri :: t().

validate(Uri, Arg) ->
    maybe_error(is_valid(Uri, Arg), Uri).

-doc """
Matches a ground uri `Uri` with `Pattern`. `Uri` cannot be the empty
uri.
""".
-spec match(Uri :: t(), Pattern :: t(), Strategy :: match_strategy()) -> any().

match(<<>>, _, Strategy) when Strategy =/= ?PREFIX_MATCH ->
    error(badarg);
match(Uri, Uri, ?EXACT_MATCH) when
    is_binary(Uri) andalso byte_size(Uri) > 0
->
    true;
match(_, <<>>, ?PREFIX_MATCH) ->
    %% The any prefix matches everything
    true;
match(Uri, Pattern, ?PREFIX_MATCH) when
    is_binary(Uri)
->
    %% A prefix matches on a URI-component boundary, never on a raw byte
    %% prefix: `com.app.order` does not cover `com.app.orders_admin.x`.
    %% The match holds in one of three cases:
    %% - `Uri` equals `Pattern`;
    %% - `Uri` byte-starts with `Pattern` and `Pattern` ends with `.`;
    %% - `Uri` byte-starts with `Pattern` and the next byte of `Uri` is `.`.
    %% `bondy_wamp_uri_SUITE:do_match/1` checks the boundary cases.
    PS = byte_size(Pattern),
    case Uri of
        Pattern ->
            true;
        <<Pattern:PS/binary, Next, _/binary>> ->
            Next =:= $. orelse binary:last(Pattern) =:= $.;
        _ ->
            false
    end;
match(Uri, Pattern, ?WILDCARD_MATCH) when
    is_binary(Uri) andalso byte_size(Uri) > 0
->
    wildcard_component(Pattern, Uri);
match(Uri, _, _) when
    is_binary(Uri) andalso byte_size(Uri) > 0
->
    false;
match(_, _, _) ->
    error(badarg).

-doc """
Example:

```erlang
components(<<"com.mycompany.foo.bar">>) ->
[<<"com.mycompany">>, <<"foo">>, <<"bar">>].
```
""".
-spec components(t()) -> [binary()] | no_return().

components(Uri) ->
    case binary:split(Uri, <<".">>, [global]) of
        [TopLevelDomain, AppName | Rest] when length(Rest) > 0 ->
            Domain = <<TopLevelDomain/binary, $., AppName/binary>>,
            [Domain | Rest];
        _Other ->
            error({?WAMP_INVALID_URI, Uri})
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
%% Each rule is a grammar over bytes; `prop_bondy_wamp_uri:prop_scan_is_the_grammar'
%% checks the scanner against it, written as a regular expression. A rule
%% names a component class and a shape: components (`exact'), components with
%% one optional trailing `.' (`prefix'), or any run of class bytes and `.'
%% (`allow_empty').
scan(Uri, strict) ->
    strict(Uri, exact);
scan(Uri, strict_prefix) ->
    strict(Uri, prefix);
scan(Uri, strict_allow_empty) ->
    strict_any(Uri);
scan(Uri, loose) ->
    loose(Uri, exact);
scan(Uri, loose_prefix) ->
    loose(Uri, prefix);
scan(Uri, loose_allow_empty) ->
    loose_any(Uri);
scan(Uri, prefix) ->
    case bondy_wamp_config:get(uri_strictness) of
        loose -> loose(Uri, prefix);
        strict -> strict(Uri, prefix)
    end;
scan(Uri, allow_empty) ->
    case bondy_wamp_config:get(uri_strictness) of
        loose -> loose_any(Uri);
        strict -> strict_any(Uri)
    end;
scan(_, _) ->
    error(badrule).

%% @private
%% A component starts with a class byte, so an empty component fails.
strict(<<C, Rest/binary>>, Shape) when ?STRICT_CHAR(C) ->
    strict_component(Rest, Shape);
strict(_, _) ->
    false.

%% @private
strict_component(<<C, Rest/binary>>, Shape) when ?STRICT_CHAR(C) ->
    strict_component(Rest, Shape);
strict_component(<<$.>>, prefix) ->
    true;
strict_component(<<$., Rest/binary>>, Shape) ->
    strict(Rest, Shape);
strict_component(<<>>, _) ->
    true;
strict_component(_, _) ->
    false.

%% @private
strict_any(<<C, Rest/binary>>) when ?STRICT_CHAR(C) orelse C =:= $. ->
    strict_any(Rest);
strict_any(<<>>) ->
    true;
strict_any(_) ->
    false.

%% @private
loose(<<C, Rest/binary>>, Shape) when ?LOOSE_CHAR(C) ->
    loose_component(Rest, Shape);
loose(_, _) ->
    false.

%% @private
loose_component(<<C, Rest/binary>>, Shape) when ?LOOSE_CHAR(C) ->
    loose_component(Rest, Shape);
loose_component(<<$.>>, prefix) ->
    true;
loose_component(<<$., Rest/binary>>, Shape) ->
    loose(Rest, Shape);
loose_component(<<>>, _) ->
    true;
loose_component(_, _) ->
    false.

%% @private
loose_any(<<C, Rest/binary>>) when ?LOOSE_CHAR(C) orelse C =:= $. ->
    loose_any(Rest);
loose_any(<<>>) ->
    true;
loose_any(_) ->
    false.

%% @private
%% The pattern's components are compared with the URI's in order, and an empty
%% pattern component matches any one URI component, the empty one included.
%% A literal component is compared in one step: its length comes from
%% scanning the pattern alone, then the URI must start with the same bytes
%% and the same separator, one memory compare. Walking both binaries byte by
%% byte would build a sub-binary at every byte, since the compiler reuses the
%% match context of only one binary argument.
wildcard_component(<<$., Pattern/binary>>, Uri) ->
    wildcard_skip(Pattern, Uri);
wildcard_component(<<>>, Uri) ->
    wildcard_last(Uri);
wildcard_component(Pattern, Uri) ->
    Len = component_length(Pattern, 0),
    case Pattern of
        <<Component:Len/binary>> ->
            Uri =:= Component;
        <<Component:Len/binary, $., PatternRest/binary>> ->
            case Uri of
                <<Component:Len/binary, $., UriRest/binary>> ->
                    wildcard_component(PatternRest, UriRest);
                _ ->
                    false
            end
    end.

%% @private
component_length(<<$., _/binary>>, N) ->
    N;
component_length(<<_, Rest/binary>>, N) ->
    component_length(Rest, N + 1);
component_length(<<>>, N) ->
    N.

%% @private
%% An empty pattern component with more after it: skip one URI component.
wildcard_skip(Pattern, <<$., Uri/binary>>) ->
    wildcard_component(Pattern, Uri);
wildcard_skip(Pattern, <<_, Uri/binary>>) ->
    wildcard_skip(Pattern, Uri);
wildcard_skip(_, <<>>) ->
    false.

%% @private
%% An empty last pattern component: the rest of the URI is one component.
wildcard_last(<<$., _/binary>>) ->
    false;
wildcard_last(<<_, Uri/binary>>) ->
    wildcard_last(Uri);
wildcard_last(<<>>) ->
    true.

%% @private
maybe_error(true, Uri) ->
    Uri;
maybe_error(false, Uri) ->
    error({invalid_uri, Uri}).

%% @private
rule_for_strategy(Strategy) ->
    rule_for_strategy(Strategy, bondy_wamp_config:get(uri_strictness)).

%% loose | strict
rule_for_strategy(?EXACT_MATCH, Rule) -> Rule;
rule_for_strategy(?PREFIX_MATCH, loose) -> loose_prefix;
rule_for_strategy(?PREFIX_MATCH, strict) -> strict_prefix;
rule_for_strategy(?WILDCARD_MATCH, loose) -> loose_allow_empty;
rule_for_strategy(?WILDCARD_MATCH, strict) -> strict_allow_empty;
rule_for_strategy(_, _) -> error(badstrategy).
