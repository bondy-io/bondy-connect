%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_wamp_meta_api).
-moduledoc """
The spec-compliant `wamp.*` registry/subscription meta procedures
(`wamp.registration.*` and `wamp.subscription.*`: `list`, `lookup`, `match`,
`get`, `list_callees`/`list_subscribers`, `count_callees`/`count_subscribers`).

Each procedure takes the arguments the WAMP specification gives and reads the
caller's own realm. Naming another realm is a Bondy extension: a master-realm
session reads any realm through the realm-first `bondy.*` procedures in
`bondy_registry_api`.

Results take the shapes the WAMP specification gives: `list` groups ids by
match policy, `subscription.match` is a list of ids, and `registration.match`
and `lookup` are one id or none. In Bondy every callee or subscriber holds its
own registration or subscription id, so `registration.match` names the oldest
entry of the group a `CALL` would be routed to
(`bondy_registry_meta:best_match/3`).

These procedures are **not** paginated. The cluster-wide set is unbounded, so
each enumeration is **bounded** via
`bondy_registry_meta:max_results/0`: past the ceiling it returns
`{error, too_many_results}` (→ `bondy.error.too_many_results`) and steers the
caller to the paginated `bondy.*` family (`bondy_registry_api`). `get`-by-id is a
cluster-wide broadcast and may return `{error, unavailable}` (→
`bondy.error.unavailable`) rather than a false `no_such_registration` when a node
holding the entry cannot be reached.

`*.count_callees`/`*.count_subscribers` and `*.list_callees`/`*.list_subscribers`
take a registration/subscription id: `bondy_registry_meta` resolves it to its URI
(a cluster-wide broadcast `get`) and then counts (from RIB summaries) or gathers
the member session ids (each owner node contributes its local sessions — the ids
are not replicated under write-only RIB, only summary counts, so they are
collected on demand). Best-effort AP; `{error, unavailable}` when the resolving
`get` cannot confirm the id.
""".
-behaviour(bondy_wamp_callback).

-include_lib("kernel/include/logger.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_uris.hrl").

-define(ALL, all).

-export([handle_call/2]).

%% =============================================================================
%% API
%% =============================================================================

-spec handle_call(M :: bondy_wamp_message:call(), Ctxt :: bondy_context:t()) ->
    ok
    | continue
    | {continue, uri() | wamp_call()}
    | {continue, uri() | wamp_call(), fun(
        (Reason :: any()) -> wamp_error() | undefined
    )}
    | {reply, wamp_result() | wamp_error()}.

