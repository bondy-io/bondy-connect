%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_regulator_rate_limit).

-moduledoc """
Token-bucket rate limiters.

A bucket holds at most `capacity` tokens (default 20) and refills at `rate`
tokens per millisecond (default 0.005, at most 1,000,000). `allow/2` admits a
request when the bucket holds at least the requested number of tokens, and
takes them. A caller reads and updates a bucket without a process call.

`new/3` registers a bucket under a key in an ETS table that this module's
server owns. `new/2` creates a bucket that is not registered; its doc says
when to use each.

A bucket stores one integer, its theoretical arrival time (the generic cell
rate algorithm): the instant at which it would be full again, in nanoseconds of
the monotonic clock since the bucket was made. Each token taken moves it
`1 / rate` later, and `allow/2` admits a request while it stays within
`capacity / rate` of now. Nothing is rounded to whole tokens, so admission
matches a token bucket kept in exact arithmetic
(`gcra_matches_an_exact_token_bucket_test` in this module) and a caller below
the rate is never refused
(`bondy_rate_limiter_test:a_caller_below_the_rate_is_never_refused`).
`allow/2` replaces the integer with `compare_exchange` and retries when another
caller changed it first, so callers racing on one bucket spend each token once
(`bondy_rate_limiter_test:concurrent_callers_spend_each_token_once`).
""".

-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(TAB, ?MODULE).
-define(MAX_TOLERANCE, (1 bsl 62)).

-record(bondy_regulator_rate_limit, {
    key :: any(),
    algorithm :: algorithm(),
    %% Nanoseconds of refill per token, `1 / rate`.
    interval :: pos_integer(),
    %% Nanoseconds of refill a full bucket holds, `capacity / rate`.
    tolerance :: pos_integer(),
    %% Monotonic nanosecond the arrival time counts from.
    epoch :: integer(),
    atomics :: atomics:atomics_ref()
}).

-type t() :: #?MODULE{}.
-type key() :: any().
-type algorithm() :: token_bucket.
-type opts() :: #{
    capacity => pos_integer(),
    rate => number()
}.
-type info() :: #{
    remaining := number(),
    resets_in := pos_integer()
}.

-export_type([t/0]).

%% API
-export([new/2]).
-export([new/3]).
-export([delete/1]).
-export([allow/2]).
-export([wait/2]).
-export([reset/1]).
-export([peek/1]).

-export([start_link/0]).

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).

%% =============================================================================
%% API
%% =============================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Creates a bucket that is NOT registered in the module's table: it has no key,
and the caller's reference to the returned term is the only thing keeping its
atomics array alive.

Use this for a bucket a single owner holds in its own state and passes to
`allow/2` directly — a per-session or per-connection limiter. Such a bucket is
never looked up by key, so registering it buys nothing and costs a row that
only the owner can ever free: if the owner dies without running its teardown,
the row is unreachable for good, because its key is not derivable from
anything. Unregistered, the array is freed by the VM when the owner's
reference goes, and there is no teardown to forget.

Use `new/3` only when some OTHER process must find the bucket by key — the
shared node / listener / realm buckets `m:bondy_rate_limiter` owns and reaps
with its own idle-TTL sweep.
""".
-spec new(Algo :: algorithm(), Options :: opts()) ->
    {ok, t()} | {error, Reason :: any()}.

new(Algo, Opts) ->
    case make(Algo, undefined, Opts) of
        #?MODULE{} = T ->
            ok = reset(T),
            {ok, T};
        {error, _} = Error ->
            Error
    end.

-doc """
Creates a bucket registered in the module's table under `Key`, so that it can
be found with `allow/2`, `peek/1` or `reset/1` given the key alone. The row is
the caller's to remove with `delete/1`.

