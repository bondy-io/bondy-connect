%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_metrics_ct).

-moduledoc """
Hosts the `bondy_metrics` registry for a CT suite that runs without a booted
node.

In a node, `bondy_oplog_sup` owns the registry. A registry left running by an
earlier suite makes that supervisor fail with `already_started` when a later
suite boots Bondy, and the failed start halts the CT node (running
`bondy_http_connector_http_pool_SUITE` then `bondy_mcp_e2e_SUITE` showed it).
So a suite stops only the registry it started, and never adopts one it found.
""".

-export([ensure_registry/0]).
-export([stop_registry/1]).

-doc """
Starts the registry unless one is running, and returns whether it did. The
registry is unlinked so it outlives the transient `init_per_suite` process.
""".
-spec ensure_registry() -> boolean().

ensure_registry() ->
    case whereis(bondy_metrics) of
        undefined ->
            {ok, Pid} = bondy_metrics:start_link(),
            true = unlink(Pid),
            true;
        Pid when is_pid(Pid) ->
            false
    end.

-doc "Stops the registry if `ensure_registry/0` returned `true`.".
-spec stop_registry(Started :: boolean()) -> ok.

stop_registry(true) ->
    gen_server:stop(bondy_metrics);
stop_registry(false) ->
    ok.
