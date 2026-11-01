![Bondy Connect logo](https://github.com/bondy-io/bondy-connect/blob/develop/doc/assets/bondy_bg.png?raw=true)

![Version](https://img.shields.io/badge/version-1.0.0-blue?style=for-the-badge)
![License](https://img.shields.io/badge/license-Apache%202.0-blue?style=for-the-badge)<br>
![Docker Pulls](https://img.shields.io/docker/pulls/leapsight/bondy-connect?style=for-the-badge)
![Docker Build (main)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy-connect/docker-debian.yaml?&branch=main&label=docker-main&style=for-the-badge)
![Docker Build (develop)](https://img.shields.io/github/actions/workflow/status/bondy-io/bondy-connect/docker-debian.yaml?&branch=develop&label=docker-develop&style=for-the-badge)
<br>![Architectures](https://img.shields.io/badge/architecture-linux%2Famd64%20%7C%20linux%2Farm64%20%7C%20macOS%2Fintel%20%7C%20macOS%2Fapple%20silicon-lightgrey?style=for-the-badge)

# Bondy Connect

### The distributed application networking platform

Bondy Connect is an open-source application networking platform. It connects
the parts of a distributed application — web and mobile apps, IoT devices,
backend services and AI agents — through one protocol. Each part calls and
notifies the others without knowing where they run.

Bondy Connect implements the
[Web Application Messaging Protocol](https://wamp-proto.org) (WAMP), an open
standard that combines Remote Procedure Calls (RPC) and Publish/Subscribe.
Around the WAMP router, Bondy Connect adds an HTTP API Gateway, an MCP gateway,
an HTTP connector, broker bridges, identity management and role-based access
control. A Bondy Connect cluster replicates realms, identities, permissions and
API specifications to every node.

> **Bondy is now Bondy Connect.** From 1.0.0:
>
> - The release and its start script are named `bondy-connect`. Run
>   `bin/bondy-connect`, not `bin/bondy`.
> - The Docker images are `leapsight/bondy-connect` and
>   `ghcr.io/bondy-io/bondy-connect`.
> - The repository is `github.com/bondy-io/bondy-connect`.
>
> The `/bondy` paths, node names, `BONDY_*` environment variables and
> `etc/bondy.conf` keep their names.

> **Upgrading from `1.0.0-rc.65` or earlier.** Bondy Connect 1.0.0 cannot
> read the data directory of an earlier release. Take a backup on the old
> release, wipe the data directory, and import the backup into 1.0.0. Read the
> [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md) and
> the *Action required* section of the [CHANGELOG](CHANGELOG.md) before you
> start.

<br>
<p align="center">
     <img src="https://github.com/bondy-io/bondy-connect/blob/develop/doc/assets/bondy_cluster.png?raw=true" alt="A Bondy Connect cluster connecting clients and services" width="600"/>
</p>
<br>

## How Bondy Connect works

- **A cluster of equal nodes.** No node is special, and any node accepts any
  session. A node keeps working when other nodes or the network fail.
- **Location-transparent routing.** A message reaches its callee or its
  subscribers on whichever node their sessions run. The nodes form a full mesh,
  so a routed message takes one hop between nodes.
- **Replicated state.** Every node holds the realms, identities, permissions,
  API specifications and registry. Each table converges through operation-based
  CRDTs. Pull-based active anti-entropy over Merkle Search Trees repairs what a
  node missed. See [Database architecture](doc/guides/architecture/db_architecture.md)
  and [Convergence](doc/guides/database/convergence.md).
- **Partisan.** The nodes talk over [Partisan](https://partisan.dev), a
  replacement for Distributed Erlang that keeps control and data traffic on
  separate channels. A node finds its peers through DNS or a static list. See
  [Clustering](doc/guides/configuration/clustering.md).
- **Erlang/OTP.** Bondy Connect runs on the BEAM. Every session and subsystem
  is a lightweight, isolated and supervised process.
- **Realm isolation.** A realm is a routing and administrative domain. Each
  realm has its own users, groups, permissions, authentication methods and URI
  namespace, and a session belongs to exactly one realm.

## Beyond the router

These components run in the same node as the WAMP router:

- **HTTP API Gateway.** Maps HTTP requests to WAMP calls and publications, and
  maps the results back to HTTP responses. The cluster replicates API
  specifications to every node.
- **Admin API.** Manages realms, users, groups, grants and sources, over HTTP
  or over WAMP through the `bondy.*` procedures.
- **MCP gateway.** Serves the Model Context Protocol over HTTP on any listener
  that declares the `mcp` service. It maps `tools/*` and `resources/*` onto
  WAMP, and it can expose upstream MCP servers as WAMP procedures.
- **HTTP connector.** Registers WAMP procedures that call upstream HTTP
  services. See [HTTP connector](doc/guides/configuration/http_connector.md).
- **Broker bridges.** Re-publish WAMP events to Kafka, AWS SNS, Mailgun,
  SendGrid or an SMTP server.
- **Bridge relay.** Connects a realm on one cluster to a realm on another, for
  example an edge node to a core cluster. See
  [Bridge relay](doc/guides/configuration/bridge_relay.md).
- **Outbound mail.** Sends email through configured SMTP relays.
- **Rate limiting.** Token buckets per IP address for handshakes,
  authentication, connections, HTTP requests and messages. See
  [Load regulation and rate limiting](doc/guides/configuration/load_regulation_and_rate_limiting.md).
- **Export and import.** A logical export of the durable tables, through the
  `bondy.export.*` procedures.

## What's new in 1.0.0

- **A new storage and replication stack.** `bondy_db`, `bondy_oplog` and
  `bondy_mst` replace PlumDB and RocksDB. Every replicated table converges
  through operation-based CRDTs. Deletion and tombstone reclamation are on by
  default.
- **Summary-based registry routing.** See
  [Registry routing](doc/guides/router/registry_routing.md).
- **Progressive Call Results and Progressive Call Invocations**, also across
  cluster nodes and through bridge relays.
- **Call deadlines and retries.** `CALL.Options._deadline` caps the duration of
  a whole call. `CALL.Options._retries` re-routes a call that got no answer to
  another `_idempotent` registration.
- **Procedure, topic and error reflection** through the `wamp.reflection.*`
  procedures.
- **Operator-defined listeners** (`listeners.$name.*`), validated at boot.
  Listeners support HTTP/2, Unix domain sockets and the PROXY protocol. Suspend
  and resume take a node out of rotation.
- **MCP gateway.** Serves the Model Context Protocol on any listener and maps
  MCP tools and resources onto WAMP procedures.
- **HTTP connector.** Registers WAMP procedures that call upstream HTTP
  services, with token acquisition and connection pooling.
- **Outbound mail** over SMTP relays.
- **Inbound rate limiting** per IP address, globally or per listener.
- **Observability.** Prometheus metrics, OpenTelemetry (OTLP) span export and
  alarms. [`monitoring/`](monitoring/README.md) bundles a Prometheus, Tempo and
  Grafana stack.
- **Security hardening.**
  - A revoked ticket is revoked on every node.
  - A node refuses to start on an insecure cluster peer plane unless its
    configuration allows it.
  - Realm keys can be encrypted at rest.
  - The [CHANGELOG](CHANGELOG.md#security) lists the security fixes.
- **Erlang/OTP 29.**

## Quick start

### Docker

1. Install and start [Docker](https://www.docker.com/get-started).
2. Download the [examples/custom_config](https://github.com/bondy-io/bondy-connect/tree/develop/examples/custom_config/etc)
   folder, or clone this repository. Then `cd` to the folder that contains
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
leapsight/bondy-connect:1.0.0
```

The example configuration runs a single node (`cluster.enabled = off`) with the
default listeners:

| Port  | Listener           | Serves |
|-------|--------------------|--------|
| 18080 | `api_gateway_http` | API Gateway, WAMP over WebSocket (`/ws`), SSE and Longpoll |
| 18081 | `admin`            | Admin API, WAMP over WebSocket, `/ping`, `/ready`, `/metrics` |
| 18082 | `wamp_tcp`         | WAMP RawSocket over TCP |

The images are built for `linux/amd64` and `linux/arm64`. They are published as
`leapsight/bondy-connect:<version>` and `ghcr.io/bondy-io/bondy-connect:<version>`.
From 1.0.1, each version also has an Alpine Linux image, `<version>-alpine`.

### Building from source

#### Requirements

* macOS (Intel or Apple silicon) or Linux (amd64 or arm64)
* [Erlang/OTP](https://www.erlang.org/) 29 or later. The release images use
  29.1.2.
* [rebar3](https://rebar3.org/) 3.27.0 or later. The release images use 3.28.0.
* [just](https://just.systems/), the task runner (`brew install just` or
  `cargo install just`)
* A C and C++ toolchain, `cmake` and `git`, to build the native dependencies
* OpenSSL

#### Building

Clone this repository and `cd` into it. To list every recipe, run `just` with
no arguments.

To build a production release tarball, run:

```shell
just release-tar
```

The recipe writes `_build/prod/rel/bondy-connect/bondy-connect-1.0.0.tar.gz`
and unpacks a copy into `_build/tar`. To install Bondy Connect somewhere else,
unpack the tarball there, for example into `~/tmp/bondy`:

```shell
mkdir -p ~/tmp/bondy
tar -zxvf _build/prod/rel/bondy-connect/bondy-connect-1.0.0.tar.gz -C ~/tmp/bondy
```

#### Running

Run these commands from the install directory. With no arguments, the start
script lists its commands:

```shell
bin/bondy-connect
```

To run Bondy Connect in the foreground and log to stdout:

```shell
bin/bondy-connect foreground
```

To run Bondy Connect with an interactive Erlang shell:

```shell
bin/bondy-connect console
```

## Local cluster

The `node1`, `node2` and `node3` recipes build and start three nodes on
`127.0.0.1`. Each node reads its own configuration from `config/test/`.

| Listener                    | node1 | node2 | node3 |
|-----------------------------|-------|-------|-------|
| API Gateway HTTP, WebSocket | 18080 | 18180 | 18280 |
| Admin API HTTP, WebSocket   | 18081 | 18181 | 18281 |
| RawSocket TCP               | 18082 | 18182 | 18282 |
| API Gateway HTTPS           | 18083 | 18183 | off   |
| Admin API HTTPS             | 18084 | 18184 | off   |
| RawSocket TLS               | 18085 | 18185 | off   |
| Cluster peer                | 18086 | 18186 | 18286 |

### Start the first node

```shell
just node1
```

### Create a realm

Every WAMP session belongs to a realm. Create one through the Admin API on the
node's local socket, which needs no credentials:

```shell
SOCK=_build/node1/rel/bondy-connect/run/bondy_admin.sock
curl --unix-socket "$SOCK" -X POST "http://localhost/realms" \
     -H 'Content-Type: application/json; charset=utf-8' \
     -H 'Accept: application/json; charset=utf-8' \
     -d '{"uri": "com.myrealm", "description": "My first realm"}'
```

While you experiment, disable security on the realm so that clients can connect
without credentials:

```shell
curl --unix-socket "$SOCK" \
     -X DELETE "http://localhost/realms/com.myrealm/security_enabled" \
     -H 'Accept: application/json; charset=utf-8'
```

On port 18081 the Admin API needs a bearer token from the master realm. See
[Authenticating to the Admin API](doc/guides/configuration/listeners.md#authenticating-to-the-admin-api).

### Start a second node

```shell
just node2
```

`node2` finds `node1` in its static peer list and joins the cluster within a
few seconds. Anti-entropy then copies the realm you created on `node1` to
`node2`.

`node3` starts with peer discovery off. To add it to the cluster, set
`cluster.peer_discovery.enabled = on` in `config/test/node_3_bondy.conf.template`
before you run `just node3`.

## Supported WAMP features

Bondy Connect advertises its features in every `WELCOME` message, under
`roles.dealer.features` and `roles.broker.features`. The build fixes the
features; configuration does not change them. See
[WAMP features](doc/guides/router/wamp_features.md) for how a session obtains
them and for the contracts of Bondy Connect's extensions.

### Authentication

* [x] Anonymous
* [x] Cryptosign
* [x] Ticket
* [x] WAMP-CRA
* [x] WAMP-SCRAM
* [x] Cookie (validates a Bondy Connect ticket issued by the OpenID Connect flow)

In addition, Bondy Connect provides:

* [x] Password
* [x] OAuth2, with Bondy Connect as the token server
* [x] Trust — admits a known user without credentials; for trusted networks only
* [x] OpenID Connect relying party — an HTTP login flow that issues a ticket for the `cookie` method
* [x] Same Sign-on — one set of credentials signs on to several realms
* [x] Single Sign-on — Same Sign-on combined with Ticket authentication; one ticket signs on to several realms
* [x] Prototype realms — realms that inherit configuration from a prototype
* [x] Mutual TLS — the TLS layer verifies client certificates

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

In addition, Bondy Connect provides:

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

Bondy Connect does not publish the `on_create` and `on_delete` meta events for
registrations or subscriptions. A cluster cannot tell a URI's first and last
registration without coordinating its nodes.

### Other advanced features

* [ ] Session Meta API — `wamp.session.on_join`, `on_leave` and `get` are implemented; `list`, `count` and the `kill*` procedures are not
* [ ] Testament

### Transports

* [x] WebSocket
* [x] RawSocket over TCP and TLS
* [x] HTTP Longpoll (JSON)
* [x] E2E encryption (via Payload Passthru Mode)

In addition, Bondy Connect provides:

* [x] HTTP Server-Sent Events (SSE) — a variant of HTTP Longpoll that receives over SSE (JSON)
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

## Documentation

- [developer.bondy.io](https://developer.bondy.io) — the documentation site.
- [`doc/guides/`](doc/guides) — the guides for this release: architecture,
  configuration, database, deployment, router and security.
- [CHANGELOG](CHANGELOG.md).

## Resources

* [bondy.io](https://www.bondy.io)
* [WAMP specification](https://wamp-proto.org)
* [@bondyIO](https://twitter.com/bondyIO)
* Recorded webinar: [Implementing a polyglot microservices architecture](https://www.youtube.com/watch?v=XxJ1IS8mo84) (10 July 2019)

## License

Bondy Connect is licensed under the [Apache License 2.0](LICENSE).

The Bondy Connect documentation (https://developer.bondy.io) is copyright Leapsight and
licensed under CC-BY-SA 4.0. It is provided as-is, without any warranties.
