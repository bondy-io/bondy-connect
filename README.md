![Bondy logo](https://github.com/bondy-io/bondy/blob/develop/doc/assets/bondy_bg.png?raw=true)

![Version](https://img.shields.io/badge/version-1.0.0-blue?style=for-the-badge)
![License](https://img.shields.io/badge/license-Apache%202.0-blue?style=for-the-badge)<br>
![Docker Pulls](https://img.shields.io/docker/pulls/leapsight/bondy?style=for-the-badge)
![Docker Build (master)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy/docker-debian.yaml?&branch=master&label=docker-master&style=for-the-badge)
![Docker Build (develop)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy/docker-debian.yaml?&branch=develop&label=docker-develop&style=for-the-badge)
<br>![Architectures](https://img.shields.io/badge/architecture-linux%2Famd64%20%7C%20linux%2Farm64%20%7C%20macOS%2Fintel%20%7C%20macOS%2FM1-lightgrey?style=for-the-badge)


# Bondy

### The distributed application networking platform

Bondy is an open source, always-on application networking platform. It connects
every part of a distributed application — web and mobile apps, IoT devices,
backend services and AI agents — through one secure protocol, so that each part
can call and notify the others without knowing where they run.

Bondy implements the open [Web Application Messaging Protocol](https://wamp-proto.org)
(WAMP): Remote Procedure Calls (RPC) and Publish/Subscribe in one router. Around
the router it adds an HTTP API Gateway, an MCP gateway, an HTTP connector,
broker bridges, identity management and role-based access control, all
replicated across the cluster.

> **Bondy is becoming Bondy Connect.** From 1.0.0 the release and its start
> script are named `bondy-connect`: run `bin/bondy-connect`, not `bin/bondy`.
> The `/bondy` paths, node names, `BONDY_*` environment variables and
> `etc/bondy.conf` are unchanged. See the [CHANGELOG](CHANGELOG.md).

<br>
<p align="center">
     <img src="https://github.com/bondy-io/bondy/blob/develop/doc/assets/bondy_cluster.png?raw=true" alt="A Bondy cluster connecting clients and services" width="600"/>
</p>
<br>

## What's new in 1.0.0

1.0.0 is a major release. Upgrading from `1.0.0-rc.65` or earlier needs a new
cluster: read the [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md)
and the *Action required* section of the [CHANGELOG](CHANGELOG.md) first.

- **A new storage and replication stack.** `bondy_db`, `bondy_oplog` and
  `bondy_mst` replace PlumDB and RocksDB. Every replicated table converges
  through operation-based CRDTs, with deletion and tombstone reclamation on by
  default.
- **Summary-based registry routing.** See
  [Registry routing](doc/guides/router/registry_routing.md).
- **Progressive Call Results and Progressive Call Invocations**, including
  across cluster nodes and through bridge relays.
- **Call deadlines and retries.** `CALL.Options._deadline` caps a whole call, and
  `CALL.Options._retries` re-routes a call to an `_idempotent` registration
  that gave no answer.
- **Procedure, topic and error reflection** through the `wamp.reflection.*`
  procedures.
- **Operator-defined listeners** (`listeners.$name.*`), validated at boot, with
  HTTP/2, Unix domain sockets, PROXY protocol, and suspend and resume to take a
  node out of rotation.
- **MCP gateway.** Serves the Model Context Protocol on any listener and maps
  MCP tools and resources onto WAMP procedures.
- **HTTP connector.** Registers WAMP procedures that call upstream HTTP
  services, with token acquisition and connection pooling.
- **Outbound mail** over SMTP relays.
- **Inbound rate limiting** per IP address, globally or per listener.
- **Observability.** Prometheus metrics, OpenTelemetry (OTLP) span export,
  alarms, and a bundled Prometheus, Tempo and Grafana stack under
  [`monitoring/`](monitoring/README.md).
- **Security hardening.** Ticket revocation that replicates to every node, a
  node that refuses to start on an insecure cluster peer plane unless told to
  allow it, optional encryption at rest of realm keys, and the fixes listed in
  the [CHANGELOG](CHANGELOG.md#security).
- **Erlang/OTP 29.**

## Documentation

- [developer.bondy.io](https://developer.bondy.io) — the documentation site.
- [`doc/guides/`](doc/guides) — the guides for this release: architecture,
  configuration, database, deployment, router and security.
- [CHANGELOG](CHANGELOG.md).

## Supported WAMP features

Bondy advertises its features in every `WELCOME`, under
`roles.dealer.features` and `roles.broker.features`. The features are a
property of the build, not of the configuration. See
[WAMP features](doc/guides/router/wamp_features.md) for how a session obtains
them and for the contracts of Bondy's extensions.

### Authentication

* [x] Anonymous
* [x] Cryptosign
* [x] Ticket
* [x] WAMP-CRA
* [x] WAMP-SCRAM
* [x] Cookie (validates a Bondy ticket issued by the OpenID Connect flow)

In addition Bondy provides:

* [x] Password
* [x] OAuth2 (Bondy acts as the token server)
* [x] Trust — admits a known user without credentials; for trusted networks only
* [x] OpenID Connect relying party — an HTTP login flow that issues a ticket for the `cookie` method
* [x] Same Sign-on — use a single set of credentials to sign on to multiple realms
* [x] Single Sign-on — combines Same Sign-on with Ticket authentication; the ticket signs on to multiple realms
* [x] Prototype realms — realms that inherit configuration from a prototype
* [x] Mutual TLS — client certificates verified at the TLS layer

### Basic profile

* [x] Remote Procedure Calls (Caller, Dealer, Callee)
* [x] Publish & Subscribe (Publisher, Broker, Subscriber)

### Advanced RPC features

* [x] Progressive Call Results
* [x] Progressive Call Invocations — streams call arguments from caller to callee; see [Progressive call invocations](doc/guides/router/progressive_calls.md)
* [x] Call Timeouts
* [x] Call Canceling — `skip`, `kill` and `killnowait`, also when the callee is on another node
* [x] Caller Identification
* [ ] Call Trust Levels — `INVOCATION.Details.trust_level` is always `0`
* [x] Pattern-based Registration — `exact`, `prefix` and `wildcard`
* [x] Shared Registration
     * [x] Single
     * [x] Round robin
     * [x] First
     * [x] Random
     * [x] Last
* [ ] Sharded Registration — caller side only: a CALL with `runmode = "partition"` and `rkey` reaches the callee its `rkey` hashes to; registration-side sharding is not implemented
* [ ] Call Re-Routing
* [x] Payload Passthru Mode
* [ ] Registration Revocation
* [x] Registration Meta API — `list`, `lookup`, `match`, `get`, `list_callees`, `count_callees`; events `on_register` and `on_unregister`
* [x] Procedure Reflection — `wamp.reflection.procedure.list` and `describe`

In addition Bondy provides:

* [x] Call deadline — `CALL.Options._deadline`; see [Call deadline](doc/guides/router/wamp_features.md#call-deadline)
* [x] Call retries — `CALL.Options._retries` with `REGISTER.Options._idempotent`; see [Call retries](doc/guides/router/wamp_features.md#call-retries)
* [x] Error reflection — `wamp.reflection.error.list` and `describe`
* [x] Caller authentication claims (`caller_auth_claims`)

### Advanced Pub/Sub features

* [x] Pattern-based Subscriptions — `exact`, `prefix` and `wildcard`
* [x] Publisher Exclusion
* [x] Publisher Identification
* [x] Subscriber Black- and Whitelisting — by session id, `authid` and `authrole`
* [x] Event Retention
* [ ] Publication Trust Levels
* [x] Payload Passthru Mode
* [ ] Sharded Subscriptions
* [ ] Event History
* [ ] Subscription Revocation
* [x] Subscription Meta API — `list`, `lookup`, `match`, `get`, `list_subscribers`, `count_subscribers`; events `on_subscribe` and `on_unsubscribe`
* [x] Topic Reflection — `wamp.reflection.topic.list` and `describe`

The `on_create` and `on_delete` registration and subscription meta events are
not published: a cluster cannot tell a URI's first and last registration
without coordinating its nodes.

### Other advanced features

* [ ] Session Meta API — `wamp.session.on_join`, `on_leave` and `get` are implemented; `list`, `count` and the `kill*` procedures are not
* [ ] Testament

### Transports

* [x] WebSocket
* [x] RawSocket over TCP and TLS
* [x] HTTP Longpoll (JSON)
* [x] E2E encryption (via Payload Passthru Mode)

In addition Bondy provides:

* [x] HTTP Server-Sent Events (SSE) — a variation of HTTP Longpoll that receives over SSE (JSON)
* [x] RawSocket over Unix domain sockets
* [x] HTTP/1.1 and HTTP/2 on every HTTP listener

### Serialization

* [x] JSON
* [x] MessagePack
* [x] CBOR
* [x] Erlang (`wamp.2.erl`, a subset of the Erlang external term format)
* [ ] JSON batched
* [ ] MessagePack batched
* [ ] CBOR batched

## Beyond the router

Bondy runs these alongside the WAMP router, in the same node:

- **HTTP API Gateway.** Maps HTTP requests to WAMP calls and publications,
  and HTTP responses back. API specifications are replicated to every node.
- **Admin API.** Manage realms, users, groups, grants and sources over HTTP
  or WAMP (`bondy.*` procedures).
- **MCP gateway.** Serves MCP over HTTP on listeners that declare the `mcp`
  service. It maps `tools/*` and `resources/*` onto WAMP, and can proxy
  upstream MCP servers as WAMP procedures.
- **HTTP connector.** Registers WAMP procedures backed by upstream HTTP
  services. See [HTTP connector](doc/guides/configuration/http_connector.md).
- **Broker bridges.** Re-publish WAMP events to Kafka, AWS SNS, Mailgun,
  SendGrid or an SMTP server.
- **Bridge relay.** Connects a realm on one cluster to a realm on another,
  for example an edge node to a core cluster. See
  [Bridge relay](doc/guides/configuration/bridge_relay.md).
- **Outbound mail.** Sends email through configured SMTP relays.
- **Rate limiting.** Token buckets per IP address for handshakes,
  authentication, connections, HTTP requests and messages. See
  [Load regulation and rate limiting](doc/guides/configuration/load_regulation_and_rate_limiting.md).
- **Export and import.** A logical export of the durable tables, through
  `bondy.export.*`.

## How Bondy is built

- **Distributed by design.** Bondy is a cluster of equal nodes: no node is
  special and any node accepts any session. A node keeps operating when other
  nodes or the network fail.
- **Transparent routing.** A message reaches its callee or subscribers
  wherever their sessions are in the cluster. Nodes connect in a full mesh, so
  a routed message takes one hop between nodes.
- **Replicated state.** Realms, identities, RBAC, API specifications and the
  registry are replicated to every node. Each table converges through
  operation-based CRDTs, and pull-based active anti-entropy over Merkle Search
  Trees repairs what a node missed. See
  [Database architecture](doc/guides/architecture/db_architecture.md) and
  [Convergence](doc/guides/database/convergence.md).
- **Partisan.** Nodes communicate over [Partisan](https://partisan.dev), a
  replacement for Distributed Erlang with separate channels for control and
  data traffic. Peers are found by DNS or a static list. See
  [Clustering](doc/guides/configuration/clustering.md).
- **Erlang/OTP.** Bondy runs on the BEAM, which provides lightweight processes,
  isolation and supervision for every session and subsystem.
- **Realm isolation.** Each realm has its own users, groups, permissions,
  authentication methods and routing namespace.

## Quick start

### Docker

1. Install and start [Docker](https://www.docker.com/get-started).
2. Download the [examples/custom_config](https://github.com/bondy-io/bondy/tree/develop/examples/custom_config/etc)
   folder, or clone this repository, and `cd` to the folder that contains
   `examples/`.
3. Run:

```shell
docker run \
--rm \
-e BONDY_ERL_NODENAME=bondy1@127.0.0.1 \
-e BONDY_ERL_DISTRIBUTED_COOKIE=bondy \
-u 0:1000 \
-p 18080:18080 \
-p 18081:18081 \
-p 18082:18082 \
-v "$PWD/examples/custom_config/etc:/bondy/etc" \
-v "/tmp/data:/bondy/data" \
leapsight/bondy:1.0.0
```

The example configuration runs a single node (`cluster.enabled = off`) with the
default listeners:

| Port  | Listener           | Serves |
|-------|--------------------|--------|
| 18080 | `api_gateway_http` | API Gateway, WAMP over WebSocket (`/ws`), SSE and Longpoll |
| 18081 | `admin`            | Admin API, WAMP over WebSocket, `/ping`, `/ready`, `/metrics` |
| 18082 | `wamp_tcp`         | WAMP RawSocket over TCP |

Images are published for `linux/amd64` and `linux/arm64` as
`leapsight/bondy:<version>` and `ghcr.io/bondy-io/bondy:<version>`.

### Building from source

#### Requirements

* macOS (Intel or Apple Silicon) or Linux (amd64 or arm64)
* [Erlang/OTP](https://www.erlang.org/) 29 or later (the release images use
  29.1.2)
* [rebar3](https://rebar3.org/) 3.27.0 or later (the release images use 3.28.0)
* [just](https://just.systems/), the task runner (`brew install just` or
  `cargo install just`)
* A C and C++ toolchain, `cmake` and `git`, to build the native dependencies
* OpenSSL

#### Building

Clone this repository and `cd` into it. Run `just` with no arguments to list
every recipe.

Build a production release tarball:

```shell
just release-tar
```

The tarball is written to `_build/prod/rel/bondy-connect/`. Unpack it where you
want to install Bondy, for example `~/tmp/bondy`:

```shell
mkdir -p ~/tmp/bondy
tar -zxvf _build/prod/rel/bondy-connect/bondy-connect-1.0.0.tar.gz -C ~/tmp/bondy
```

#### Running

From the install directory, run the start script with no arguments to list its
commands:

```shell
bin/bondy-connect
```

Run Bondy in the foreground, logging to stdout:

```shell
bin/bondy-connect foreground
```

Run Bondy with an interactive Erlang shell:

```shell
bin/bondy-connect console
```

## Local cluster

The `node1`, `node2` and `node3` recipes build and start three nodes on
`127.0.0.1`, each with its own configuration under `config/test/`.

| Listener              | node1 | node2 | node3 |
|-----------------------|-------|-------|-------|
| API Gateway HTTP, WebSocket | 18080 | 18180 | 18280 |
| Admin API HTTP, WebSocket   | 18081 | 18181 | 18281 |
| RawSocket TCP         | 18082 | 18182 | 18282 |
| API Gateway HTTPS     | 18083 | 18183 | 18283 |
| Admin API HTTPS       | 18084 | 18184 | 18284 |
| RawSocket TLS         | 18085 | 18185 | off   |
| Cluster peer          | 18086 | 18186 | 18286 |

### Start the first node

```shell
just node1
```

### Create a realm

Every WAMP session belongs to a realm. Create one through the Admin API:

```shell
curl -X POST "http://localhost:18081/realms" \
     -H 'Content-Type: application/json; charset=utf-8' \
     -H 'Accept: application/json; charset=utf-8' \
     -d '{"uri": "com.myrealm", "description": "My first realm"}'
```

Disable security on the realm, so that clients can connect without
credentials while you experiment:

```shell
curl -X DELETE "http://localhost:18081/realms/com.myrealm/security_enabled" \
     -H 'Accept: application/json; charset=utf-8'
```

### Start a second node

```shell
just node2
```

`node2` finds `node1` through peer discovery (a static list) within a few
seconds and joins the cluster. Anti-entropy then copies the realm you created
on `node1` to `node2`.

`node3` starts with peer discovery off. To add it to the cluster, set
`cluster.peer_discovery.enabled = on` in `config/test/node_3_bondy.conf.template`
before running `just node3`.

## Resources

* [bondy.io](https://www.bondy.io)
* [developer.bondy.io](https://developer.bondy.io) — documentation
* [WAMP specification](https://wamp-proto.org)
* [@bondyIO](https://twitter.com/bondyIO)
* Recorded webinar: [Implementing a polyglot microservices architecture](https://www.youtube.com/watch?v=XxJ1IS8mo84) (10 July 2019)

## License

Bondy is licensed under the [Apache License 2.0](LICENSE).

The Bondy documentation (https://developer.bondy.io) is copyright Leapsight and
licensed under CC-BY-SA 4.0, provided as-is without any warranties.