handle_call(#call{} = M0, Ctxt) ->
    case bondy_wamp_api_utils:decode_call(M0) of
        {ok, M} -> do_handle_call(M, Ctxt);
        {error, Reply} -> {reply, Reply}
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
do_handle_call(#call{procedure_uri = ?WAMP_SESSION_GET} = M0, Ctxt) ->
    [Guid] = bondy_wamp_api_utils:call_args(M0, Ctxt, 1),
    %% Sessions are not replicated, so we route the call to the node that owns
    %% the session. The client-facing session id (`Guid`) is `{NodeHash}.{Rest}`;
    %% its own dot aligns with WAMP URI segments, so the routing URI is plain
    %% concatenation `wamp.session.{NodeHash}.{Rest}.get`. Each node registers a
    %% wildcard `wamp.session.{NodeHash}..get` (see bondy_session_manager), so the
    %% dealer forwards to the owning node with no per-session registration.
    case is_binary(Guid) andalso bondy_session_id:is_type(Guid) of
        true ->
            Uri = <<"wamp.session.", Guid/binary, ".get">>,
            Opts = maps:put(x_procedure, ?WAMP_SESSION_GET, M0#call.options),
            M1 = M0#call{procedure_uri = Uri, options = Opts, args = [Guid]},

            %% As we are rewriting the call, if the session does not exist we
            %% will get either noproc or no_such_procedure and we want to reply
            %% not_found.
            MakeError = fun
                (no_such_procedure) ->
                    no_such_session_error(?CALL, M0#call.request_id);
                (_) ->
                    undefined
            end,

            {continue, M1, MakeError};
        false ->
            E = no_such_session_error(?CALL, M0#call.request_id),
            {reply, E}
    end;
do_handle_call(#call{procedure_uri = ?WAMP_REG_LIST} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:call_args(M, Ctxt, 0),
    reply(M, summary(registration, realm_uri(Ctxt)));
do_handle_call(#call{procedure_uri = ?WAMP_REG_LOOKUP} = M, Ctxt) ->
    Args = bondy_wamp_api_utils:call_args(M, Ctxt, 1, 2),
    reply(M, lookup(registration, realm_uri(Ctxt), Args));
do_handle_call(#call{procedure_uri = ?WAMP_REG_MATCH} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(M, match(registration, realm_uri(Ctxt), Uri));
do_handle_call(#call{procedure_uri = ?WAMP_REG_GET} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        registration,
        Id,
        bondy_registry_meta:get(
            registration, realm_uri(Ctxt), Id
        )
    );
do_handle_call(#call{procedure_uri = ?WAMP_LIST_CALLEES} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        registration,
        Id,
        bondy_registry_meta:list_members(
            registration, realm_uri(Ctxt), Id
        )
    );
do_handle_call(#call{procedure_uri = ?WAMP_COUNT_CALLEES} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        registration,
        Id,
        bondy_registry_meta:count_members(
            registration, realm_uri(Ctxt), Id
        )
    );
do_handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST} = M, Ctxt) ->
    [] = bondy_wamp_api_utils:call_args(M, Ctxt, 0),
    reply(M, summary(subscription, realm_uri(Ctxt)));
do_handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_LOOKUP} = M, Ctxt) ->
    Args = bondy_wamp_api_utils:call_args(M, Ctxt, 1, 2),
    reply(M, lookup(subscription, realm_uri(Ctxt), Args));
do_handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_MATCH} = M, Ctxt) ->
    [Uri] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(M, match(subscription, realm_uri(Ctxt), Uri));
do_handle_call(#call{procedure_uri = ?WAMP_SUBSCRIPTION_GET} = M, Ctxt) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        subscription,
        Id,
        bondy_registry_meta:get(
            subscription, realm_uri(Ctxt), Id
        )
    );
do_handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_LIST_SUBSCRIBERS} = M, Ctxt
) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        subscription,
        Id,
        bondy_registry_meta:list_members(
            subscription, realm_uri(Ctxt), Id
        )
    );
do_handle_call(
    #call{procedure_uri = ?WAMP_SUBSCRIPTION_COUNT_SUBSCRIBERS} = M, Ctxt
) ->
    [Id] = bondy_wamp_api_utils:call_args(M, Ctxt, 1),
    reply(
        M,
        subscription,
        Id,
        bondy_registry_meta:count_members(
            subscription, realm_uri(Ctxt), Id
        )
    );
