%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_login_rolling_restart_SUITE).
-moduledoc """
Logins and API Gateway specifications across a rolling restart of a 3-node
cluster that runs the shipped anti-entropy and authentication-fence settings.

One case restarts the nodes one at a time; the other stops two nodes for longer
than the fence's lag (`auth_max_lag`) and brings them back. After each step a
password login and the loaded API specification are required on every node.
When a node keeps refusing the login, the case adds a second user, records
whether that write restores the login, and fails with both observations.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("bondy_wamp/include/bondy_wamp.hrl").
-include("bondy_security.hrl").

-export([all/0]).
-export([suite/0]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).
-export([logins_survive_a_rolling_restart/1]).
-export([logins_recover_after_a_node_is_cut_off/1]).
-export([do_setup/0]).
-export([do_login/0]).
-export([do_has_spec/0]).
-export([do_add_user/1]).

%% The values `config/bondy.conf.defaults' generates for these keys.
-define(SHIPPED_ENV, [
    {[bondy_oplog, aae_enabled], true},
    {[bondy_oplog, aae_fence_on_isolation], refuse},
    {[bondy_oplog, sync_interval_ms], 500},
    {[bondy_router, auth_max_lag], 60000}
]).

-define(REALM, ~"com.example.login_rolling_restart").
-define(USER, ~"rolling_user").
-define(PASSWORD, ~"rolling_pass_123").
-define(SPEC_ID, ~"com.example.login_rolling_restart.api").
-define(LOGIN_TIMEOUT, 180000).

all() ->
    [logins_survive_a_rolling_restart, logins_recover_after_a_node_is_cut_off].

suite() ->
    [{timetrap, {minutes, 30}}].

init_per_testcase(_Case, Config) ->
    Specs = bondy_ct:start_cluster(
        [
            {bondy1, ?SHIPPED_ENV},
            {bondy2, ?SHIPPED_ENV},
            {bondy3, ?SHIPPED_ENV}
        ],
        Config
    ),
    ok = lists:foreach(fun({_, Node, _}) -> push_module(Node) end, Specs),
    [{cluster, Specs} | Config].

end_per_testcase(_Case, Config) ->
    ok = bondy_ct:stop_cluster(current_cluster(Config)),
    Config.

%% A case that replaces nodes stores the replacements under `cluster_now'.
current_cluster(Config) ->
    case erlang:get(cluster_now) of
        undefined -> ?config(cluster, Config);
        Specs -> Specs
    end.

%% =============================================================================
%% CASES
%% =============================================================================

logins_survive_a_rolling_restart(Config) ->
    Specs0 = ?config(cluster, Config),
    [{_, N1, _} | _] = Specs0,
    ok = erpc:call(N1, ?MODULE, do_setup, [], 60000),
    Baseline = await_all(node_names(Specs0)),
    ct:pal("before restarts: ~p", [Baseline]),
    ?assertEqual([], failures(Baseline), "baseline login and spec"),
    {Specs, Rounds} = lists:foldl(
        fun(Idx, {SpecsAcc, Acc}) ->
            Spec = lists:nth(Idx, SpecsAcc),
            Others = [S || S <- SpecsAcc, S =/= Spec],
            New = bondy_ct:restart_node(
                Spec, Idx, ?SHIPPED_ENV, Config, graceful
            ),
            ok = push_module(element(2, New)),
            ok = bondy_ct:rejoin(New, Others, 60000),
            SpecsAcc1 = replace(Spec, New, SpecsAcc),
            Round = await_all(node_names(SpecsAcc1)),
            ct:pal("after restarting node ~p: ~p", [Idx, Round]),
            {SpecsAcc1, [{Idx, Round} | Acc]}
        end,
        {Specs0, []},
        [3, 2, 1]
    ),
    _ = erlang:put(cluster_now, Specs),
    Failed = [{Idx, F} || {Idx, Round} <- Rounds, F <- failures(Round)],
    AfterWrite =
        case Failed of
            [] ->
                not_needed;
            [_ | _] ->
                [{_, M1, _} | _] = Specs,
                ok = erpc:call(M1, ?MODULE, do_add_user, [~"rolling_user_2"]),
                await_all(node_names(Specs))
        end,
    ct:pal("after adding a second user: ~p", [AfterWrite]),
    ?assertEqual({[], not_needed}, {Failed, AfterWrite}).

logins_recover_after_a_node_is_cut_off(Config) ->
    [S1, S2, S3] = ?config(cluster, Config),
    {_, N1, _} = S1,
    {_, N3, _} = S3,
    ok = erpc:call(N1, ?MODULE, do_setup, [], 60000),
    Baseline = await_all(node_names([S1, S2, S3])),
    ct:pal("before the cut: ~p", [Baseline]),
    ?assertEqual([], failures(Baseline), "baseline login and spec"),
    ok = stop(S1),
    ok = stop(S2),
    _ = erlang:put(cluster_now, [S3]),
    timer:sleep(70000),
    Alone = call(N3, do_login, []),
    ct:pal("node 3 alone for 70 s: ~p", [Alone]),
    PrivDir = ?config(priv_dir, Config),
    Cookie = atom_to_list(erlang:get_cookie()),
    New1 = bondy_ct:start_node(bondy1, 1, PrivDir, Cookie, ?SHIPPED_ENV),
    ok = push_module(element(2, New1)),
    ok = bondy_ct:rejoin(New1, [S3], 60000),
    New2 = bondy_ct:start_node(bondy2, 2, PrivDir, Cookie, ?SHIPPED_ENV),
    ok = push_module(element(2, New2)),
    ok = bondy_ct:rejoin(New2, [S3, New1], 60000),
    Specs = [New1, New2, S3],
    _ = erlang:put(cluster_now, Specs),
    After = await_all(node_names(Specs)),
    ct:pal("after the peers return: ~p", [After]),
    AfterWrite =
        case failures(After) of
            [] ->
                not_needed;
            [_ | _] ->
                {_, M1, _} = New1,
                ok = erpc:call(M1, ?MODULE, do_add_user, [~"rolling_user_2"]),
                await_all(node_names(Specs))
        end,
    ct:pal("after adding a second user: ~p", [AfterWrite]),
    ?assertEqual({[], not_needed}, {failures(After), AfterWrite}).

%% =============================================================================
%% PRIVATE — controller side
%% =============================================================================

stop({_, Node, _} = Spec) ->
    ok = bondy_ct:stop_node(Spec, graceful),
    _ = erlang:disconnect_node(Node),
    await_down(Node, 60).

await_down(Node, 0) ->
    error({node_still_up, Node});
await_down(Node, N) ->
    case net_adm:ping(Node) of
        pang ->
            ok;
        pong ->
            _ = erlang:disconnect_node(Node),
            timer:sleep(500),
            await_down(Node, N - 1)
    end.

push_module(Node) ->
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = erpc:call(Node, code, load_binary, [Mod, File, Bin]),
    ok.

node_names(Specs) ->
    [Node || {_, Node, _} <- Specs].

replace(Old, New, Specs) ->
    [
        case S of
            Old -> New;
            _ -> S
        end
     || S <- Specs
    ].

%% For each node: the login outcome and the time it took to succeed (or the
%% last refusal at the deadline), and whether the API spec arrived by the
%% same deadline.
await_all(Nodes) ->
    Deadline = erlang:monotonic_time(millisecond) + ?LOGIN_TIMEOUT,
    [
        {Node, await_login(Node, Deadline), await_spec(Node, Deadline)}
     || Node <- Nodes
    ].

await_login(Node, Deadline) ->
    Start = erlang:monotonic_time(millisecond),
    await_login(Node, Start, Deadline).

await_login(Node, Start, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case call(Node, do_login, []) of
        ok ->
            {ok, Now - Start};
        Refused when Now >= Deadline ->
            {refused, Refused};
        _ ->
            timer:sleep(1000),
            await_login(Node, Start, Deadline)
    end.

await_spec(Node, Deadline) ->
    case call(Node, do_has_spec, []) of
        true ->
            true;
        Missing ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    Missing;
                false ->
                    timer:sleep(1000),
                    await_spec(Node, Deadline)
            end
    end.

call(Node, Fun, Args) ->
    try
        erpc:call(Node, ?MODULE, Fun, Args, 10000)
    catch
        error:{erpc, Reason} -> {erpc, Reason}
    end.

failures(Round) ->
    [
        {Node, Login, Spec}
     || {Node, Login, Spec} <- Round,
        not (element(1, Login) == ok andalso Spec == true)
    ].

%% =============================================================================
%% PRIVATE — node side
%% =============================================================================

do_setup() ->
    _ =
        bondy_realm:exists(?REALM) orelse
            bondy_realm:create(#{
                uri => ?REALM,
                description => ~"login across a rolling restart",
                security_enabled => true,
                authmethods => [?PASSWORD_AUTH],
                sources => [
                    #{
                        usernames => ~"all",
                        authmethod => ?PASSWORD_AUTH,
                        cidr => ~"0.0.0.0/0"
                    }
                ]
            }),
    ok = do_add_user(?USER),
    ok = bondy_http_gateway:load(#{
        ~"id" => ?SPEC_ID,
        ~"name" => ?SPEC_ID,
        ~"host" => ~"_",
        ~"realm_uri" => ?REALM,
        ~"defaults" => #{~"security" => #{}, ~"schemes" => [~"http"]},
        ~"versions" => #{
            ~"1.0.0" => #{
                ~"base_path" => ~"/login_rolling/v1.0",
                ~"paths" => #{
                    ~"/thing" => #{
                        ~"get" => #{
                            ~"action" => #{
                                ~"type" => ~"wamp_call",
                                ~"procedure" => ~"com.example.thing",
                                ~"args" => []
                            },
                            ~"response" => #{
                                ~"on_error" => #{},
                                ~"on_result" => #{}
                            }
                        }
                    }
                }
            }
        }
    }).

do_add_user(Username) ->
    User = bondy_rbac_user:new(#{
        username => Username, password => ?PASSWORD, groups => []
    }),
    %% Every case starts its cluster on the data directories the previous
    %% case left, so the user may already be there.
    case bondy_rbac_user:add(?REALM, User) of
        {ok, _} -> ok;
        {error, already_exists} -> ok
    end.

do_login() ->
    case
        bondy_auth:init(
            bondy_session_id:new(), ?REALM, ?USER, [], {127, 0, 0, 1}
        )
    of
        {ok, Ctxt} ->
            case
                bondy_auth:authenticate(
                    ?PASSWORD_AUTH, ?PASSWORD, undefined, Ctxt
                )
            of
                {ok, _, _} -> ok;
                {error, Reason} -> {auth_error, Reason}
            end;
        {error, Reason} ->
            {init_error, Reason}
    end.

do_has_spec() ->
    case bondy_http_gateway:lookup(?SPEC_ID) of
        Spec when is_map(Spec) -> true;
        Other -> {missing, Other}
    end.
