%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_oidc_provider).
-moduledoc """
Manages OIDC provider configuration and `oidcc_provider_configuration_worker`
lifecycle.

Provider workers are started lazily on first use and registered via gproc
as `{bondy_oidc_provider, RealmUri, ProviderName, Issuer, AllowUnsafeHttp}`.
Each worker caches and periodically refreshes the provider metadata (JWKS,
endpoints).

A worker serves only the provider settings it was started with. A lookup
names the realm's current issuer and `allow_unsafe_http`, so after a change
it misses, and the pair's old worker is stopped before a new one starts
(`bondy_realm_SUITE:oidc_provider_worker_follows_the_realm`). Deleting a realm
stops its workers on every node through `bondy_realm:teardown/1`
(`bondy_realm_cluster_SUITE:oidc_provider_workers_stop_with_their_realm`).
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").

%% API
-export([get_client_context/2]).
-export([get_provider_config/2]).
-export([get_refresh_jwks_fun/2]).
-export([request_opts/1]).
-export([start_provider_worker/3]).
-export([stop_provider_worker/2]).
-export([stop_realm_workers/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Starts an `oidcc_provider_configuration_worker` for the given provider.

If a worker started from the same issuer and `allow_unsafe_http` is running
for this (realm, provider) pair, returns `{ok, Pid}` of that worker. Otherwise
stops the pair's other workers and starts one from `Config`.
""".
-spec start_provider_worker(
    RealmUri :: uri(),
    ProviderName :: binary(),
    Config :: map()
) -> {ok, pid()} | {error, term()}.

start_provider_worker(RealmUri, ProviderName, Config) when
    is_binary(RealmUri) andalso is_binary(ProviderName) andalso is_map(Config)
->
    case whereis_worker(RealmUri, ProviderName, Config) of
        undefined ->
            ok = stop_provider_worker(RealmUri, ProviderName),
            do_start_worker(RealmUri, ProviderName, Config);
        Pid ->
            {ok, Pid}
    end.

-doc """
Stops this node's provider configuration workers for the given (realm,
provider) pair.
""".
-spec stop_provider_worker(
    RealmUri :: uri(),
    ProviderName :: binary()
) -> ok.

stop_provider_worker(RealmUri, ProviderName) when
    is_binary(RealmUri) andalso is_binary(ProviderName)
->
    stop_workers(RealmUri, ProviderName).

-doc """
Stops this node's provider configuration workers for every provider of the
realm.
""".
-spec stop_realm_workers(RealmUri :: uri()) -> ok.

stop_realm_workers(RealmUri) when is_binary(RealmUri) ->
    stop_workers(RealmUri, '_').

-doc """
Returns an `oidcc_client_context` for the given (realm, provider) pair.

Lazily starts the provider worker if needed.
""".
-spec get_client_context(
    RealmUri :: uri(),
    ProviderName :: binary()
) -> {ok, oidcc_client_context:t()} | {error, term()}.

get_client_context(RealmUri, ProviderName) when
    is_binary(RealmUri) andalso is_binary(ProviderName)
->
    case get_provider_config(RealmUri, ProviderName) of
        {ok, #{client_id := ClientId, client_secret := ClientSecret} = Config} ->
            Pid = ensure_worker(RealmUri, ProviderName, Config),
            try
                oidcc_client_context:from_configuration_worker(
                    Pid, ClientId, ClientSecret
                )
            catch
                exit:{_, {gen_server, call, _}} = Reason ->
                    ?LOG_ERROR(#{
                        description => "Failed to create OIDC client context",
                        realm_uri => RealmUri,
                        provider => ProviderName,
                        reason => Reason
                    }),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Looks up provider configuration from the realm.
""".
-spec get_provider_config(
    RealmUri :: uri(),
    ProviderName :: binary()
) -> {ok, map()} | {error, not_found | {no_such_realm, uri()}}.

get_provider_config(RealmUri, ProviderName) when
    is_binary(RealmUri) andalso is_binary(ProviderName)
->
    try bondy_realm:fetch(RealmUri) of
        Realm ->
            bondy_realm:get_oidc_provider(Realm, ProviderName)
    catch
        error:{not_found, RealmUri} ->
            {error, {no_such_realm, RealmUri}}
    end.

-doc """
Returns a JWKS refresh function for the given (realm, provider) pair.

