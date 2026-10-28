%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_rate_limiter_test).
-moduledoc "The keyed, GC'd token-bucket rate limiter.".

-include_lib("eunit/include/eunit.hrl").

-define(M, bondy_rate_limiter).
%% Near-zero refill so the bucket does not top up within a test — `capacity`
%% is the deterministic burst size.
-define(OPTS(Cap), #{rate => 0.00001, capacity => Cap}).

rate_limiter_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun allow_within_capacity/0,
        fun deny_over_capacity/0,
        fun reuses_bucket_per_key/0,
        fun distinct_keys_independent/0,
        fun forget_resets/0,
        fun gc_sweeps_idle/0,
        fun a_non_positive_increment_is_refused/0,
        {timeout, 60, fun concurrent_callers_spend_each_token_once/0},
        {timeout, 30, fun a_caller_below_the_rate_is_never_refused/0}
    ]}.

setup() ->
    %% Start the shared `bondy_regulator` APP rather than its registered
    %% gen_servers directly: `ensure_all_started/1` is idempotent, the
    %% supervisor owns the children, and the app staying up serves every
    %% sibling. A direct `start_link/0` leaves an UNSUPERVISED registered
    %% orphan behind, and a later fixture's
    %% `application:start(bondy_regulator)` then fails with
    %% `{already_started, _}` on the sup child.
    {ok, _} = application:ensure_all_started(bondy_regulator),
    ok.

cleanup(_) ->
    %% Deliberately NOT stopping the shared app: siblings and later
    %% fixtures keep using it, and `ensure_all_started/1` makes every
    %% setup idempotent against it running.
    ok.

key(Name) ->
    {test, Name, erlang:unique_integer([positive])}.

allow_within_capacity() ->
    K = key(within),
    ?assert(?M:allow(K, ?OPTS(3))),
    ?assert(?M:allow(K, ?OPTS(3))),
    ?assert(?M:allow(K, ?OPTS(3))).

deny_over_capacity() ->
    K = key(over),
    ?assert(?M:allow(K, ?OPTS(2))),
    ?assert(?M:allow(K, ?OPTS(2))),
    ?assertNot(?M:allow(K, ?OPTS(2))).

reuses_bucket_per_key() ->
    %% Repeated calls with the same key deplete the SAME bucket.
    K = key(reuse),
    [?assert(?M:allow(K, ?OPTS(5))) || _ <- lists:seq(1, 5)],
    ?assertNot(?M:allow(K, ?OPTS(5))).

distinct_keys_independent() ->
    K1 = key(indep_a),
    K2 = key(indep_b),
    ?assert(?M:allow(K1, ?OPTS(1))),
    ?assertNot(?M:allow(K1, ?OPTS(1))),
    %% A different key has its own bucket.
    ?assert(?M:allow(K2, ?OPTS(1))).

forget_resets() ->
    K = key(forget),
    ?assert(?M:allow(K, ?OPTS(1))),
    ?assertNot(?M:allow(K, ?OPTS(1))),
    ?assertMatch([_], regulator_rows(K)),
    ok = ?M:forget(K),
    %% Both the registry row and the regulator bucket are gone.
    ?assertEqual([], ets:lookup(bondy_rate_limiter, K)),
    ?assertEqual([], regulator_rows(K)),
    %% A fresh bucket is minted after forget.
    ?assert(?M:allow(K, ?OPTS(1))).

gc_sweeps_idle() ->
    K = key(gc),
    ?assert(?M:allow(K, ?OPTS(1))),
    ?assertMatch([_], ets:lookup(bondy_rate_limiter, K)),
    %% Age the entry past any TTL and drive a sweep cycle directly.
    true = ets:update_element(bondy_rate_limiter, K, {3, 0}),
    bondy_rate_limiter ! sweep,
    ok = wait_gone(bondy_rate_limiter, K, 50),
    ?assertEqual([], ets:lookup(bondy_rate_limiter, K)),
    ?assertEqual([], regulator_rows(K)).

%% The regulator bucket is registered under `{bondy_rate_limiter, Key}`.
regulator_rows(K) ->
    ets:lookup(bondy_regulator_rate_limit, {bondy_rate_limiter, K}).

wait_gone(_Tab, _K, 0) ->
    {error, still_present};
wait_gone(Tab, K, N) ->
    case ets:lookup(Tab, K) of
        [] ->
            ok;
        _ ->
            timer:sleep(20),
            wait_gone(Tab, K, N - 1)
    end.

%% A negative increment would subtract a negative, refilling the bucket past
%% its capacity.
a_non_positive_increment_is_refused() ->
    {ok, T} = bondy_regulator_rate_limit:new(token_bucket, ?OPTS(2)),
    [
        ?assertError(
            function_clause, bondy_regulator_rate_limit:allow(T, I)
        )
     || I <- [-5, 0]
    ],
    ?assertMatch(
        {true, #{remaining := 1}}, bondy_regulator_rate_limit:allow(T, 1)
    ).

%% Callers released together on one bucket: each token is spent by exactly one
%% of them, so the bucket admits its capacity and no more. Rounds repeat the
%% race because a single round need not interleave.
concurrent_callers_spend_each_token_once() ->
    Capacity = 50,
    [
        begin
            {ok, T} = bondy_regulator_rate_limit:new(
                token_bucket, ?OPTS(Capacity)
            ),
            ?assertEqual(Capacity, admitted_concurrently(T, 64, 10))
        end
     || _ <- lists:seq(1, 20)
    ].

%% 4.5 calls a second against a bucket refilling 5 a second, with gaps that
%% each add a fraction of a token. Sleeping late only adds refill.
a_caller_below_the_rate_is_never_refused() ->
    {ok, T} = bondy_regulator_rate_limit:new(
        token_bucket, #{rate => 5 / 1000, capacity => 2}
    ),
    Admitted = [
        begin
            timer:sleep(Gap),
            element(1, bondy_regulator_rate_limit:allow(T, 1))
        end
     || Gap <- lists:append(lists:duplicate(10, [150, 290]))
    ],
    ?assertEqual(lists:duplicate(20, true), Admitted).

admitted_concurrently(T, Callers, Calls) ->
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            receive
                go -> ok
            end,
            Admitted = length([
                ok
             || _ <- lists:seq(1, Calls),
                element(1, bondy_regulator_rate_limit:allow(T, 1)) =:= true
            ]),
            Self ! {admitted, self(), Admitted}
        end)
     || _ <- lists:seq(1, Callers)
    ],
    [Pid ! go || Pid <- Pids],
    lists:sum([
        receive
            {admitted, Pid, N} -> N
        end
     || Pid <- Pids
    ]).