For an owner-held bucket that nobody looks up by key, use `new/2` instead — see
why there.
""".
-spec new(Algo :: algorithm(), Key :: key(), Options :: opts()) ->
    {ok, t()} | {error, Reason :: any()}.

new(Algo, Key, Opts) ->
    case make(Algo, Key, Opts) of
        #?MODULE{} = T ->
            store(T);
        {error, _} = Error ->
            Error
    end.

%% @private
make(token_bucket = Algo, Key, Opts) when is_map(Opts) ->
    Ref = atomics:new(1, [{signed, false}]),
    %% Default = 5 reqs / second
    Rate = maps:get(rate, Opts, 5 / 1_000),
    %% Burst up
    Capacity = maps:get(capacity, Opts, 20),

    is_number(Rate) andalso Rate > 0 andalso Rate =< 1_000_000 orelse
        error(
            badarg,
            [Algo, Key, Opts],
            [
                {error_info, #{
                    cause => #{
                        3 =>
                            "rate should be a positive number of at most 1000000"
                    }
                }}
            ]
        ),

    Interval = round(1.0e6 / Rate),

    is_integer(Capacity) andalso Capacity > 0 andalso
        Capacity * Interval =< ?MAX_TOLERANCE orelse
        error(
            badarg,
            [Algo, Key, Opts],
            [
                {error_info, #{
                    cause => #{
                        3 =>
                            "capacity should be a positive integer, and "
                            "capacity / rate at most 2^62 nanoseconds"
                    }
                }}
            ]
        ),

    #?MODULE{
        key = Key,
        algorithm = token_bucket,
        interval = Interval,
        tolerance = Capacity * Interval,
        epoch = erlang:monotonic_time(nanosecond),
        atomics = Ref
    };
make(Algo, Key, Opts) ->
    %% Only support token_bucket for the time being
    error(
        badarg,
        [Algo, Key, Opts],
        [{error_info, #{cause => #{1 => "algorithm not supported"}}}]
    ).

-doc """
Takes `Increment` tokens from the bucket, after refilling it for the time
since its last refill.

Returns `{true, Info}` when the bucket held enough tokens. `Info` gives the
tokens left in `remaining`, and in `resets_in` the milliseconds until another
`Increment` fits, or `0` when one fits now. Returns `{false, Info}`, with
`remaining` `0`, when it did not; the bucket is then left unchanged.

Given a key, fails with `badarg` when no bucket is registered under it.
""".
-spec allow(key() | t(), Increment :: pos_integer()) ->
    {true, info()} | {false, info()} | no_return().

allow(#?MODULE{} = T, Increment) when
    is_integer(Increment) andalso Increment > 0
->
    try_take(T, Increment, atomics:get(T#?MODULE.atomics, 1), elapsed(T));
allow(Key, Increment) when is_integer(Increment) andalso Increment > 0 ->
    allow(fetch(Key), Increment).

-doc """
As `allow/2`, but on refusal the caller sleeps for `resets_in` milliseconds
and tries once more, returning the result of that second attempt.
""".
-spec wait(key() | t(), Increment :: pos_integer()) ->
    {true, info()} | {false, info()} | no_return().

wait(Term, Increment) ->
    case allow(Term, Increment) of
        {true, _} = Result ->
            Result;
        {false, #{resets_in := Millis}} ->
            timer:sleep(Millis),
            allow(Term, Increment)
    end.

-doc """
Returns the bucket's token count, refilled to now, without taking a token.
`resets_in` is the milliseconds until one token is available.

