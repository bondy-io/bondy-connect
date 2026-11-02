%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_realm_cluster_SUITE).
-moduledoc """
Realm deletion across a 3-node cluster: node-local state a node holds for a
realm goes when the realm is deleted on another node.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("oidcc/include/oidcc_provider_configuration.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([oidc_provider_workers_stop_with_their_realm/1]).
-export([do_mock_provider_metadata/0]).
-export([do_start_provider_worker/2]).
-export([do_provider_workers/0]).
-export([do_unmock_provider_metadata/0]).

-define(NODE_NAMES, [realmc1, realmc2, realmc3]).
-define(PROVIDER, ~"idp").
-define(AWAIT_MS, 60000).

all() ->
    [oidc_provider_workers_stop_with_their_realm].

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config) ->
    Nodes = bondy_ct:start_cluster(?NODE_NAMES, Config),
    _ = [push_module(Node) || {_, Node, _} <- Nodes],
    [{cluster, Nodes} | Config].

end_per_suite(Config) ->
    ok = bondy_ct:stop_cluster(?config(cluster, Config)),
    Config.

%% =============================================================================
%% CASES
%% =============================================================================

%% Each node starts its own provider worker; the realm is deleted on node 1.
%% Nodes 2 and 3 learn of the deletion only through replication. Covers a
%% connected cluster; it does not cover a node cut off during the deletion.
oidc_provider_workers_stop_with_their_realm(Config) ->
    Nodes = [N1 | _] = [N || {_, N, _} <- ?config(cluster, Config)],
    Uri = ~"com.example.realmc.oidc",
    ok = lists:foreach(
        fun(N) -> ok = erpc:call(N, ?MODULE, do_mock_provider_metadata, []) end,
        Nodes
    ),
    try
        _ = erpc:call(N1, bondy_realm, create, [realm(Uri)]),
        Started = [
            {N, await(N, fun() -> start_provider_worker(N, Uri) end)}
         || N <- Nodes
        ],
        ?assertEqual([{N, 1} || N <- Nodes], Started),
        ok = erpc:call(N1, bondy_realm, delete, [Uri]),
        Left = [
            {N, await(N, fun() -> provider_workers(N) =:= 0 end)}
         || N <- Nodes
        ],
        ?assertEqual([{N, 0} || N <- Nodes], Left)
    after
        lists:foreach(
            fun(N) ->
                ok = erpc:call(N, ?MODULE, do_unmock_provider_metadata, [])
            end,
            Nodes
        )
    end.

%% =============================================================================
%% PRIVATE — controller side
%% =============================================================================

realm(Uri) ->
    #{
        uri => Uri,
        info => #{
            ~"oidc_providers" => #{
                ?PROVIDER => #{
                    ~"issuer" => ~"http://127.0.0.1:1/idp",
                    ~"client_id" => ~"client",
                    ~"client_secret" => ~"secret",
                    ~"redirect_uri" => ~"http://127.0.0.1:18080/cb"
                }
            }
        }
    }.

%% The realm reaches nodes 2 and 3 by replication, so a start waits for it.
start_provider_worker(Node, Uri) ->
    case erpc:call(Node, bondy_realm, lookup, [Uri]) of
        {ok, _} ->
            ok = erpc:call(Node, ?MODULE, do_start_provider_worker, [
                Uri, ?PROVIDER
            ]),
            true;
        {error, not_found} ->
            false
    end.

%% How many provider workers `Node` runs once `Done` holds, or at the deadline.
await(Node, Done) ->
    Deadline = erlang:monotonic_time(millisecond) + ?AWAIT_MS,
    await(Node, Done, Deadline).

await(Node, Done, Deadline) ->
    case Done() orelse erlang:monotonic_time(millisecond) > Deadline of
        true ->
            provider_workers(Node);
        false ->
            timer:sleep(200),
            await(Node, Done, Deadline)
    end.

provider_workers(Node) ->
    erpc:call(Node, ?MODULE, do_provider_workers, []).

push_module(Node) ->
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

%% =============================================================================
%% PRIVATE — peer side
%% =============================================================================

%% Provider metadata echoes the issuer it was loaded from, so no provider has
%% to be reachable.
do_mock_provider_metadata() ->
    ok = meck:new(oidcc_provider_configuration, [passthrough, no_link]),
    ok = meck:expect(
        oidcc_provider_configuration,
        load_configuration,
        fun(Issuer, _) ->
            Config = #oidcc_provider_configuration{
                issuer = Issuer, jwks_uri = <<Issuer/binary, "/jwks">>
            },
            {ok, {Config, 3600000}}
        end
    ),
    meck:expect(
        oidcc_provider_configuration,
        load_jwks,
        fun(_, _) -> {ok, {jose_jwk:generate_key({oct, 32}), 3600000}} end
    ).

do_unmock_provider_metadata() ->
    meck:unload(oidcc_provider_configuration).

do_start_provider_worker(Uri, Provider) ->
    {ok, _} = bondy_oidc_provider:get_client_context(Uri, Provider),
    ok.

do_provider_workers() ->
    proplists:get_value(
        active, supervisor:count_children(bondy_oidc_provider_sup)
    ).
