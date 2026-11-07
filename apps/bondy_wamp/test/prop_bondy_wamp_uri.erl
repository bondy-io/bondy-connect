%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(prop_bondy_wamp_uri).
-moduledoc """
Property-based tests for `bondy_wamp_uri`: URI validation under the loose and
strict rules, matching, and `components/1`.

The generators follow the WAMP URI grammar. A URI is one or more components
separated by single dots. A strict component holds lower-case letters, digits
and `_`. A loose component holds any byte except `.`, `#`, DEL (0x7F) and the
bytes from 0x00 to 0x20. Each rule combines a class with a shape: components
(`exact`), components with one optional trailing dot (`prefix`), or any run of
class bytes and dots (`allow_empty`, for wildcard patterns).

Valid URIs come from the grammar; invalid ones are a valid URI with exactly
one defect, so a rejection is attributable to that defect.
""".

-include_lib("proper/include/proper.hrl").
-include("bondy_wamp.hrl").

%% Validation
-export([prop_valid_strict_uri_accepted/0]).
-export([prop_valid_loose_uri_accepted/0]).
-export([prop_strict_is_a_subset_of_loose/0]).
-export([prop_a_forbidden_byte_is_rejected/0]).
-export([prop_strict_rejects_a_loose_only_byte/0]).
-export([prop_an_empty_component_needs_allow_empty/0]).
-export([prop_a_trailing_dot_needs_prefix_or_allow_empty/0]).
-export([prop_empty_uri_only_loose_prefix/0]).
-export([prop_validate_agrees_with_is_valid/0]).
-export([prop_scan_is_the_grammar/0]).
%% Matching
-export([prop_exact_match_reflexive/0]).
-export([prop_prefix_match_reflexive/0]).
-export([prop_wildcard_match_reflexive/0]).
-export([prop_prefix_match_empty_pattern/0]).
-export([prop_wildcard_match_is_componentwise/0]).
%% Components
-export([prop_components_valid_uri/0]).
-export([prop_components_reconstructable/0]).

-define(NUMTESTS, 5000).

%% =============================================================================
%% GENERATORS: BYTES
%% =============================================================================

strict_byte() ->
    frequency([{26, range($a, $z)}, {10, range($0, $9)}, {2, $_}]).

