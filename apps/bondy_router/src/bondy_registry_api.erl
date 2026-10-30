%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_registry_api).
-moduledoc """
The `bondy.*` registry introspection procedures. Each takes the realm it reads
as its first argument, so a master-realm session can read any realm; the
`wamp.*` meta procedures in `bondy_wamp_meta_api` read the caller's own realm
only.

The enumerations are **paginated** (`bondy.registration.list|match`,
`bondy.subscription.list|match`, `bondy.registration.callee.list`): a thin
adapter over `bondy_registry_meta` reads the `limit` / `cursor` KWArgs (bounded
by `bondy_registry_meta:{default,max}_page_size/0`), runs the distributed
keyset page, and externalises it with `bondy_pagination:to_external/1`.

The procedures addressed by an id (`bondy.registration.get|list_callees|
count_callees`, `bondy.subscription.get|list_subscribers|count_subscribers`)
return what their `wamp.*` namesakes return for the caller's realm.
""".
-behaviour(bondy_wamp_api).

-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy.hrl").
-include("bondy_uris.hrl").

-export([handle_call/3]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(
    Proc :: uri(), M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()
) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

%% -----------------------------------------------------------------------------
%% bondy.registration.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_REGISTRATION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    reply_page(M, paginated_list(registration, RealmUri, M));
handle_call(?BONDY_REGISTRATION_MATCH, M, Ctxt) ->
    [RealmUri, Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_page(M, paginated_match(registration, RealmUri, Uri, M));
handle_call(?BONDY_REGISTRATION_CALLEE_LIST, M, Ctxt) ->
    Args = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1, 2),
    reply_page(M, paginated_callees(Args, M));
handle_call(?BONDY_REGISTRATION_GET, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        registration,
        Id,
        bondy_registry_meta:get(
            registration, RealmUri, Id
        )
    );
handle_call(?BONDY_REGISTRATION_LIST_CALLEES, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        registration,
        Id,
        bondy_registry_meta:list_members(
            registration, RealmUri, Id
        )
    );
handle_call(?BONDY_REGISTRATION_COUNT_CALLEES, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        registration,
        Id,
        bondy_registry_meta:count_members(
            registration, RealmUri, Id
        )
    );
%% -----------------------------------------------------------------------------
%% bondy.subscription.*
%% -----------------------------------------------------------------------------
handle_call(?BONDY_SUBSCRIPTION_LIST, M, Ctxt) ->
    [RealmUri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 1),
    reply_page(M, paginated_list(subscription, RealmUri, M));
handle_call(?BONDY_SUBSCRIPTION_MATCH, M, Ctxt) ->
    [RealmUri, Uri] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_page(M, paginated_match(subscription, RealmUri, Uri, M));
handle_call(?BONDY_SUBSCRIPTION_GET, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        subscription,
        Id,
        bondy_registry_meta:get(
            subscription, RealmUri, Id
        )
    );
handle_call(?BONDY_SUBSCRIPTION_LIST_SUBSCRIBERS, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        subscription,
        Id,
        bondy_registry_meta:list_members(
            subscription, RealmUri, Id
        )
    );
handle_call(?BONDY_SUBSCRIPTION_COUNT_SUBSCRIBERS, M, Ctxt) ->
    [RealmUri, Id] = bondy_wamp_api_utils:validate_call_args(M, Ctxt, 2),
    reply_value(
        M,
        subscription,
        Id,
        bondy_registry_meta:count_members(
            subscription, RealmUri, Id
        )
    );
handle_call(_, M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
reply_value(M, Type, Id, Result) ->
    case bondy_wamp_api_utils:entry_result(Type, Id, Result) of
        {ok, Value} ->
            {reply, bondy_wamp_message:result(M#call.request_id, #{}, [Value])};
        {error, Reason} ->
            {reply, bondy_wamp_api_utils:error(Reason, M)}
    end.

%% @private
reply_page(M, {ok, PageMap}) ->
    R = bondy_wamp_message:result(M#call.request_id, #{}, [PageMap]),
    {reply, R};
reply_page(M, {error, Reason}) ->
    E = bondy_wamp_api_utils:error(Reason, M),
    {reply, E}.

%% @private
%% A cluster-wide keyset page of the realm's entries of `Type`, externalised for
%% the wire. Distributed and paginated via `bondy_registry_meta`.
paginated_list(Type, RealmUri, M) ->
    externalise(
        fun() -> bondy_registry_meta:list(Type, RealmUri, page_opts(M)) end
    ).

%% @private
paginated_match(Type, RealmUri, Uri, M) ->
    externalise(
        fun() ->
            bondy_registry_meta:match(Type, RealmUri, Uri, page_opts(M))
        end
    ).

%% @private
%% The callees of a realm (1 arg) or of a procedure (2 args), as
%% `#{node, session_id}`. Paginated and cluster-wide like the four procedures
%% above. Reading it through `bondy_dealer:callees/1,2` instead would reach
%% `bondy_registry:match/3,4`, which under write-only RIB answers with the
%% SERVING node's entries only — silently omitting every callee living
%% elsewhere, and growing less complete as the cluster grows.
paginated_callees([RealmUri], M) ->
    paginated_callees(RealmUri, all, M);
paginated_callees([RealmUri, ProcedureUri], M) ->
    paginated_callees(RealmUri, ProcedureUri, M).

%% @private
paginated_callees(RealmUri, Query, M) ->
    externalise(
        fun() ->
            bondy_registry_meta:page_members(
                registration, RealmUri, Query, page_opts(M)
            )
        end
    ).

%% @private
externalise(Fun) ->
    try Fun() of
        {ok, ResultSet} ->
            {ok, bondy_pagination:to_external(ResultSet)};
        {error, _} = Error ->
            Error
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            {error, Reason}
    end.

%% @private
%% Keyset pagination from the `limit` and `cursor` KWArgs. The bounds are the
%% engine's, not this module's.
page_opts(M) ->
    #{
        limit => bondy_wamp_api_utils:page_limit(
            M,
            bondy_registry_meta:default_page_size(),
            bondy_registry_meta:max_page_size()
        ),
        cursor => bondy_wamp_api_utils:page_cursor(M)
    }.