The returned function can be passed as the `refresh_jwks` option to
`oidcc_token:retrieve/3` so that unknown key IDs trigger an automatic
JWKS re-fetch from the provider.
""".
-spec get_refresh_jwks_fun(
    RealmUri :: uri(),
    ProviderName :: binary()
) -> {ok, oidcc_jwt_util:refresh_jwks_for_unknown_kid_fun()} | {error, term()}.

get_refresh_jwks_fun(RealmUri, ProviderName) when
    is_binary(RealmUri) andalso is_binary(ProviderName)
->
    case get_provider_config(RealmUri, ProviderName) of
        {ok, Config} ->
            Pid = ensure_worker(RealmUri, ProviderName, Config),
            {ok, oidcc_jwt_util:refresh_jwks_fun(Pid)};
        {error, _} = Error ->
            Error
    end.

-doc """
Returns the `request_opts` map (including SSL options) for the given provider
config. Must be passed to every `oidcc` function that makes HTTP requests
(`oidcc_token:retrieve/3`, `oidcc_userinfo:retrieve/3`, `oidcc_token:refresh/3`)
because `httpc` computes default SSL options — including OS CA cert loading via
`pubkey_os_cacerts:get/0` — even for plain HTTP requests. In environments
without OS CA certs (e.g. containers), this causes a `function_clause` crash.
""".
-spec request_opts(Config :: map()) -> map().

request_opts(#{issuer := Issuer} = Config) ->
    AllowUnsafeHttp = maps:get(allow_unsafe_http, Config, false),
    #{ssl => ssl_opts(Issuer, AllowUnsafeHttp)}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
worker_key(RealmUri, ProviderName, #{issuer := Issuer} = Config) ->
    AllowUnsafeHttp = maps:get(allow_unsafe_http, Config, false),
    {bondy_oidc_provider, RealmUri, ProviderName, Issuer, AllowUnsafeHttp}.

%% @private
whereis_worker(RealmUri, ProviderName, Config) ->
    try
        bondy_gproc:lookup_pid(worker_key(RealmUri, ProviderName, Config))
    catch
        error:badarg ->
            undefined
    end.

%% @private
%% `ProviderName` is `'_'` to match every provider of the realm.
stop_workers(RealmUri, ProviderName) ->
    Key = {bondy_oidc_provider, RealmUri, ProviderName, '_', '_'},
    Pids = gproc:select({l, n}, [{{{n, l, Key}, '$1', '_'}, [], ['$1']}]),
    lists:foreach(
        fun(Pid) ->
            case supervisor:terminate_child(bondy_oidc_provider_sup, Pid) of
                ok -> ok;
                {error, not_found} -> ok
            end
        end,
        Pids
    ).

%% @private
ensure_worker(RealmUri, ProviderName, Config) ->
    case start_provider_worker(RealmUri, ProviderName, Config) of
        {ok, Pid} -> Pid;
        {error, Reason} -> error(Reason)
    end.

%% @private
do_start_worker(RealmUri, ProviderName, Config) ->
    #{issuer := Issuer} = Config,

    GprocName =
        {via, gproc, {n, l, worker_key(RealmUri, ProviderName, Config)}},

    AllowUnsafeHttp = maps:get(allow_unsafe_http, Config, false),

    SslOpts = ssl_opts(Issuer, AllowUnsafeHttp),

    WorkerArgs = #{
        issuer => Issuer,
        name => GprocName,
        provider_configuration_opts => #{
            request_opts => #{ssl => SslOpts},
            quirks => #{allow_unsafe_http => AllowUnsafeHttp}
        }
    },

    case bondy_oidc_provider_sup:start_child(WorkerArgs) of
        {ok, Pid} ->
            ?LOG_INFO(#{
                description => "Started OIDC provider worker",
                realm_uri => RealmUri,
                provider => ProviderName,
                issuer => Issuer,
                pid => Pid
            }),
            case await_worker_ready(Pid, RealmUri, ProviderName) of
                ok ->
                    {ok, Pid};
                {error, _} = Error ->
                    Error
            end;
        {error, {already_started, Pid}} ->
            {ok, Pid};
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                description => "Failed to start OIDC provider worker",
                realm_uri => RealmUri,
                provider => ProviderName,
                issuer => Issuer,
                reason => Reason
            }),
            Error
    end.

%% @private
%% Returns SSL options for httpc requests to the OIDC provider.
%% We must always provide explicit ssl options because httpc computes default
%% SSL options (including OS CA cert loading via pubkey_os_cacerts:get/0) even
%% for plain HTTP requests. In environments without OS CA certs (e.g.
%% containers), this causes a function_clause crash.
ssl_opts(Issuer, _AllowUnsafeHttp) when is_binary(Issuer) ->
    case string:prefix(Issuer, <<"https">>) of
        nomatch ->
            bondy_cert_manager:ssl_opts(#{verify => verify_none});
        _ ->
            bondy_cert_manager:ssl_opts()
    end.

%% @private
%% Waits for the provider worker to finish loading its configuration and JWKS.
%% The oidcc worker loads these in handle_continue after init, so gen_server
%% calls will time out until both are done.
await_worker_ready(Pid, RealmUri, ProviderName) ->
    await_worker_ready(Pid, RealmUri, ProviderName, 10).

%% @private
await_worker_ready(_Pid, RealmUri, ProviderName, 0) ->
    ?LOG_ERROR(#{
        description => "OIDC provider worker not ready after retries",
        realm_uri => RealmUri,
        provider => ProviderName
    }),
    {error, {provider_not_ready, ProviderName}};
await_worker_ready(Pid, RealmUri, ProviderName, Retries) ->
    try
        case gen_server:call(Pid, get_provider_configuration, 3000) of
            undefined ->
                timer:sleep(500),
                await_worker_ready(Pid, RealmUri, ProviderName, Retries - 1);
            _Config ->
                ok
        end
    catch
        exit:{timeout, _} ->
            timer:sleep(500),
            await_worker_ready(Pid, RealmUri, ProviderName, Retries - 1);
        exit:Reason ->
            ?LOG_ERROR(#{
                description => "OIDC provider worker failed during startup",
                realm_uri => RealmUri,
                provider => ProviderName,
                reason => Reason
            }),
            {error, {provider_unavailable, ProviderName}}
    end.