Given a key, fails with `badarg` when no bucket is registered under it.
""".
-spec peek(key() | t()) -> info() | no_return().

peek(#?MODULE{interval = Interval, tolerance = Tolerance} = T) ->
    Used = max(atomics:get(T#?MODULE.atomics, 1) - elapsed(T), 0),
    #{
        remaining => (Tolerance - Used) div Interval,
        resets_in => to_millis(Used + Interval - Tolerance)
    };
peek(Key) ->
    peek(fetch(Key)).

-doc """
Removes a registered bucket from the table. A bucket created with `new/2`
has no row, so deleting it does nothing.
""".
-spec delete(key() | t()) -> ok.

delete(#?MODULE{key = undefined}) ->
    ok;
delete(#?MODULE{} = T) ->
    delete(T#?MODULE.key);
delete(Key) ->
    ets:delete(?TAB, Key),
    ok.

-doc """
Fails with `badarg` exception if the limit doesn't exist.
""".
-spec reset(key() | t()) -> ok | no_return().

reset(#?MODULE{algorithm = token_bucket} = T) ->
    atomics:put(T#?MODULE.atomics, 1, elapsed(T));
reset(Key) ->
    reset(fetch(Key)).

%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================

%% The server exists to OWN `?TAB`: the registered buckets outlive any
%% individual caller, so the table must not be owned by one.
%% It runs no reaper. A sweep that deletes rows whose `atomics:get/2` raises
%% `badarg` reclaims nothing: the row holds a reference to the array, which
%% keeps it alive, so the read always succeeds. Registered buckets are reaped
%% by their owner, `m:bondy_rate_limiter`, which sweeps its own on an idle
%% TTL and calls `delete/1`. Owner-held buckets are built with `new/2` and
%% are not in the table at all.
init(_) ->
    ?TAB = ets:new(?TAB, [
        named_table,
        ordered_set,
        {keypos, 2},
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, #{}}.

handle_call(_, _, State) ->
    {reply, ok, State}.

handle_cast(_Event, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

store(#?MODULE{} = T) ->
    case ets:insert_new(?TAB, T) of
        true ->
            ok = reset(T),
            {ok, T};
        false ->
            %% Ref will be GC'ed
            {error, already_exists}
    end.

fetch(Key) ->
    case ets:lookup(?TAB, Key) of
        [#?MODULE{} = T] ->
            T;
        [] ->
            error(badarg)
    end.

%% A refusal writes nothing, so the refill keeps accruing.
try_take(T, Increment, Tat, Now) ->
    #?MODULE{interval = Interval, tolerance = Tolerance} = T,
    New = max(Tat, Now) + Increment * Interval,
    case New - Now =< Tolerance of
        true ->
            case atomics:compare_exchange(T#?MODULE.atomics, 1, Tat, New) of
                ok ->
                    {true, #{
                        remaining => (Tolerance - (New - Now)) div Interval,
                        resets_in => to_millis(
                            New + Increment * Interval - Tolerance - Now
                        )
                    }};
                Current ->
                    try_take(T, Increment, Current, elapsed(T))
            end;
        false ->
            {false, #{
                remaining => 0,
                resets_in => to_millis(New - Tolerance - Now)
            }}
    end.

elapsed(#?MODULE{epoch = Epoch}) ->
    erlang:monotonic_time(nanosecond) - Epoch.

to_millis(Nanos) when Nanos =< 0 ->
    0;
to_millis(Nanos) ->
    (Nanos + 999_999) div 1_000_000.

%% =============================================================================
%% EUNIT
%% =============================================================================

-ifdef(TEST).

token_bucket_test() ->
    {ok, Pid} = start_link(),
    try
        %% 1 req/sec without bursting
        {ok, T} = new(token_bucket, foo, #{capacity => 1, rate => 1 / 1000}),
        ?assertMatch({true, #{}}, allow(T, 1)),
        ?assertMatch({false, #{}}, allow(T, 1)),
        ?assertMatch({true, #{}}, wait(T, 1)),
        {false, Info} = allow(T, 1),
        ?assertEqual(Info, peek(T))
    after
        %% The server is REGISTERED: leaving it running orphans the name
        %% outside any supervision tree, and every later fixture's
        %% `application:ensure_all_started(bondy_regulator)` then fails
        %% with `{already_started, _}` on the sup child.
        unlink(Pid),
        gen_server:stop(Pid)
    end.

%% The exact bucket counts tokens as nanoseconds of refill, so it rounds
%% nothing. Random gaps and increments must get the same decisions.
gcra_matches_an_exact_token_bucket_test() ->
    _ = rand:seed(exsss, {17, 23, 31}),
    [
        exact_bucket_run(rand:uniform(5), rand:uniform(7) * 1_000)
     || _ <- lists:seq(1, 500)
    ].

exact_bucket_run(Capacity, Interval) ->
    T = #?MODULE{
        key = undefined,
        algorithm = token_bucket,
        interval = Interval,
        tolerance = Capacity * Interval,
        epoch = 0,
        atomics = atomics:new(1, [{signed, false}])
    },
    exact_bucket_run(T, 40, 0, Capacity * Interval).

exact_bucket_run(_, 0, _, _) ->
    ok;
exact_bucket_run(T, Steps, Now0, Level0) ->
    #?MODULE{interval = Interval, tolerance = Tolerance} = T,
    Now = Now0 + rand:uniform(3 * Interval) - 1,
    Increment = rand:uniform(3),
    Level1 = min(Tolerance, Level0 + Now - Now0),
    {Expected, Level} =
        case Level1 >= Increment * Interval of
            true ->
                Left = Level1 - Increment * Interval,
                {{true, Left div Interval}, Left};
            false ->
                {{false, 0}, Level1}
        end,
    {Admitted, #{remaining := Remaining}} =
        try_take(T, Increment, atomics:get(T#?MODULE.atomics, 1), Now),
    ?assertEqual(Expected, {Admitted, Remaining}),
    exact_bucket_run(T, Steps - 1, Now, Level).

-endif.
