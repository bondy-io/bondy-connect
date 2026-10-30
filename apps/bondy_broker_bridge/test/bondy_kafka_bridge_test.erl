%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_kafka_bridge_test).

-include_lib("eunit/include/eunit.hrl").

%% brod reads `required_acks` as 0 = no ack, 1 = the leader only and -1 = every
%% in-sync replica (`brod_producer`), so each alias has to name that number.
required_acks_alias_test_() ->
    [
        {binary_to_list(Alias), ?_assertEqual(Expected, required_acks(Alias))}
     || {Alias, Expected} <- [
            {~"all", -1},
            {~"leader", 1},
            {~"none", 0}
        ]
    ].

required_acks_integer_test_() ->
    [?_assertEqual(N, required_acks(N)) || N <- [-1, 0, 1]].

required_acks(Value) ->
    {ok, #{~"options" := #{~"required_acks" := Acks}}} =
        bondy_kafka_bridge:validate_action(
            action(~"v", #{~"required_acks" => Value})
        ),
    Acks.

a_partitioner_value_the_hash_cannot_take_is_invalid_test() ->
    Partitioner = #{~"algorithm" => ~"fnv32a", ~"value" => #{~"a" => 1}},
    ?assertMatch(
        {error, #{code := invalid_value}},
        bondy_kafka_bridge:validate_action(
            action(~"v", #{~"partitioner" => Partitioner})
        )
    ).

a_fault_other_than_an_invalid_action_is_raised_test() ->
    ?assertError({badmap, _}, bondy_kafka_bridge:validate_action(not_a_map)).

a_value_the_encoding_cannot_take_is_an_error_test() ->
    {ok, Action} = bondy_kafka_bridge:validate_action(action(<<255>>, #{})),
    ?assertEqual(
        {error, {invalid_byte, 255}}, bondy_kafka_bridge:apply_action(Action)
    ).

action(Value, Opts) ->
    #{
        ~"topic" => ~"t",
        ~"key" => ~"k",
        ~"value" => Value,
        ~"options" => maps:merge(
            #{
                ~"client_id" => ~"default",
                ~"encoding" => ~"json",
                ~"partitioner" => #{
                    ~"algorithm" => ~"random", ~"value" => null
                }
            },
            Opts
        )
    }.