%% In the loose class and outside the strict one: upper case, ASCII
%% punctuation other than `.' and `#', and bytes above 0x7F.
loose_only_byte() ->
    frequency([
        {3, range($A, $Z)},
        {3,
            oneof(
                (lists:seq(16#21, 16#2F) -- [$#, $.]) ++ lists:seq($:, $@) ++
                    "[\\]^`{|}~"
            )},
        {2, range(16#80, 16#FF)}
    ]).

loose_byte() ->
    frequency([{3, strict_byte()}, {2, loose_only_byte()}]).

%% Outside every class, and not the separator: the bytes from 0x00 to 0x20
%% (whitespace and control characters, NUL and newline among them), `#' and
%% DEL.
forbidden_byte() ->
    frequency([
        {4, range(0, 16#20)},
        {2, oneof([0, $\n, $\s, $\t, $\r])},
        {1, $#},
        {1, 16#7F}
    ]).

%% =============================================================================
%% GENERATORS: URIS
%% =============================================================================

%% Mostly short, sometimes long enough to span several words.
component(Byte) ->
    ?LET(
        N,
        frequency([{8, range(1, 8)}, {2, range(9, 24)}]),
        ?LET(Bytes, vector(N, Byte), list_to_binary(Bytes))
    ).

uri(Byte) ->
    ?LET(
        N,
        range(1, 8),
        ?LET(Cs, vector(N, component(Byte)), join(Cs))
    ).

prefix_uri(Byte) ->
    ?LET(
        {Uri, Dot},
        {uri(Byte), boolean()},
        case Dot of
            true -> <<Uri/binary, ".">>;
            false -> Uri
        end
    ).

%% A wildcard pattern: components, some of them empty. Never the empty URI,
%% which only `loose_prefix' accepts.
wildcard_pattern(Byte) ->
    ?SUCHTHAT(
        P,
        ?LET(
            N,
            range(1, 8),
            ?LET(
                Cs,
                vector(N, frequency([{3, component(Byte)}, {1, <<>>}])),
                join(Cs)
            )
        ),
        P =/= <<>>
    ).

%% A valid input for each class and shape.
valid(Class, exact) -> uri(class_byte(Class));
valid(Class, prefix) -> prefix_uri(class_byte(Class));
valid(Class, allow_empty) -> wildcard_pattern(class_byte(Class)).

class_byte(strict) -> strict_byte();
class_byte(loose) -> loose_byte().

shape() ->
    oneof([exact, prefix, allow_empty]).

class() ->
    oneof([strict, loose]).

rule() ->
    oneof(rules()).

rules() ->
    [
        strict,
        strict_prefix,
        strict_allow_empty,
        loose,
        loose_prefix,
        loose_allow_empty
    ].

rule(strict, exact) -> strict;
rule(strict, prefix) -> strict_prefix;
rule(strict, allow_empty) -> strict_allow_empty;
rule(loose, exact) -> loose;
rule(loose, prefix) -> loose_prefix;
rule(loose, allow_empty) -> loose_allow_empty.

%% `Bin' with `Byte' inserted at a position from the start to the end.
insert_byte(Bin, ByteGen) ->
    ?LET(
        {Pos, Byte},
        {range(0, byte_size(Bin)), ByteGen},
        begin
            <<H:Pos/binary, T/binary>> = Bin,
            <<H/binary, Byte, T/binary>>
        end
    ).

%% A URI with one empty component: a leading dot, a doubled dot, or a doubled
%% trailing dot.
with_empty_component(Uri) ->
    Doubled =
        case binary:matches(Uri, <<".">>) of
            [] ->
                [];
            Dots ->
                [
                    ?LET(
                        {Pos, _},
                        oneof(Dots),
                        begin
                            <<H:Pos/binary, T/binary>> = Uri,
                            <<H/binary, ".", T/binary>>
                        end
                    )
                ]
        end,
    oneof([<<".", Uri/binary>>, <<Uri/binary, "..">> | Doubled]).

join(Components) ->
    iolist_to_binary(lists:join(<<".">>, Components)).

%% Any input at all: valid for some class and shape, one defect away from
%% valid, or arbitrary bytes.
any_input() ->
    frequency([
        {3, ?LET({C, S}, {class(), shape()}, valid(C, S))},
        {2,
            ?LET(
                {C, S},
                {class(), shape()},
                ?LET(U, valid(C, S), insert_byte(U, forbidden_byte()))
            )},
        {1, ?LET(U, uri(strict_byte()), insert_byte(U, loose_only_byte()))},
        {1, ?LET(U, uri(loose_byte()), with_empty_component(U))},
        {1, ?LET(L, list(range(0, 255)), list_to_binary(L))}
    ]).

%% =============================================================================
%% PROPERTIES: VALIDATION
%% =============================================================================

%% Every URI the strict grammar generates is valid under the strict rule of
%% its shape.
prop_valid_strict_uri_accepted() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Shape, Uri},
            ?LET(S, shape(), {S, valid(strict, S)}),
            bondy_wamp_uri:is_valid(Uri, rule(strict, Shape))
        )
    ).

%% Every URI the loose grammar generates is valid under the loose rule of its
%% shape.
prop_valid_loose_uri_accepted() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Shape, Uri},
            ?LET(S, shape(), {S, valid(loose, S)}),
            bondy_wamp_uri:is_valid(Uri, rule(loose, Shape))
        )
    ).

%% The strict class is part of the loose class, so a strict URI is also a
%% loose URI of the same shape.
prop_strict_is_a_subset_of_loose() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Shape, Uri},
            ?LET(S, shape(), {S, valid(strict, S)}),
            bondy_wamp_uri:is_valid(Uri, rule(loose, Shape))
        )
    ).

%% One byte outside every class, at any position including the first and the
%% last, makes a URI invalid under every rule. A newline at the end is one
%% such case.
prop_a_forbidden_byte_is_rejected() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            Uri,
            ?LET(
                {C, S},
                {class(), shape()},
                ?LET(U, valid(C, S), insert_byte(U, forbidden_byte()))
            ),
            lists:all(
                fun(R) -> not bondy_wamp_uri:is_valid(Uri, R) end, rules()
            )
        )
    ).

