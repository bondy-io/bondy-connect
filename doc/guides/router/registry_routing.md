# Registry Routing (RIB)

Bondy's registry holds every WAMP **registration** (a callee offering a
procedure) and **subscription** (a subscriber interested in a topic). To route
a call or an event across a cluster, a node must know which other nodes can
serve a given procedure or topic.

Bondy answers that question from a **Routing Information Base (RIB)**: a set of
compact, replicated *summary cells* — one per `(realm, match policy, URI,
node)` — rather than by replicating every full registry entry to every node.
Each node keeps its own full entries in node-local memory and publishes only
the summary of what it can serve. Cross-node routing is decided from the merged
summaries.

The payoff is scale. A registration's replicated footprint is **one small cell
per node that owns it**, not a full copy of the entry on every node in the
cluster. A cluster with many short-lived registrations replicates far less
state and does far less anti-entropy work.

This is how the registry always works — there is no mode to select and nothing
to configure to turn it on.

## How routing works

- **Local registrations and subscriptions** live only in the owning node's
  memory. They are never replicated.
- Each node maintains a **summary cell** per `(realm, match policy, URI)` it
  serves, and those cells replicate cluster-wide by anti-entropy. A peer
  compiles the merged cells into a **stub view** of who can serve what.
- **Dealer (calls).** To route a call whose callee is remote, a node picks the
  owning node from the stub view and forwards the call **node-addressed**. The
  receiving node then re-selects the callee among *its own* live local
  registrations (owner-side completion) rather than acting on the sender's
  possibly-stale choice of entry. If the chosen node's summary was momentarily
  stale, a bounded pre-invocation retry reroutes to another candidate before
  the call fails with `no_eligible_callee`. A progressive call invocation is
  not rerouted: the caller's later chunks follow the first to the node it
  reached, so a miss there is final (`bondy_rpc_retry_SUITE`).
- **Broker (events).** To publish to remote subscribers, a node discovers the
  subscriber *nodes* from the subscription stubs and relays one PUBLISH per
  such node; the receiving node matches and delivers to its own local
  subscribers.

Local calls and events never leave the node — they resolve against the local
registry directly.

## Restarts and clocks

A summary cell carries its node's latest *reading* of how many live entries it
has, stamped from a node-wide hybrid logical clock. On every replica the
highest-stamped reading wins, so a reading left over from before a restart is
replaced by the node's next one, never added to or subtracted from.

The registry lives in memory, in the node's `registry` database. Every open of
that database is followed by a restore that rewrites the node's summary cells
from its registry. It opens at boot, and again whenever one of its processes
dies in a running node: the node then closes and reopens the whole database
and logs `A process of the bondy_db registry DB died; reopening the DB` at
error level.

This relies on one operational rule: **a node's wall clock must not go back,
across a restart, past the last stamp the node issued.** A node restarted with
its clock stepped far enough back writes readings that lose to its own older
ones, and a peer may keep routing to callees the node no longer has. Keep node
clocks synchronised (NTP or equivalent) and never step a clock backwards
across a restart.

## When a node leaves

Only a node writes its own summary cells, so a node that is gone cannot remove
them. The other nodes reclaim them, and the stubs built from them, after the
node leaves the cluster membership: through `bondy.cluster.leave`, or through
its own graceful shutdown under `cluster.automatic_leave` (see
[Turning clustering off for a member](../configuration/clustering.md#turning-clustering-off-for-a-member)).
A node that has crashed or is partitioned, and has not left, keeps its cells
and stubs. A membership loss can be reversed, and a node that comes back needs
its routing.

Each remaining node reclaims a departed node's routing state in three stages,
each on its own schedule:

1. The origin-retirement pass reaps the departed node's origin from its
   summary cells, which leaves each cell with a count of zero. The pass runs on
   each membership change and every `db.oplog.origin_retirement.interval`.
2. The reclamation sweep discards the emptied cells once they are causally
   stable, every `db.oplog.reclaim.interval`. See
   [Understanding deletion and reclamation](../database/deletion_and_reclamation.md).
3. The consistency sweep deletes each stub of a non-member node whose cell is
   gone, every `registry.rib.check_interval`. With that interval set to `0`,
   a departed node's stubs are never removed.

`bondy_rib_reclamation_cluster_SUITE` covers this sequence. The
[reclamation configuration reference](../configuration/reclamation_options.md)
describes the first two settings.

Until its stubs are gone, a departed node still counts as a subscriber node. A
`PUBLISH` that matches its subscriptions is relayed to it, and the registry
meta API includes it in its walk. When the dealer chooses a node for a call,
it prefers reachable nodes, so a departed node's registrations take no call
while a reachable callee exists.

## Configuration

Routing on the RIB is unconditional; there is nothing to enable. One optional
setting runs the consistency sweep. It does not change what the registry
replicates.

### Consistency sweep

```
registry.rib.check_interval = 5m   # default; 0 disables
```

Each node periodically compares its summary cells against the registry ground
truth per realm and logs a warning naming any divergence. In steady state the
sweep finds nothing; a persistent divergence is worth investigating.

Before it compares, the sweep deletes the stubs of departed nodes whose cells
are gone (see [When a node leaves](#when-a-node-leaves)), and logs the count at
info level. `0` disables this deletion too. The setting therefore changes
which stubs a node keeps, not only what it reports.

## Observability

The summary machinery is instrumented on the wait-free metrics lane and
surfaced on the Admin API `/metrics` endpoint:

| Metric | Meaning |
|---|---|
| `bondy_registry_rib_members` | live local entries feeding the summaries |
| `bondy_registry_rib_stub_cells` | merged remote summary cells held for routing |
| `bondy_registry_rib_divergences` | divergences found by the last sweep |
| `bondy_rpc_rib_completions_total` `{outcome}` | owner-side callee re-selections (`ok`/`miss`) |
| `bondy_rpc_rib_retries_total` `{outcome}` | routing retries after a miss (`node`/`local`/`exhausted`) |

The bundled Grafana dashboard (`monitoring/`) has a **Registry RIB** section
covering these.