%% Interface Reflection: the read side of `bondy_interface`. A LIST is the
%% RBAC-projected set of described URIs — the specification's own wording is
%% a list of what the peer "is authorized to access or provide" — and a
%% DESCRIBE of an entry the caller may not see answers exactly as an absent
%% one, so the reply is not an existence oracle.
do_handle_call(#call{procedure_uri = ?WAMP_REFLECTION_PROC_LIST} = M, Ctxt) ->
    reflection_list(procedure, M, Ctxt);
do_handle_call(#call{procedure_uri = ?WAMP_REFLECTION_PROC_DESCRIBE} = M, Ctxt) ->
    reflection_describe(procedure, M, Ctxt);
do_handle_call(#call{procedure_uri = ?WAMP_REFLECTION_TOPIC_LIST} = M, Ctxt) ->
    reflection_list(topic, M, Ctxt);
do_handle_call(
    #call{procedure_uri = ?WAMP_REFLECTION_TOPIC_DESCRIBE} = M, Ctxt
) ->
    reflection_describe(topic, M, Ctxt);
do_handle_call(#call{procedure_uri = ?WAMP_REFLECTION_ERROR_LIST} = M, Ctxt) ->
    reflection_list(error, M, Ctxt);
do_handle_call(
    #call{procedure_uri = ?WAMP_REFLECTION_ERROR_DESCRIBE} = M, Ctxt
) ->
    reflection_describe(error, M, Ctxt);
do_handle_call(#call{} = M, _) ->
    E = bondy_wamp_api_utils:no_such_procedure_error(M),
    {reply, E}.

%% @private
reflection_list(Kind, M, Ctxt) ->
    [] = bondy_wamp_api_utils:call_args(M, Ctxt, 0),
    Entries = bondy_interface:list(realm_uri(Ctxt), Kind),
    Uris = visible_uris(Kind, Entries, rbac_filter(Ctxt)),
    R = bondy_wamp_message:result(M#call.request_id, #{}, [Uris]),
    {reply, R}.

%% @private
reflection_describe(Kind, M, Ctxt) ->
    case bondy_wamp_api_utils:call_args(M, Ctxt, 1) of
        [Uri] when is_binary(Uri) ->
            RealmUri = realm_uri(Ctxt),
            Visible =
                case rbac_filter(Ctxt) of
                    none ->
                        true;
                    {filter, RBACCtxt} ->
                        {V, _} = permitted(Kind, Uri, RBACCtxt),
                        V
                end,
            case
                Visible andalso bondy_interface:describe(RealmUri, Kind, Uri)
            of
                {ok, Entry} ->
                    External = bondy_interface:to_external(Entry),
                    R = bondy_wamp_message:result(
                        M#call.request_id, #{}, [External]
                    ),
                    {reply, R};
                _ ->
                    {reply, bondy_wamp_api_utils:error(not_found, M)}
            end;
        [_] ->
            {reply, bondy_wamp_api_utils:error(badarg, M)}
    end.

%% @private
%% Whether — and with which RBAC context — a reflection result must be
%% projected. Mirrors `bondy_rbac:authorize/3`'s gate: no filter on a
%% security-disabled realm.
rbac_filter(Ctxt) ->
    case bondy_context:is_security_enabled(Ctxt) of
        true ->
            {filter, bondy_session:rbac_context(bondy_context:session(Ctxt))};
        false ->
            none
    end.

%% @private
%% The RBAC projection of a list result, threading the refreshed context
%% through the fold (`check_permission/2` returns it precisely so a caller
%% does not rebuild it per entry once the epoch lapses).
visible_uris(_Kind, Entries, none) ->
    lists:usort([maps:get(uri, E) || E <- Entries]);
visible_uris(Kind, Entries, {filter, RBACCtxt0}) ->
    {Uris, _} = lists:foldl(
        fun(E, {Acc, RC0}) ->
            Uri = maps:get(uri, E),
            case permitted(Kind, Uri, RC0) of
                {true, RC} -> {[Uri | Acc], RC};
                {false, RC} -> {Acc, RC}
            end
        end,
        {[], RBACCtxt0},
        Entries
    ),
    lists:usort(Uris).

%% @private
%% "Authorized to access or provide": a procedure is visible to a caller who
%% may call OR register it, a topic to one who may subscribe OR publish.
%% Error URIs have no permission space — they ride on the operations that
%% raise them — so they are always visible.
permitted(error, _Uri, RBACCtxt) ->
    {true, RBACCtxt};
permitted(Kind, Uri, RBACCtxt) ->
    any_permitted(actions(Kind), Uri, RBACCtxt).

%% @private
actions(procedure) -> [<<"wamp.call">>, <<"wamp.register">>];
actions(topic) -> [<<"wamp.subscribe">>, <<"wamp.publish">>].

%% @private
any_permitted([], _Uri, RBACCtxt) ->
    {false, RBACCtxt};
any_permitted([Action | Rest], Uri, RBACCtxt0) ->
    case bondy_rbac:check_permission({Action, Uri}, RBACCtxt0) of
        {true, RBACCtxt} -> {true, RBACCtxt};
        {false, _, RBACCtxt} -> any_permitted(Rest, Uri, RBACCtxt)
    end.

no_such_session_error(Type, ReqId) when Type == ?CALL; Type == ?INVOCATION ->
    bondy_wamp_message:error(
        Type,
        ReqId,
        #{},
        ?WAMP_NO_SUCH_SESSION,
        [
            <<"No session exists for the supplied identifier">>
        ]
    ).

%% @private
-doc """
Retrieves subscription IDs listed according to match policies.

```
Res :=
  {
      "exact": subscription_ids|list,
      "prefix": subscription_ids|list,
      "wildcard": subscription_ids|list
  }
```
""".
summary(Type, RealmUri) ->
    Default = #{
        ?EXACT_MATCH => [],
        ?PREFIX_MATCH => [],
        ?WILDCARD_MATCH => []
    },
    case bounded_ext(Type, RealmUri, ?ALL) of
        {ok, Externals} ->
            Grouped = lists:foldl(
                fun(Ext, Acc) ->
                    Policy = maps:get(match, Ext),
                    Id = maps:get(id, Ext),
                    maps:update_with(Policy, fun(L) -> [Id | L] end, [Id], Acc)
                end,
                Default,
                Externals
            ),
            {ok, Grouped};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Run a bounded `bondy_registry_meta` enumeration at the wamp.* ceiling:
%% `{ok, Externals}` (<= ?WAMP_META_MAX `wamp_meta` maps) or
%% `{error, too_many_results}` when more exist. `?ALL` lists the realm; a URI
%% matches it.
bounded_ext(Type, RealmUri, ?ALL) ->
    bounded_page(bondy_registry_meta:list(Type, RealmUri, page_limit()));
bounded_ext(Type, RealmUri, Uri) ->
    bounded_page(bondy_registry_meta:match(Type, RealmUri, Uri, page_limit())).

%% @private
bounded_page({ok, #{values := Values, has_more := false}}) ->
    {ok, Values};
bounded_page({ok, #{has_more := true}}) ->
    {error, too_many_results};
bounded_page({error, _} = Error) ->
    Error.

%% @private
%% Fetch one past the ceiling so the bounded enumeration can tell "exactly the
%% ceiling" from "more exist" without a count.
page_limit() ->
    #{limit => bondy_registry_meta:max_results() + 1}.

%% @private
realm_uri(Ctxt) ->
    bondy_context:realm_uri(Ctxt).

%% @private
%% `ok` is the specification's null: a RESULT with no arguments.
reply(M, ok) ->
    {reply, bondy_wamp_message:result(M#call.request_id, #{})};
reply(M, {ok, Value}) ->
    {reply, bondy_wamp_message:result(M#call.request_id, #{}, [Value])};
reply(M, {error, Reason}) ->
    {reply, bondy_wamp_api_utils:error(Reason, M)}.

%% @private
reply(M, Type, Id, Result) ->
    reply(M, bondy_wamp_api_utils:entry_result(Type, Id, Result)).

%% @private
%% The id managing `Uri` under the options' match policy (`exact` when absent),
%% or `ok` for none. `invalid_argument` names a policy that is not one of the
%% three WAMP policies.
lookup(Type, RealmUri, [Uri]) ->
    lookup(Type, RealmUri, [Uri, #{}]);
lookup(Type, RealmUri, [Uri, Opts]) when is_map(Opts) ->
    case lookup_policy(Opts) of
        {ok, Policy} ->
            case bondy_registry_meta:lookup(Type, RealmUri, Uri, Policy) of
                {ok, External} ->
                    {ok, maps:get(id, External)};
                {error, not_found} ->
                    ok;
                {error, unavailable} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
lookup_policy(Opts) ->
    case maps:get(~"match", Opts, maps:get(match, Opts, ?EXACT_MATCH)) of
        Policy when
            Policy == ?EXACT_MATCH;
            Policy == ?PREFIX_MATCH;
            Policy == ?WILDCARD_MATCH
        ->
            {ok, Policy};
        Policy ->
            {error,
                bondy_connect_error:new(invalid_argument, #{
                    details => #{match => Policy}
                })}
    end.

%% @private
%% `wamp.registration.match` names the one registration a CALL to `Uri` would
%% reach; `wamp.subscription.match` lists every subscription an event on `Uri`
%% would reach, bounded at the `wamp.*` ceiling.
match(registration, RealmUri, Uri) ->
    case bondy_registry_meta:best_match(registration, RealmUri, Uri) of
        {ok, External} ->
            {ok, maps:get(id, External)};
        {error, not_found} ->
            ok;
        {error, unavailable} = Error ->
            Error
    end;
match(subscription, RealmUri, Uri) ->
    case bounded_ext(subscription, RealmUri, Uri) of
        {ok, []} ->
            ok;
        {ok, Externals} ->
            {ok, [maps:get(id, Ext) || Ext <- Externals]};
        {error, _} = Error ->
            Error
    end.