%% A loose-only byte in a strict URI leaves it valid under the loose rules
%% and invalid under the strict ones.
prop_strict_rejects_a_loose_only_byte() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            Uri,
            ?LET(U, uri(strict_byte()), insert_byte(U, loose_only_byte())),
            lists:all(fun(R) -> bondy_wamp_uri:is_valid(Uri, R) end, [
                loose, loose_prefix, loose_allow_empty
            ]) andalso
                lists:all(fun(R) -> not bondy_wamp_uri:is_valid(Uri, R) end, [
                    strict, strict_prefix, strict_allow_empty
                ])
        )
    ).

%% An empty component is valid only where empty components are allowed.
prop_an_empty_component_needs_allow_empty() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Class, Uri},
            ?LET(
                C,
                class(),
                {C, ?LET(U, uri(class_byte(C)), with_empty_component(U))}
            ),
            not bondy_wamp_uri:is_valid(Uri, rule(Class, exact)) andalso
                not bondy_wamp_uri:is_valid(Uri, rule(Class, prefix)) andalso
                bondy_wamp_uri:is_valid(Uri, rule(Class, allow_empty))
        )
    ).

%% A single trailing dot is valid for a prefix or a wildcard pattern and
%% invalid for an exact URI.
prop_a_trailing_dot_needs_prefix_or_allow_empty() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Class, Uri},
            ?LET(
                C, class(), {C, ?LET(U, uri(class_byte(C)), <<U/binary, ".">>)}
            ),
            not bondy_wamp_uri:is_valid(Uri, rule(Class, exact)) andalso
                bondy_wamp_uri:is_valid(Uri, rule(Class, prefix)) andalso
                bondy_wamp_uri:is_valid(Uri, rule(Class, allow_empty))
        )
    ).

%% The empty URI is valid only as a loose prefix, the prefix of every URI.
prop_empty_uri_only_loose_prefix() ->
    ?FORALL(
        Rule,
        rule(),
        bondy_wamp_uri:is_valid(<<>>, Rule) =:= (Rule =:= loose_prefix)
    ).

%% `validate/2' returns the URI that `is_valid/2' accepts and raises for the
%% one it rejects.
prop_validate_agrees_with_is_valid() ->
    numtests(
        ?NUMTESTS,
        ?FORALL(
            {Rule, Uri},
            {rule(), any_input()},
            case bondy_wamp_uri:is_valid(Uri, Rule) of
                true ->
                    bondy_wamp_uri:validate(Uri, Rule) =:= Uri;
                false ->
                    try bondy_wamp_uri:validate(Uri, Rule) of
                        _ -> false
                    catch
                        error:{invalid_uri, Uri} -> true
                    end
            end
        )
    ).

%% `is_valid/2' accepts exactly what each rule's grammar accepts, with the
%% grammar written as the regular expression it is easiest to read as. The
%% expression is compiled with `dollar_endonly' so that `$' means end of
%% input: without it, PCRE's `$' also matches before a final newline.
prop_scan_is_the_grammar() ->
    numtests(
        20000,
        ?FORALL(
            {Rule, Uri},
            {rule(), any_input()},
            bondy_wamp_uri:is_valid(Uri, Rule) =:= grammar_accepts(Uri, Rule)
        )
    ).

grammar_accepts(<<>>, Rule) ->
    loose_prefix == Rule;
grammar_accepts(Uri, Rule) ->
    {ok, MP} = re:compile(grammar(Rule), [dollar_endonly]),
    re:run(Uri, MP) =/= nomatch.

-define(LOOSE_CLASS, "[^\\s\\.#\\x00-\\x1F\\x7F]").
-define(STRICT_CLASS, "[0-9a-z_]").

grammar(loose) ->
    "^(" ?LOOSE_CLASS "+\\.)*(" ?LOOSE_CLASS "+)$";
grammar(loose_prefix) ->
    "^(" ?LOOSE_CLASS "+\\.)*(" ?LOOSE_CLASS "+)[.]?$";
grammar(loose_allow_empty) ->
    "^((" ?LOOSE_CLASS "+\\.)|\\.)*(" ?LOOSE_CLASS "+)?$";
grammar(strict) ->
    "^(" ?STRICT_CLASS "+\\.)*(" ?STRICT_CLASS "+)$";
grammar(strict_prefix) ->
    "^(" ?STRICT_CLASS "+\\.)*(" ?STRICT_CLASS "+)[.]?$";
grammar(strict_allow_empty) ->
    "^((" ?STRICT_CLASS "+\\.)|\\.)*(" ?STRICT_CLASS "+)?$".

%% =============================================================================
%% PROPERTIES: MATCHING
%% =============================================================================

prop_exact_match_reflexive() ->
    ?FORALL(
        Uri, uri(loose_byte()), bondy_wamp_uri:match(Uri, Uri, ?EXACT_MATCH)
    ).

prop_prefix_match_reflexive() ->
    ?FORALL(
        Uri, uri(loose_byte()), bondy_wamp_uri:match(Uri, Uri, ?PREFIX_MATCH)
    ).

prop_wildcard_match_reflexive() ->
    ?FORALL(
        Uri, uri(loose_byte()), bondy_wamp_uri:match(Uri, Uri, ?WILDCARD_MATCH)
    ).

%% The empty prefix matches every URI.
prop_prefix_match_empty_pattern() ->
    ?FORALL(
        Uri, uri(loose_byte()), bondy_wamp_uri:match(Uri, <<>>, ?PREFIX_MATCH)
    ).

%% `match(Uri, Pattern, wildcard)' holds exactly when both have the same
%% number of components and each pattern component is empty or equal to the
%% URI's. Half the URIs are drawn from the pattern: its empty components
%% filled, and sometimes one byte changed, so matches and near misses are
%% common, not only unrelated pairs.
prop_wildcard_match_is_componentwise() ->
    numtests(
        20000,
        ?FORALL(
            {Pattern, Uri},
            ?LET(
                {Byte, P},
                ?LET(C, class(), {
                    class_byte(C), wildcard_pattern(class_byte(C))
                }),
                {P, oneof([uri(Byte), from_pattern(P, Byte)])}
            ),
            bondy_wamp_uri:match(Uri, Pattern, ?WILDCARD_MATCH) =:=
                componentwise(
                    binary:split(Pattern, <<".">>, [global]),
                    binary:split(Uri, <<".">>, [global])
                )
        )
    ).

componentwise([], []) -> true;
componentwise([<<>> | P], [_ | U]) -> componentwise(P, U);
componentwise([C | P], [C | U]) -> componentwise(P, U);
componentwise(_, _) -> false.

%% The pattern with each empty component filled, and sometimes one byte
%% replaced by another class byte.
from_pattern(Pattern, Byte) ->
    ?LET(
        Filled,
        ?LET(
            Cs,
            [
                case C of
                    <<>> -> component(Byte);
                    _ -> C
                end
             || C <- binary:split(Pattern, <<".">>, [global])
            ],
            join(Cs)
        ),
        oneof([Filled, replace_one_byte(Filled, Byte)])
    ).

replace_one_byte(Bin, Byte) ->
    ?LET(
        {I, New},
        {range(0, byte_size(Bin) - 1), Byte},
        begin
            <<H:I/binary, Old, T/binary>> = Bin,
            case Old of
                $. -> Bin;
                _ -> <<H/binary, New, T/binary>>
            end
        end
    ).

%% =============================================================================
%% PROPERTIES: COMPONENTS
%% =============================================================================

three_or_more_components() ->
    ?LET(N, range(3, 6), vector(N, component(loose_byte()))).

%% A URI of three or more components splits into the domain (the first two
%% components) followed by each remaining component.
prop_components_valid_uri() ->
    ?FORALL(
        Components,
        three_or_more_components(),
        length(bondy_wamp_uri:components(join(Components))) =:=
            length(Components) - 1
    ).

prop_components_reconstructable() ->
    ?FORALL(
        Components,
        three_or_more_components(),
        begin
            [Domain | Rest] = bondy_wamp_uri:components(join(Components)),
            [First, Second | Tail] = Components,
            Domain =:= <<First/binary, ".", Second/binary>> andalso
                Rest =:= Tail
        end
    ).
