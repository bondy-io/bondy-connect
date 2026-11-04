# CHANGELOG
## Unreleased

### Fixes
* A request to the Admin API or to an API Gateway `oauth2` path with no `Authorization: Bearer` header, or with a bearer value that is not a JWT, got `401` with an `internal_error` body and a `trace_id` that matched no log entry. The body now names the refusal as `bondy.error.token_invalid`.
* The `WWW-Authenticate: Bearer` challenge of a `401` follows RFC 6750 on the Admin API, API Gateway `oauth2` paths, the credential-verification endpoints and the MCP endpoint. A request that presented no bearer token gets `Bearer realm="<realm>"` with no error. A presented token that is refused gets `error="invalid_token"`. Before, the gateway sent Bondy's own error code (for example `error="invalid_credentials"`) together with non-standard `message` and `description` parameters, the verification endpoints sent `invalid_token` also when no credential was presented, and MCP sent a bare `Bearer` with no parameters. A gateway `401` caused by a token for a realm that does not exist now carries the challenge; before, it had none. The `Cookie`, `Basic` and `ApiKey` challenges do not change.

## 1.1.0

### Action required
* A node refuses to start when `bondy.conf` sets a key that this release does not read: a renamed key, a removed key or a typo. The error names each such key and the closest key the release knows. Earlier releases ignored such a key without a word, so its setting silently stayed at the default. Check your `bondy.conf` with `scripts/migrate_conf.escript check` before you upgrade.
* The `db.*` keys of `bondy.conf` are grouped by the component they configure, so most of them have a new name. A node refuses to start on a `bondy.conf` that still uses an old name, and the error names the new key. Before you upgrade, run `scripts/migrate_conf.escript check <path>/bondy.conf` from this repository: it lists every old key with its new name, and `migrate` writes the converted file. The renames:
  * `db.aae`, `db.aae.*` → `db.oplog.aae`, `db.oplog.aae.*`
  * `db.wal.*` → `db.oplog.wal.*`
  * `db.pack_auto_seal_bytes` → `db.oplog.pack.auto_seal_bytes`
  * `db.pack_seal_mode` → `db.oplog.pack.seal_mode`
  * `db.gc_interval` → `db.oplog.heap_gc.interval`
  * `db.gc_heap_delta` → `db.oplog.heap_gc.delta`
  * `db.gc_max_concurrency` → `db.oplog.compaction.max_concurrency`
  * `db.frontier.hole_alarm` → `db.oplog.frontier.hole_alarm`
  * `db.drain.stall_alarm` → `db.oplog.drain.stall_alarm`
  * `db.reclaim`, `db.reclaim.*` → `db.oplog.reclaim`, `db.oplog.reclaim.*`
  * `db.origin_retirement`, `db.origin_retirement.*` → `db.oplog.origin_retirement`, `db.oplog.origin_retirement.*`
  * `db.journal_trim_interval` → `db.leveled.journal.trim_interval`
  * `db.primary_scan_limit` → `db.index.primary_scan_limit`

  The keys under `db.main.*`, `db.registry.*` and `db.leveled.*` keep their names. Values, units and defaults do not change.

### Changes
* New `bondy.conf` keys tune the reclamation of a durable table's anti-entropy tree, which 1.0.2 could set only in the application environment: `db.oplog.pack.gc.interval` (default `1h`), `db.oplog.pack.gc.growth_factor` (default `2`, at least 2) and `db.oplog.pack.gc.min_records` (default `10000`). See `doc/guides/configuration/database_options.md`.

## 1.0.2

### Fixes
* The pages a durable table's anti-entropy tree no longer used were reclaimed at most once an hour, and never in a node's first hour after boot, while they grow with every write. A burst of writes, such as a restore or a re-sync, could fill the data volume under `bondy_db/mst` before the first reclamation, and a node that then restarted onto the full volume could not open its storage. Reclamation now also runs once a shard's tree has doubled since the last one, so the space it holds follows the write volume instead of the clock.

## 1.0.1

### Action required
* `oauth2.refresh_token.limit` is a whole number of tokens, 1 or more. It used to accept a size, so `25KB` meant 25600 tokens and `0` was accepted. A `bondy.conf` that writes the key with a unit suffix, or as `0`, now stops configuration generation at boot with an error naming the key; write the number of tokens instead. The default, 25, is unchanged.
* The Admin API needs an OAuth2 bearer token from the master realm on every listener that carries `admin_api` (port 18081 by default), and answers `401` without one. Since the master-realm hardening it answered `403` to every request; a deployment that granted `anonymous` again on the master realm to use it served administration without credentials. To use it over the network, add `oauth2` to the master realm's `authmethods` and an `oauth2` source for your administrators' network, then get tokens from `/oauth/token` on the same listener. The internal socket `<platform_runtime_dir>/bondy_admin.sock` needs no token. See [Authenticating to the Admin API](doc/guides/configuration/listeners.md#authenticating-to-the-admin-api).
* `bondy.user.update` (`PUT /realms/:realm_uri/users/:id`), `bondy.oauth2.client.update` (`PUT /realms/:realm_uri/clients/:id`) and `bondy.oauth2.resource_owner.update` (`PUT /realms/:realm_uri/resource_owners/:id`) reject a `password` or `client_secret` with `wamp.error.invalid_argument` (HTTP 400). They used to return success, leave the credential unchanged and close the user's sessions. Set a password or client secret with `bondy.user.change_password` (`POST /realms/:realm_uri/users/:id/change_password`).
* On a realm with security enabled, sources now apply to an OIDC user Bondy holds no user record for, which is the case when the provider does not set `auto_provision`. This covers a WAMP session opened with the ticket cookie, an API Gateway `oidc` path and the Admin API's cookie path. Such a user used to be admitted from any address, whatever the realm's sources said. Add sources that allow `oidcrp` and `cookie` to `all` from the networks your OIDC users connect from, for example `{"usernames": "all", "authmethod": "oidcrp", "cidr": "0.0.0.0/0"}` and the same with `cookie`. Without them, the WAMP session is refused and the HTTP request gets `401`. A source that names users cannot cover such a user, because it requires the users to exist. See *Source* on developer.bondy.io.
* The credential verification route (`<base_path>/oidc/verify`, `<base_path>/oauth/verify`) now applies the realm's `authmethods` and sources, as a WAMP session does. Each credential is checked under its own method: `oidcrp` for a ticket the OIDC login flow issued, `ticket` for any other ticket, `oauth2` for an access token. A credential sent in the ticket cookie also needs `cookie`. A realm whose verify route answered `200` needs those methods among its `authmethods` and sources allowing them. The route sees the reverse proxy's address unless the listener trusts the proxy's forwarding headers (`proxy_protocol.trusted_proxies`), so either forward the client's address from a trusted proxy or write the source for the proxy's address. See [Verifying Credentials over HTTP](doc/guides/security/verifying_credentials_over_http.md#what-is-verified).

* `cookie` in a realm's `authmethods` and sources now means what it means in the WAMP specification: a credential may arrive in a cookie. The OIDC credential has its own method, `oidcrp`, which Bondy did not check before. A ticket the OIDC login flow issued needs `oidcrp`, a ticket from `bondy.ticket.issue` needs `ticket`, and either one sent in the ticket cookie also needs `cookie`, each with a source that allows it. This applies to WAMP sessions opened with the cookie, API Gateway `oidc` paths, the Admin API and the verify route. A ticket from `bondy.ticket.issue` sent in the cookie used to be admitted under `cookie` alone. For now, `cookie` still admits an OIDC ticket that `oidcrp` does not, and Bondy logs the warning "The realm admitted an OIDC credential through the 'cookie' method" once per realm on each node; a later release removes this. Add `oidcrp` to the realm's `authmethods` and a source that allows it, for example `{"usernames": "all", "authmethod": "oidcrp", "cidr": "0.0.0.0/0"}`.
* The OIDC login applies the same check before it issues the ticket cookie: the realm must admit `oidcrp` (or, for now, `cookie`) for the user from the client's address. Otherwise the callback (`<base_path>/oidc/<provider>/callback`) answers `403` with `no_authmethod`, and `auto_provision` creates no user. It used to issue the ticket whatever the realm's methods and sources said.

* `security.oidc.providers.enabled`, `security.oidc.providers.<id>.login_path` and `security.oidc.providers.<id>.redirect_path` are removed. Nothing read them: OIDC providers are configured on the realm, in `info.oidc_providers`, and the login and callback routes come from the API Gateway specification. A node that still sets them boots and ignores them; `scripts/migrate_conf.escript check` lists them. Delete them from `bondy.conf`.
* MCP requests to a realm with security enabled matched the realm's sources against the socket peer, ignoring the listener's `proxy_protocol` settings. Behind a trusted proxy (`proxy_protocol.trusted_proxies`), sources now match the client address the proxy forwards, as on the API Gateway and Admin API. With `proxy_protocol.mode = strict`, a request from a trusted proxy that forwards no client address is answered `403`, as on the API Gateway. A realm whose sources admitted the proxy's address for MCP callers needs sources for the clients' networks instead.

### New Features
* The Admin API also accepts the master realm's OIDC ticket cookie, from a request without an `Authorization` header, when the master realm's `authmethods` include `cookie` and a source allows it from the client's address. Requests other than `GET`, `HEAD` and `OPTIONS` need the CSRF token in `x-csrf-token`. The login endpoints come from an API Gateway specification bound to the master realm with the `oidc` scheme. See [Authenticating to the Admin API](doc/guides/configuration/listeners.md#authenticating-to-the-admin-api).
* An API Gateway path whose specification declares the `oidc` security scheme now authenticates with the realm's OIDC ticket cookie (`bondy_ticket_<realm_uri>`), the way a WAMP session opened with that cookie does: the realm's `authmethods` must include `cookie`, and the ticket's scope and issuer must match the realm. A request other than `GET`, `HEAD` or `OPTIONS` must also send the `bondy_csrf_<realm_uri>` cookie's value in `x-csrf-token`, or gets `403`. Such paths used to answer `500` to every request.
* The `bondy_auth_fence_closed` alarm (critical) is raised when the authentication freshness fence has refused every new authentication for longer than `db.aae.fence.alarm` (default `5m`, `0` disables), and cleared when it admits again. It does not affect readiness. See [Database options](doc/guides/configuration/database_options.md).
* `bondy.export.import` (and its alias `bondy.backup.restore`) takes `dry_run`: with `{"filename": ..., "dry_run": true}` it reads the whole file as an import does, converts each record as the import would, and writes nothing. `bondy.export.status` with the filename of the file being imported, or of the last one imported, now adds an `import` report: the outcome, the records read, the records written per table (for a dry run, those it would write), the records skipped per reason, and the unreadable bytes. The report is updated after every write, so after a failed import it shows what was written. See *Export & Backup* on developer.bondy.io.
* Alpine Linux images are published again, for `linux/amd64` and `linux/arm64`, as `<version>-alpine` (`leapsight/bondy-connect:1.0.1-alpine`, `ghcr.io/bondy-io/bondy-connect:1.0.1-alpine`). The image without a suffix, and `latest`, stay on Debian.

### Fixes
* On an API Gateway `oidc` path of a realm with no OIDC providers configured, including one whose providers were removed by a realm update, `/oidc/login` answered `500`; it now answers `404` with `unknown_provider`. `/oidc/logout` with an OIDC ticket cookie from such a realm also answered `500`; it now clears the cookies and redirects. `/oidc/login` and the `/oidc/<provider>/callback` path of a realm deleted while its route was still mounted answered `500`; they now answer `404` with `no_such_realm` (`wamp.error.no_such_realm`).
* `bondy.user.enable` and `bondy.user.disable` answered `bondy.error.internal_error` for a username the realm does not hold. They now answer `wamp.error.no_such_principal`, as `bondy.user.update` does. `bondy.user.is_enabled`, `bondy.user.add_alias` and `bondy.user.remove_alias` already answered `wamp.error.no_such_principal` for such a name, but each call also logged a warning with a stack trace. They no longer log it, and neither does `bondy.user.add_alias` for a user linked to an SSO realm that no longer holds the user.
* A reserved user or group name, such as `all` or `anonymous`, got `bondy.error.internal_error` from `bondy.user.update`, `bondy.user.delete`, `bondy.user.enable`, `bondy.user.disable`, `bondy.group.update`, `bondy.group.delete`, `bondy.oauth2.client.update`, `bondy.oauth2.client.delete`, `bondy.oauth2.resource_owner.update` and `bondy.oauth2.resource_owner.delete`, and `anonymous` got it from `bondy.user.add_alias`. These calls now answer `bondy.error.invalid_value`, as `bondy.user.add` and `bondy.group.add` already did.
* An OIDC provider kept the realm's first `issuer` and `allow_unsafe_http` until the node restarted. After a change to the realm's `oidc_providers`, or after the realm was deleted and created again with the same URI, logins on that node still went to the old issuer. Each node also kept fetching the provider's metadata after the realm was deleted. A change now takes effect at the provider's next use on each node, and deleting a realm stops its providers' work on every node.
* `bondy.user.remove_alias` (`DELETE /realms/:realm_uri/users/:id/aliases/:alias`) deleted the name it was given even when the user did not hold it, and answered success. Naming another user's alias removed that alias from its owner; naming another user's username deleted that user's record. A name the user does not hold is now left with its holder, and deleting a user clears only the aliases it holds. If this call was ever made with a name the user did not hold, check that the aliases and users it named still exist.
* With `security.rate_limit` enabled, requests that authentication refused were not throttled: a flood of missing or invalid bearer tokens on API Gateway and Admin API routes, or of bad client credentials on `/oauth/token`, got `401` without limit. The `http` class (API Gateway and Admin API routes) and the `auth` class (the OAuth2 endpoints) are now charged before authentication, so these requests count and get `429` once the budget is spent. Authenticated requests are charged once, as before.
* `bondy.user.remove_group`, `bondy.group.add_group`, `bondy.group.add_groups` and `bondy.group.remove_group` stored the change and then answered `bondy.error.internal_error`. They now answer an empty result, as the other membership procedures do. A client that treated the error as a failed call and retried, or reported it, can stop.
* A source naming a user, and a permission granted to the user by name, did not apply to the user's OIDC ticket cookie when the IdP's spelling of the authid differed in case from the stored, casefolded username. This affected WAMP sessions opened with the cookie, API Gateway `oidc` paths and the Admin API. The stored username is now the caller's authid.
* Setting `security.oidc.providers.<id>.issuer` made configuration generation fail: cuttlefish stopped with an error in the `security.oidc.providers` translation and wrote no configuration for any key. The key now generates. A `security.oidc.providers.<id>` entry without `issuer`, an http or https URL with a host, or without `client_id` is left out, and the configuration generator prints a warning naming it when the node starts. These keys are reserved for a node registry of OIDC providers and this release does not use them.
* An API Gateway path whose specification declares the `basic` or `api_key` security scheme answered `500` to every request. Bondy does not enforce these schemes, so such a path now answers `401` with `wamp.error.authentication_failed`, and still never serves the request.
* An `Authorization: Bearer` value that is not a JWT got `400` and an error report with a stack trace, on API Gateway `oauth2` paths and on the Admin API. It now gets `401`. WAMP `oauth2` authentication with such a token logged an error report and failed with `internal_error`; it now fails as an invalid grant, without the report.
* On an API Gateway `oidc` path and on the Admin API, the CSRF token was checked against the CSRF cookie paired with the first ticket cookie the browser sent, which could belong to another realm. A browser signed in to several realms could therefore get `403` on a valid request. The token is now checked against the pair of the realm whose ticket cookie authenticated the request.
* A user whose password was stored before the 1.2 password format (`1.0` or `1.1` records, as a legacy backup import carries them) was offered WAMP-CRA, and the challenge crashed the connection. Such a password now serves the `password` method and the OAuth2 password grant only; changing it stores the current format, which WAMP-CRA and WAMP-SCRAM accept.
* A refused WAMP authentication is logged at `info` as "WAMP authentication failed", with the reason, the authid, the method being answered and the requested methods; the realm and source IP are in the log metadata. The client still receives the generic `wamp.error.authentication_failed`.
* Partisan 6.3.2. A node that crashed and returned on a new address, such as a Kubernetes StatefulSet pod recreated with a new IP, left its previous address in the cluster membership, and every node kept retrying it. The previous address is now pruned, and the returning node is not reported down when it is. See the [Partisan changelog](https://github.com/lasp-lang/partisan/blob/v6.3.2/CHANGELOG.md).
* The master-realm hardening warnings and the default admin password warning no longer contain internal review identifiers ("(D-1)", "(D-2)"). A log alert that matched them needs updating.
* The warning that the master realm `admin` user still has the legacy password `bondy-admin` said to rotate it with `security.admin_user.password`. That key only sets the password when the master realm is created, so it has no effect on an existing install. The warning now says to call `bondy.user.change_password`.
* The Admin API on the internal `admin_local` Unix socket ran every request as `anonymous`, which a hardened master realm refuses, so it answered 403 to everything. Requests on that socket now act as the local operator (authid `<admin_local>`) and are not subject to RBAC: only the node's Unix user and root can open the socket (mode 0600). It stays usable after every master-realm administrator is deleted or loses their grants. No other listener, including an operator-defined Unix socket listener, gets this mode.
* Importing a backup whose last record was cut short, for example by an interrupted copy, failed with `function_clause` after reading the whole file. The records before the cut were written, but the legacy OAuth2 refresh tokens were not, because they are written at the end. The import now skips the unreadable bytes, counts them in `bad_bytes` in the import report and the `Import finished` log, and imports every complete record, refresh tokens included. A node that ran such an import can import the same file again.
* `bondy.export.status` with the filename of one file while an import of another ran answered `{error, {name_already_open, log}}`. It now reads the file's header.
* An import of the current export format counted an entry for a table the node does not provision, and a term that is not an entry, as read only. Both now count as skipped, under `{table_not_provisioned,<table>}` and `unknown_term`.
* An HTTP request resolves the client's source IP for rate limiting only when a rate limit applies to it (`security.rate_limit`, the listener's `rate_limit` or the realm's `rate_limit`). With rate limiting off, the throttle check skips the proxy-protocol lookup.

## 1.0.0

### Action required
* The release and its start script are named `bondy-connect`: run `bin/bondy-connect` in place of `bin/bondy`, and the tarball is `bondy-connect-1.0.0.tar.gz`. The Docker images start `bondy-connect foreground`. The `/bondy` paths, node names, `BONDY_*` environment variables and `etc/bondy.conf` are unchanged.
* Images are published as `leapsight/bondy-connect` on Docker Hub and `ghcr.io/bondy-io/bondy-connect` on GHCR, and the repository is `github.com/bondy-io/bondy-connect`. Update image references and git remotes. The `leapsight/bondy` and `ghcr.io/bondy-io/bondy` images stay pullable but receive no new tags.
* Upgrading from `1.0.0-rc.65` (or previous versions) requires a new cluster: PlumDB data is not readable by this release. See the [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md).
* A single-node deployment must set `cluster.enabled = off`; with `on` and no other member, compaction, reclamation, origin retirement and the authentication freshness fence hold. See [Clustering](doc/guides/configuration/clustering.md#running-a-single-node).
* Listeners are declared under `listeners.$name.*`; the fixed per-scheme listener keys are removed, and every enabled `tls` listener must state its certificate. See [Listeners](doc/guides/configuration/listeners.md#migrating-from-the-pre-10-keys).
* `listeners.$name.linger.timeout` is in seconds; a value written with a unit suffix changes meaning (`scripts/migrate_conf.escript check` reports it). See [Listeners](doc/guides/configuration/listeners.md).
* Renamed or removed `bondy.conf` keys: `wamp.transport_queue.*` → `wamp.http_transport.*`; the global `wamp.{websocket,sse,longpoll}.*` blocks, the thirty `wamp.broker.*`/`wamp.dealer.*` feature keys, `wamp.dealer.pattern_based_registration`, `wamp.broker.pattern_based_subscription`, `store.*`, `oplog.core.scan_max_concurrency` and `db.compaction.peer_timeout` are removed; `rpc_gateway.*` is `http_connector.*`. `scripts/migrate_conf.escript` reports and rewrites them.
* `advanced.config` stanzas for the router move from `{bondy, …}` to `{bondy_router, …}`, and remote-console module names changed. See the [migration guide](doc/guides/configuration/migrating_from_1.0.0-rc.65.md).
* A custom `bondy_oplog_cache_adapter` must implement `ticket/1` and `fill/5` in place of `put/4`.
* An API Gateway specification with a key the parser does not know is refused, at the host, version, path, method, action and response levels, in `defaults` and in a security scheme; a misspelt key used to be dropped and its default applied. A security scheme's `scopes` is refused: the gateway checks no OAuth2 scope.
* The `wamp.registration.*`, `wamp.subscription.*`, `wamp.session.get` and `wamp.reflection.*` procedures take the arguments the WAMP specification gives and read the caller's realm; none takes a realm argument. A client that named the realm as the first argument drops it, and a master-realm session that read another realm calls the realm-first `bondy.*` procedure instead: `bondy.registration.get`, `bondy.registration.list_callees`, `bondy.registration.count_callees`, `bondy.subscription.get`, `bondy.subscription.list_subscribers` and `bondy.subscription.count_subscribers` are new for this. `wamp.registration.match` returns one id; `wamp.registration.get` and `wamp.subscription.get` take no `details` argument.
* `bondy.registration.callee.list`, `bondy.user.change_password` and `bondy.source.match` require the realm as their first argument: each also takes an optional trailing argument, so an omitted realm made a call readable two ways.
* The Admin API's `/realms/:realm_uri/registrations_summary` and `/realms/:realm_uri/subscriptions_summary` are removed; `/realms/:realm_uri/registrations` and `/realms/:realm_uri/subscriptions` list every id with its match policy.
* The `wamp_call` action's `retry_timeout` is removed. Its `retries` becomes the CALL option `_retries` when the action's `options` set none, so the dealer retries only a registration that set `_idempotent`.
* `REGISTER.Options.invoke` takes only the WAMP invocation policies (`single`, `roundrobin`, `random`, `first`, `last`): `jump_consistent_hash`, `queue_least_loaded`, `queue_least_loaded_sample` and their short names `jch`, `qll` and `qlls` are refused. The `_routing_key` option of CALL, CANCEL and PUBLISH is removed; a partitioned CALL names its key with `rkey`.

### New Features
* New storage and replication stack replacing PlumDB/RocksDB: `bondy_db` on `bondy_oplog` and the vendored `bondy_mst`. See [Database architecture](doc/guides/architecture/db_architecture.md) and [Database options](doc/guides/configuration/database_options.md).
* Op-based CRDT convergence per table, with per-cell hybrid logical clocks. See [Convergence](doc/guides/database/convergence.md).
* Deletion with causal-stability tombstone reclamation and origin retirement, both on by default. See [Deletion and reclamation](doc/guides/database/deletion_and_reclamation.md) and [Reclamation options](doc/guides/configuration/reclamation_options.md).
* Authentication freshness fence (`db.aae.fence.*`). See [Database options](doc/guides/configuration/database_options.md).
* Replicated security reactions: a credential change or user deletion on one node closes the user's sessions on every node; the `[bondy, aae, merge_conflict]` event. See [Replicated security state](doc/guides/security/replicated_security_state.md).
* Group membership stored as one replicated fact per (user, group).
* Summary-based registry routing (RIB). See [Registry routing](doc/guides/router/registry_routing.md).
* Progressive Call Results and Progressive Call Invocations, including across cluster nodes. See [Progressive call results](doc/guides/router/progressive_call_results.md) and [Progressive call invocations](doc/guides/router/progressive_calls.md).
* `CALL.Options._deadline` caps a whole call. See [WAMP features](doc/guides/router/wamp_features.md).
* Optional encryption at rest of realm private keys (`security.master_key.*`, off by default). See [Realm key encryption](doc/guides/security/realm_key_encryption.md).
* HTTP/2 on every `http` listener. See [Listeners](doc/guides/configuration/listeners.md#http-versions).
* Operator-defined listeners (`listeners.$name.*`), validated at boot. See [Listeners](doc/guides/configuration/listeners.md).
* `bondy.listener.suspend` and `bondy.listener.resume` take a node out of rotation and back. See [Listeners](doc/guides/configuration/listeners.md#taking-a-node-out-of-rotation).
* `scripts/migrate_conf.escript` checks and rewrites a `bondy.conf`. See [Checking your configuration](doc/guides/configuration/checking_your_configuration.md).
* One error payload for every transport. See the [error catalogue](doc/guides/reference/error_catalogue.md).
* `cluster.enabled = off` runs a node without clustering; it compacts and reclaims on its own frontier. New error `bondy.error.cluster_disabled` (`K004`). See [Clustering](doc/guides/configuration/clustering.md).
* `CALL.Options._retries` asks the dealer to retry a call that got no answer, when the registration is `_idempotent`, until the call's `_deadline` or `_retries + 1` timeouts. `bondy_connect_sdk` waits for the whole window.
* The API Gateway `forward` action retries a request that got no response when its method is idempotent.

### Security
* Inbound rate limiting (`security.rate_limit.*`, off by default). See [Load regulation and rate limiting](doc/guides/configuration/load_regulation_and_rate_limiting.md).
* Forwarding headers are honoured only from a trusted proxy. See [Listeners](doc/guides/configuration/listeners.md#proxy-protocol-and-forwarded-headers).
* A node with peer discovery enabled refuses to start on an insecure cluster peer plane unless `cluster.tls.allow_insecure = on`. See [Cluster peer plane](doc/guides/security/cluster_peer_plane.md).
* Fixed ticket scope normalisation on decode, so stored tickets are found by lookup.
* A revoked ticket kept authenticating under the default `security.ticket.allow_not_found = on`. Revocation now replicates to every node, and `bondy.ticket.revoke` revokes a ticket. See [Authorization](doc/guides/security/authorization.md#ticket-revocation).
* `security.master_key.id` accepts only 0 to 65535.
* Fixed: a claim-restricted (for example OIDC) session received the grants of the user's locally stored group memberships. See [Authorization](doc/guides/security/authorization.md).
* WAMP URI validation rejects control characters, and realm URIs with NUL bytes are refused.
* Cowboy 2.18.0 and cowlib 2.19.0. See [Listeners](doc/guides/configuration/listeners.md#request-validation).
* Bridge relay full sync shipped users' password hashes; it no longer ships passwords.
* `HELLO` revealed whether a user exists; password methods now get a decoy challenge, and other methods a generic `ABORT`.
* `PUBLISH` ignored `eligible_authid`, `eligible_authrole`, `exclude_authid` and `exclude_authrole` for live and retained events.
* A realm could switch its SSO realm while its users still linked to the old one, so a token issued for one user was accepted as another. The switch is refused while linked users exist.
* An SSO user that other realms link to, and a realm that other realms use as prototype or SSO realm, can no longer be removed.

### Improvements
* Built and shipped on Erlang/OTP 29, which is now the minimum version to build. See [Runtime requirements](doc/guides/deployment/runtime_requirements.md).
* New `listeners.$name.http.*` options: `max_authorization_header_value_length`, `max_cookie_header_value_length`, `max_authority_length`, `invalid_response_headers`, `max_concurrent_streams` and `max_cookies`. See [Listeners](doc/guides/configuration/listeners.md#request-limits).
* Prometheus metrics for the storage stack, the router and the BEAM, and a bundled Prometheus and Grafana stack under `monitoring/`. See [Metrics](doc/guides/reference/metrics.md).
* `bondy_http_connector` metrics, dashboard and per-service liveness probe. See [HTTP connector](doc/guides/configuration/http_connector.md).
* `bondy_export` import writes in batches.
* `rebar3 ex_doc` builds the reference documentation again.
* Reading the cluster membership no longer blocks on Partisan's peer-service manager.
* Compaction held back by a member is reported as a trigger outcome and a "GC stalled" warning; `bondy_oplog_gc_scheduler_events_total` gains a `scheduler` label. See [Reclamation options](doc/guides/configuration/reclamation_options.md) and [Log messages](doc/guides/reference/log_messages.md).
* A refused snapshot install (`source_behind_truncation`) logs what to do. See [Clustering](doc/guides/configuration/clustering.md).
* New metric `bondy_oplog_core_range_pages_total`. See [Metrics](doc/guides/reference/metrics.md).

### Performance
* A database's shards open concurrently, and write-ahead-log recovery reads in larger chunks.
* Durable pack sealing runs off the apply path (`db.pack_seal_mode = async`, default), with a smaller seal threshold (`db.pack_auto_seal_bytes`). See [Database options](doc/guides/configuration/database_options.md).
* The in-memory registry's cell sweep resumes from its cursor instead of re-reading the whole cell directory on every batch.

### Fixes
* The bundled CA stores (certifi 2.18.0, and tls_certificate_check 1.36.0 for OTLP export) no longer trust the emSign roots Mozilla distrusted in October 2026. Bondy also trusts the OS store, so update the host's CA certificates as well.
* The Debian Docker image had no OS CA store, so an SMTP relay or SDK TLS connection without its own `cacertfile` could not verify a server. The image now installs `ca-certificates` without the emSign roots Mozilla distrusted, and the Alpine image upgrades its CA bundle.
* A grant to `all` did not reach open sessions until their cached authorization context expired (up to 5 minutes).
* Over HTTP long-poll, a router `ABORT` or `GOODBYE` never reached the client.
* A WAMP session over HTTP long-poll or SSE could receive messages out of order. See [Listeners](doc/guides/configuration/listeners.md#node-wide-http-transport-queue).
* An outbound bridge relay with no `ping` block crashed, and one with no `reconnect` block never reconnected. See [Bridge relay](doc/guides/configuration/bridge_relay.md).
* The error formatter could crash on some reasons.
* A malformed WAMP `ABORT` reason crashed the connection handler.
* Building `WWW-Authenticate` raised `badarg` for atom error codes.
* The HTTP API Gateway put raw `hackney` reasons and unrendered upstream errors into response bodies.
* HTTP long-poll errors had an empty body.
* Two WAMP-error-to-HTTP-status tables disagreed; there is one.
* `bondy_regulator` dropped its error details.
* `format_error/2` in `bondy_mst` and `bondy_registry` crashed when `error_info` had no `cause`.
* `bondy_connect_humanized:join/1` mishandled two items and a single non-iodata item.
* `?WAMP_FEATURE_NOT_SUPPORTED` expanded to `wamp.error.no_available_callee`.
* `rebar3 dialyzer` failed on a removed warning option.
* `CANCEL` was dropped when the callee was on another node. See [WAMP features](doc/guides/router/wamp_features.md).
* Cross-node calls lost their per-procedure latency metrics and checked `CANCEL` authorisation against no procedure.
* Invocations whose caller session died kept running until their timeout.
* `bondy_session_duration_seconds` and `bondy_socket_duration_seconds` recorded every observation in the lowest bucket.
* Cold boot after an unclean shutdown could lose the tail of a shared write-ahead log.
* Stopping a node destroyed its durable MST history.
* The MST pack store could persist a root before its pages.
* A freshly bootstrapped node reported divergence indefinitely.
* Re-applying the same `security` configuration at boot generated replicated writes.
* Every boot regenerated and re-replicated realm signing keys.
* Setting `listeners.$name.http.buffer.min/max` disabled dynamic buffering.
* A ping block without `ping.enabled` killed every connection on the listener.
* A TLS listener that set one security header lost its default HSTS header.
* An API Gateway specification's `host` was ignored.
* Bondy's own HTTP paths were unreachable on hosts a specification named.
* A stored specification reusing a built-in path aborted the dispatch rebuild.
* A listener naming an unimplemented carrier failed late, without naming the listener.
* `listeners.$name.linger.timeout` written with a unit suffix was read as milliseconds.
* Raw-socket and bridge-relay listeners sent no keepalive probes; a dead peer is now dropped after three unanswered probes on every protocol.
* Idle raw-socket and bridge-relay connections were never reaped.
* The raw-socket keepalive fired on the idle-reap timer and closed connections instead of probing them.
* HTTP listeners other than `admin` ran on Cowboy's `active_n` and idle-timeout defaults instead of Bondy's.
* TLS HTTP listeners sent no HSTS header.
* Bondy's own procedures and subscribers could not read JSON or CBOR payloads.
* A Payload Passthru call to one of Bondy's own procedures crashed instead of failing.
* Over CBOR, every string was sent as a byte string. See [Serialisation](doc/guides/introduction/wamp.md#serialisation).
* `bondy_connect_sdk` gave up after a router `GOODBYE`, and retried failed connections without backoff.
* An outbound bridge relay crashed on a socket error while sending its `HELLO`.
* The Kafka bridge's `encoding = erl` raised `badarg` on every message.
* The Kafka bridge's `required_acks` alias `"all"` waited for the partition leader only, and `"leader"` for every in-sync replica. `"all"` is `-1` and `"leader"` is `1`, as brod defines them.
* A write that re-created a reclaimed projection cell failed with `context_regression`.
* A member partitioned or down for longer than 30 s could lose writes to compaction. See [Convergence](doc/guides/database/convergence.md).
* A re-bootstrapping node could lose events it had compacted away.
* A re-bootstrap could leave a node missing events, or holding deleted values, while it reported itself in sync. See [Convergence](doc/guides/database/convergence.md#re-bootstrap).
* A re-bootstrapping or just-restarted replica could serve data that did not match the frontier it advertised.
* A removed set or map entry, or a disabled flag, could come back after a re-fold.
* An event held for a sequence gap could stay unapplied after a compaction.
* Two causes of needless full re-bootstraps.
* The oplog could commit `consumer.offset` past an MST root that was not durable.
* Paging through a table could stop early after a run of deleted entries.
* Reopening after a crash during a pack seal could delete the sealing file on a transient error.
* A write whose WAL writer died mid-append was reported as not written.
* `bondy_db:close_table/1` could lose index updates.
* The log line listing loaded realms printed `a, b` instead of their URIs.
* A raw-socket listener's `idle_timeout` never closed an idle connection, and a bridge-relay listener's closed live ones; both now close a connection whose peer has sent nothing for `idle_timeout`. See [Listeners](doc/guides/configuration/listeners.md).
* A bridge relay's reconnect budget ended 30 seconds after the first failure, whatever `reconnect.max_retries` said, and a send failure while forwarding or pinging stopped the client instead of reconnecting. See [Bridge relay](doc/guides/configuration/bridge_relay.md).
* Removing a running bridge relay failed and left it running.
* A bridge relay with `reconnect = off`, or one whose connect error is not retried, was restarted at once by its supervisor after every failure; about 20 failures within a minute stopped every bridge relay on the node. Such a bridge now stops and stays stopped until `bondy.router.bridge.start`. See [Bridge relay](doc/guides/configuration/bridge_relay.md#what-happens-when-the-connection-is-lost).
* A bridge relay client that the remote router refused with an ABORT restarted at once, with no backoff; about 20 refusals within a minute stopped every bridge relay on the node. A refusal now waits the next reconnect backoff in the same client. See [Bridge relay](doc/guides/configuration/bridge_relay.md#what-happens-when-the-connection-is-lost).
* An outbound bridge relay with `ping = off` crashed as soon as it connected, so its client restarted until its supervisor gave up and stopped every bridge client on the node.
* An outbound bridge relay dropped a silent connection `ping.idle_timeout` after its `idle_timeout`, and crashed on a silent connection when `idle_timeout = infinity`. See [Bridge relay](doc/guides/configuration/bridge_relay.md#idle-connections).
* A CALL whose options the load balancer refused was answered `wamp.error.no_such_procedure` instead of `wamp.error.invalid_argument`, and an ERROR the router raised for a Payload Passthru CALL copied its `ppt_*` options.
* A CANCEL in `kill` or `killnowait` mode sent INTERRUPT to a callee that had not announced `call_canceling`. Such a cancel now acts as `skip`, on the callee's node as well as locally. See [WAMP features](doc/guides/router/wamp_features.md).
* A client `ERROR` for anything other than an `INVOCATION` ends the session with `wamp.error.protocol_violation`, as the WAMP specification requires. The dealer used to answer a callee's `ERROR` for an `INTERRUPT` with an `ERROR` for the `CANCEL`, which WAMP does not define, and kept the call pending until it timed out.
* A `CANCEL` the caller may not make gets no reply and the call runs on. It used to get an `ERROR` for the `CANCEL`, which WAMP does not define, and which a client could take as the call's own result. See [WAMP features](doc/guides/router/wamp_features.md).
* A callee's `YIELD` or `ERROR` that arrived while the dealer extended the call's timeout, on a progressive call chunk or a progressive result, found no pending call and was dropped.
* A `CALL` that reused a progressive call's request id after its final chunk reached the callee as another `INVOCATION` while the callee was still working; the dealer now discards it.
* Revoking a grant from `anonymous`, or granting to `anonymous` after another role, failed with `duplicate_roles`. Master-realm hardening therefore left the anonymous `wamp.*` grant of a legacy master realm in place; it now revokes it.
* Reading the alarm list before the alarm handler was installed, or while it was being re-installed, returned an error instead of an empty list. At boot this logged "Error while reconciling retention limit alarms".
* A Kafka broker bridge action whose `partitioner.value` was neither a string nor a number passed validation and then failed in the producer for every event; validation now rejects it.
* A call from one node of a cluster to a callee bridged into another node never reached the callee: that node sent the CALL to the bridge relay without addressing the callee behind it, and the caller timed out.
* In the same case, a progressive call lost every chunk after the first, so the callee never got the final chunk and the caller timed out, and a CANCEL, or the caller leaving, never interrupted the callee. The node holding the bridge now keeps the call, as the caller's node does, and passes later chunks and the CANCEL on.
* A call could be settled twice when two settlements raced, such as a final `YIELD` and a `CANCEL` in mode `skip` or `killnowait`, so the caller received two replies to one `CALL`.
* `bondy_cluster_channel_connections` was exported by two collectors in one scrape, which a strict Prometheus parser rejects. See [Metrics](doc/guides/reference/metrics.md).
* A `registry` shard staged a catalogue install under `/tmp` rather than `platform_tmp_dir`. See [Platform directories](doc/guides/deployment/platform_directories.md#install-spool).
* `scripts/migrate_conf.escript` called four WAMP features unimplemented or implemented contrary to what the build advertises; its self-test now checks every reason against the build.
* A departed node's registrations and subscriptions were never reclaimed on a cluster with two or more surviving members.
* A departed node's registrations and subscriptions survived retirement once the survivors had compacted their registry history.
* A node or index writer that stopped between a durable write and its index updates lost those updates.
* Reading a durable cell while its first write landed could crash the reader with `badarg`: the projection's HEAD read fell back from the value column to the state column between two store calls. It now reads the one column the cell's fold writes.
* A bridge relay server crashed on a malformed `HELLO` or `AUTHENTICATE`; it answers a `protocol_violation` `ABORT`.
* Registrations and subscriptions made after a bridge relay session opened never reached the core, and their removals matched nothing.
* Two concurrent `single` registrations of one procedure could both succeed.
* `exclude`, `eligible` and `exclude_me` did not apply to exact-match subscriptions, and an empty `eligible` list delivered to every subscriber; it now delivers to none.
* A retained event was delivered twice to a new subscriber.
* Deleting a realm left its HTTP API Gateway routes installed.
* An HTTP API Gateway specification without a top-level `defaults` object failed to load with `missing_required_value`; it now loads with the built-in defaults, as one with an empty `defaults` does.
* A route with a binding, in the path or the host, could shadow a literal one; routes and hosts are matched most specific first.
* An API Gateway specification with an unknown action key crashed the gateway on load.
* A gateway response that set no status and had a non-map body lost the action's status; `bondy.error.bad_gateway` answered 503 instead of 502. A `forward` to an upstream that never answers gets `bondy.error.gateway_timeout` (504).
* The `forward` action garbled upstream bodies: JSON was decoded and re-encoded, text was quoted, and every body was labelled `application/json`. The upstream's bytes and content type are sent as received.
* The HTTP connector reported pending credentials and a failed token fetch as `bondy.error.bad_gateway` (502) instead of `bondy.error.unavailable` (503), and its own crashes as `bad_gateway` instead of `bondy.error.internal_error` (500).
* `bondy_connect_sdk` failed a call that asked for `_retries` after its first timeout.
* A MessagePack client that called `wamp.registration.get` or `wamp.subscription.get` lost its connection. `created` is sent as an ISO 8601 string to every client, as the WAMP specification defines it.
* A `null` in a WAMP payload reached HTTP connector upstreams and MCP clients as the string `"undefined"`. The HTTP connector request body and every MCP response use the WAMP JSON encoder, so `null` stays `null`. Floats are written with 16 decimals, as WAMP JSON clients receive them.
* A JSON or CBOR `null` reached the router as a different term from a MessagePack nil, so the same message got a different outcome per serializer. A nil option such as `timeout` was rejected from MessagePack and CBOR clients, and a JSON client using `bondy_connect_sdk` received `null` in payloads where MessagePack gave `undefined`. Every serializer now decodes nil as `undefined`, and a nil option is treated as absent.
* A datetime or a key-value list in a payload from an in-VM callee ended a MessagePack client's connection. MessagePack sends them as the RFC 3339 string and the object that JSON and CBOR send.
* A list of datetimes in a payload from an in-VM callee failed to encode for JSON, CBOR and MessagePack clients alike. It goes out as a list of RFC 3339 strings.
* `serializers.json.float_format` in `bondy.conf` had no effect: WAMP JSON always used `[{decimals, 16}]`. The configured format reaches the encoder.
* An HTTP connector `auth.fetch.error_path` that found JSON `null` in a token response failed the token fetch with `Unknown error`. A `null` there is no error.
* An HTTP connector secret field whose value was JSON `null` was sent as the literal string `null`. It is reported as `secret_field_not_found`, as a missing field is.
* An AWS Secrets Manager secret that was not a JSON object failed with an internal reason (`badmap`, `case_clause`, `invalid_byte`). It fails with `secret_not_json` or `secret_not_json_object`, and a field that is not a string with `secret_field_not_string`.
* With no AWS credentials, the `aws_sm` secret provider failed with `{aws_sm, {badmatch, undefined}}`. It fails with `aws_credentials_not_found`. Any other failure inside `erlcloud` now raises to the caller instead of coming back as `{error, {aws_sm, _}}`, whose reason could carry the secret's bytes.
* An exception raised inside `erlcloud` while fetching an `aws_sm` secret kept its arguments in the top stack frame, so a crash report could print the secret. The frame carries their arity instead.
* `sys:get_status/1` and crash reports of an HTTP connector callee or of the connector manager printed each service's `auth_conf`, including resolved secrets and credentials written in `bondy.conf`. They show the atom `sensitive` in its place.
* The WebSocket listener accepted the batched subprotocols (`wamp.2.json.batched`, `wamp.2.cbor.batched`, `wamp.2.msgpack.batched`, `wamp.2.erl.batched`) and then closed the connection on the first message, because Bondy cannot decode them. They are no longer negotiated: the listener picks the client's next offer, or refuses the handshake.
* A user whose RBAC sources included `tls` or `oidcrp` could not open a WAMP session with any method: `bondy_auth:init/5` failed with `unsupported_method`. Methods that have no WAMP authentication are now skipped when Bondy computes the methods a HELLO may use.
* The `oidc` authmethod named a module that does not exist. It is removed: a realm or source that lists it fails validation, and so does `security.ticket.authmethods`. OIDC sign-in issues tickets with `oidcrp`, which is unchanged.
* An invalid value for `security.ticket.authmethods` crashed config generation with `badarg` instead of naming the invalid method.
* A CALL with `runmode = "partition"` was routed by the registration's invocation policy, ignoring its `rkey`. It is now routed by a consistent hash of `rkey`, and without `rkey` it fails with `wamp.error.invalid_argument`.
* `sys:get_status/1` on a RawSocket (TCP or TLS) connection, and any crash report for one, showed `format_status/1 crashed` in place of the connection's state.
* Session-scoped ids wrapped to 0, and a session without a counter created one on demand.
* An `erl`-encoded improper list or tuple crashed the connection instead of being answered with a `protocol_violation` `ABORT`.
* Mops dropped spaces inside quoted literals, so `get('first name')` read `firstname`.
* Updating a user whose SSO user was missing returned an undeclared error.
* A WAMP JSON or CBOR frame with a truncated, trailing or ill-shaped payload was forwarded as received, so receivers got an invalid frame or lost their connection. The router decodes the payload on arrival and aborts the sender.
* Invalid JSON or CBOR, a frame that is not a WAMP array, a request or session id outside [0, 2^53], a field of the wrong WAMP type, and a `HELLO` with no roles aborted the session as an internal error. They get a protocol-violation `ABORT`.
* A partially decoded message whose options, details or URI were invalid crashed the decoder, so the session was aborted as an internal error. It gets a protocol-violation `ABORT`, or an `ERROR` for an invalid URI.
* `bondy_cbor` let malformed input escape as `function_clause`, `badmatch` or `badarith`, decoded an indefinite-length integer or tag as the atom `indefinite`, and crashed on single- and double-precision NaN and Infinity. It raises a documented error.
* A CALL from another node to a callback that raised got no answer; it gets `bondy.error.internal_error` with a trace id, as a local call does.
* A send failure on a reset bridge relay connection could stop the client without backoff; enough of them shut down every bridge relay on the node.
* Mops split a quoted argument on a comma, a bracket or `|>`, and a deferred `without([...])` kept the keys it named instead of dropping them.
* An HTTP connector request that outlasted the procedure's `timeout` was answered `bondy.error.bad_gateway` (502); it is `bondy.error.gateway_timeout` (504).
* An HTTP connector call retried a request that had timed out, and its retries could run past the procedure's `timeout`. The timeout bounds the whole call, retries included.
* A call to an HTTP connector service whose pool was down was answered `bondy.error.bad_gateway` (502); it is `wamp.error.unavailable` (503). See [HTTP connector](doc/guides/configuration/http_connector.md).

### Changes
* A progressive call streams to a callee behind a bridge relay, and a cancellation or the caller leaving interrupts that callee. See [Progressive call invocations](doc/guides/router/progressive_calls.md).
* A progressive call is authorized once, by its first chunk, whose options apply to the whole stream; a chunk that names a procedure other than the stream's is discarded. See [Progressive call invocations](doc/guides/router/progressive_calls.md).
* A call whose callee leaves before answering fails at once with `wamp.error.canceled`, as the WAMP specification requires, unless it is routed again under `CALL.Options._retries`. See [Progressive call invocations](doc/guides/router/progressive_calls.md).
* MessagePack is encoded and decoded by Bondy's own `bondy_msgpack`; four behaviours change for MessagePack clients. See [Serialisation](doc/guides/introduction/wamp.md#serialisation).
* WAMP broker and dealer features are build capabilities, not configuration; `payload_passthru_mode`, `progressive_call_invocations` and `progressive_call_results` are advertised, `call_reroute` is not. See [WAMP features](doc/guides/router/wamp_features.md).
* Pattern-based registration and subscription are always on.
* A single security header can be switched off with `off`. See [HTTP security headers](doc/guides/configuration/http_security_headers.md).
* Changed listener log records: connection-threshold alarms, the drain notice, and the WebSocket idle close. See [Log messages](doc/guides/reference/log_messages.md).
* Two listeners may share a port when they bind different addresses.
* An HTTP listener with an empty `services` list is refused at boot.
* `api_gateway` and `admin_api` are separate carriers; registering an external carrier takes `bondy_router.http_services` and `bondy_router.http_carriers`.
* `wamp.error.not_authorized` maps to HTTP 403 and `wamp.error.authorization_failed` to 500.
* An API Gateway specification's `status_codes` map overrides the built-in defaults at the host and version levels. A response status changes only through an `on_error` expression that reads it.
* `bondy_connect_sdk` reports a crashed callee handler as `bondy.error.internal_error`.
* The meta API reports inconsistencies as `bondy.error.inconsistency_error`.
* API Gateway request ids and error trace ids are W3C trace-ids. See the [error catalogue](doc/guides/reference/error_catalogue.md).
* The router application is `bondy_router`, and the RPC Gateway is `bondy_http_connector`.
* Requests with more than 100 query-string parameters or form fields are rejected.
* `listeners.$name.ip` takes a literal IP address.
* Compaction and reclamation wait for every member, on every database, to apply an event and checkpoint its frontier. See [Deletion and reclamation](doc/guides/database/deletion_and_reclamation.md#when-history-may-be-removed).
* The write-ahead log is its own application, `bondy_log`; `bondy_stdlib` is `bondy_connect_lib`.
* Renamed log messages: "Prefix-closure hold" is "Causal hold", and "Reclamation stalled" is "GC stalled".
* Removed metric `bondy_oplog_peer_exclusions_total`.
* `bondy_oplog_core:subscribe/2` accepts `all`, `{prefix, P}` and `{exact, K}` patterns; the `{match, F}` pattern is removed. A consumer `verify_event`, `refresh` or `publish_fun` callback that raises now crashes its caller instead of being logged.
* A peer must announce `call_canceling` in `HELLO` to obtain it; an omitted feature is no longer inherited from the router's advertised set.
* `bondy_cluster_channel_connections` is labelled by `peer` and `channel`.
* The authentication freshness fence counts only sync rounds; a local write no longer defers its refusal.
* Partisan 6.3.1, from 5.0.3.
* The `on_create` and `on_delete` registration and subscription meta events are not published: a cluster cannot tell a URI's first and last registration without coordinating its nodes.
* Over the `erl` serialisation, a property list in a payload is sent as a list of two-element lists, not as a map; a repeated key lost an element and a mixed list crashed the encoder.
* `bondy.oauth2.token.get`, `bondy.oauth2.token.refresh` and `bondy.telemetry.metrics` are removed; no release implemented them, and calls answer `wamp.error.no_such_procedure`. `bondy.security.find_source` answers `bondy.error.deprecated_procedure`.
* An API Gateway specification's version and method `info` maps are free-form: the parser checks only that each is a map and keeps its keys.

## 1.0.0-rc.65
* Fix bug in decoding of Error messages when using partial JSON encoding

## 1.0.0-rc.64
### Fixes
* Dockerfile security fixes to reduce CVE surface in runtime image

## 1.0.0-rc.63
### Performance
* Registry pattern matching (prefix and wildcard) rewritten as a lock-free persistent Adaptive Radix Trie (`bondy_registry_ptrie`), replacing the `art` library and its serialising gen_server. Match latency drops from ~133µs to ~1µs and reads scale with cores instead of being capped at ~5k ops/s. Per-handle QSBR reclamation is driven by `bondy_registry_ptrie_janitor` processes managed by each registry partition.
* RPC dealer: removed expensive defensive liveness checks from the call hot path; in-flight promises are now flushed when a Callee dies.

### Improvements
* RPC Gateway: significant refactor of callee lifecycle, HTTP pool management, and token cache; added `bondy_rpc_gateway_callee_lifecycle_SUITE` for coverage.
* `bondy_table_manager` supports anonymous ETS tables to avoid creating atoms from runtime-generated names; broader protections added across the codebase against atom-table exhaustion.

### Fixes
* `bondy_rpc_gateway.schema`: corrected duration unit on `pool.checkout_timeout`, `pool.connect_timeout`, `pool.idle_timeout`, and `pool.recv_timeout` (`s` → `ms`) so sub-second values round-trip correctly.
* Fixed a raise that prevented ETS table cleanup in `bondy_transport_queue` / `bondy_http_transport_session`.

## 1.0.0-rc.62
### Fixes
* Race condition in longpolling connection (between longpoll timeout and idle timeout, now separate configs)

## 1.0.0-rc.61
### Fixes
- `cookie_same_site` validation was using atoms as opposed to strings (binaries)

## 1.0.0-rc.60
### Added
- Configurable `cookie_same_site` option for OIDC providers (`lax`, `strict`, `none`; default `lax`). Required for cross-subdomain deployments where Safari refuses to send cookies on SSE/fetch requests. Both `cookie_domain` and `cookie_same_site` can be overridden via query parameters on `/oidc/logout`.

## 1.0.0-rc.59
### Added
- bondy_http_cors.erl — Centralised CORS logic with 3 origin modes (`*, auto, explicit allowlist`). Never combines credentials: true with origin: `*`. Adds Vary: Origin for non-wildcard origins.
- bondy_http_security_headers.erl — Static security headers (HSTS, X-Frame-Options, X-Content-Type-Options, CSP) cached in
  persistent_term per-listener. Configurable server header (suppress/customise).
- CORS + security headers schema keys to `bondy.schema` for all 4 listeners (admin_api http/https, api_gateway
  http/https)
- HSTS defaults to enabled for HTTPS listeners, disabled for HTTP
- X-Frame-Options defaults to SAMEORIGIN, X-Content-Type-Options to nosniff
- Removed duplicated cors_headers/1 from 4 handlers (OIDC, SSE, SSE stream, long-poll)
- Replaced ?HEADERS/?OPTIONS_HEADERS macros in OAuth2 handler
- Added CORS fallback in API Gateway REST handler (uses spec headers when present, falls back to listener config)
- Updated admin ping/ready handlers to use set_all_headers/1
- Removed ?CORS_HEADERS macro from http_api.hrl
- Removed hardcoded CORS from bondy_admin_api.json and example specs

### Fixes
- Fixed config defaults with wrong types

## 1.0.0-rc.58
### Changes
* Change user auto provisioning in OIDC to `false`
### Added
* RBAC property-based tests

## 1.0.0-rc.57
### Fixes
* Fixes an issue with OIDC tokens containing roles unknown to Bondy

## 1.0.0-rc.56
### Fixes
* Fix set comparison on authroles calculation
* Add error logs for failed OIDC connections

## 1.0.0-rc.55
### Fixes
* Fixed issues with role mapping and metadata merging in OIDC/Cookies

## 1.0.0-rc.54
### New Features
* new `bondy_cert_manager` used for validation of outgoing TLS certificates and other features like live certificate rotation

## 1.0.0-rc.53
## Fixes
* Fixes to OIDC Handler

## 1.0.0-rc.52
## Fixes
* SSL verification fixes for OIDC HTTP connections

## 1.0.0-rc.51
### New Features
* Experimental implementation of 2 additional WAMP Transports:
    * HTTP Longpoll according to the WAMP Spec.
    * HTTP SSE, a variation on Longpoll that uses Server Sent Events (SSE) for `receive` (This only works with JSON encoding only at the moment)
* Support for Cookie-based authentication in combination with OpenID Connect, where Bondy acts as OIDC Relaying Party (`oidcrp` authentication method). Configuration done at the realm level. This requires the definition of an HTTP API using Bondy API Gateway.
* RP-Initiated Logout for OIDC sessions. The `/oidc/logout` endpoint now performs a two-step logout: revokes the Bondy ticket and clears cookies, then redirects to the IdP's `end_session_endpoint` (with `id_token_hint` and `post_logout_redirect_uri`) to terminate the IdP session as well. Falls back to a direct SPA redirect if the IdP does not support `end_session_endpoint`. The `post_logout_redirect_uri` must be registered in the IdP's client configuration.
* Experimental implementation of RPC Gateway that allows for the definition of WAMP to HTTP routing, taking care of Secret Management and Token flows and caching. This is entirely configured on the `bondy.conf` file.
* Cookies now have the realm as suffix e.g. `bondy_ticket_my_realm`
* New `bondy.session.self` RPC that returns the caller's session information (useful when using cookie-based authentication as the cookie cannot be read by the client code).

### Fixes
* Fixed CORS headers missing from OIDC handler endpoints (`/oidc/login`, `/oidc/callback`, `/oidc/logout`). Cross-origin requests from SPAs were blocked by the browser. The handler now sets CORS headers on all responses and handles `OPTIONS` preflight requests.
* Fixed `bondy_csrf` cookie never being set during the OIDC callback. The cookie used `SameSite=Strict` which prevented the browser from accepting it on the cross-site redirect from the IdP. Changed to `SameSite=Lax` to match `bondy_ticket`.
* Fixed `/oidc/logout` not clearing the `bondy_ticket` cookie in cross-site deployments. The endpoint now accepts `GET` requests (in addition to `POST`) so the SPA can use a top-level navigation, which allows the browser to both send and clear `SameSite=Lax` cookies. The response is a `302` redirect instead of `200 OK`.

### Changes
* Session `authextra.meta` map now collects metadata from the User object as well as all the groups this user belongs to directly or indirectly (transitive closure). As a result both keys in `HELLO.Details.authextra.meta` and `Details._session_info.meta` can return lists (arrays) when 2 or more values have been collected for that key or when any of the values was originally a list.

## 1.0.0-rc.50
* Upgraded PlumDB with:
    * Fixes to configuration of shared write buffer and block cache
    * Latest version of RocksDB (10.7.5)
* set option `store.use_direct_io_for_flush_and_compaction` default to `false`

## 1.0.0-rc.49
* Fix dockerfile mistake

## 1.0.0-rc.48
- Upgraded to latest PlumDB which contains fixes to the RocksDB defaults (the previous values might cause issues due to excessive compaction)
- RocksDB can be configured via `bondy.conf` using `store.*` options.

## 1.0.0-rc.47
### Changes
- Implementation of JSON partial decoding/encoding for WAMP messages.
    - Bondy now decodes/encodes only the control message data (head of the WAMP message) preserving the payload (tail) in JSON format. This improves performance as the payload is never decoded unless a destination peer requires a different encoding. For networks using JSON end-to-end you should see important performance improvements.

## 1.0.0-rc.46
### Fixes
- Fixes a bug in the OAUTH2 rest handler which would prevent the `client_device_id` option to be considered when obtaining a new token. This was introduced with the new token subsystem. This issue limites the token scope to {realm, client} as opposed to {realm, client, device_id}.

## 1.0.0-rc.45
### Fixes
- Fix bug in calculation of prometheus metrics preventing /metrics to complete

## 1.0.0-rc.44
### Changes
- Make wamp router features configurable and prevent using pattern matching when not enabled
- Define a sensible default of 4MB for max_frame_size

## 1.0.0-rc.43
* Fixed TLS support for Rawsocket listener

## 1.0.0-rc.42
### Changes
- **Partial Registry concurrency improvement** - As we prepare to formalize our battle-tested platform with a `1.0.0` release, we've enhanced the registry with a more scalable and concurrent solution for EXACT matching registrations and subscriptions. PREFIX and WILDCARD matching support retain their existing concurrency limitations. In the next release candidate, we'll implement a more scalable solution for these features alongside a new replication mechanism - the final step to complete the implementation.
- `bondy.ping` added to be used as connection heartbeats where the client doesn't
support transport level heartbeats e.g. Web Browser Websocket pings. The RPC replies a single positional argument `"pong"` and it is always authorised to be called by all sessions.

## 1.0.0-rc.41
- Minor fix to new listener `liner.timeout` option to avoid confusion between protocol and socket options.

## 1.0.0-rc.40
- Major HTTP API Gateway bottleneck removed and memory usage reduced
    - Avoid Cowboy to close over the dispatch table when compiling the routing
    logic and passing it into the request handling process.
    - Uses new `persistent_term` capability from Cowboy to store the dispatch
    table
- Major refactoring of protocol/transport options for better reuse
- Added almost all options to configuration schemas

## 1.0.0-rc.39
* Completely redesigned the OAUTH2 token storage.
    * Tokens are now bounded by {User, Client, Device} (idem WAMP Tickets)
    * Tokens are sharded across all partitions, allowing for more scalability
      (idem WAMP Tickets)
    * This is part of a roadmap to completely redesign and complete the OAuth2
    and OIDC capabilities in Bondy
* OTP/Partisan compatibiliey issue fixes in PlumDB
* Refactoring of WAMP APIs (Modules renamed and consolidated)
* New WAMP APIs
    * `bondy.registry.list`
* New standard `CALL.Options`
    * `_disclose_session` - The callee will receive and the session information
    in  `INVOCATION.Details._session_info`
- Drop x_ prefix for RPC experimental options

## 1.0.0-rc.38
- Failed tag

## 1.0.0-rc.37
* Added bounded queues for job worker pool and their configuration
    * `load_regulation.job_manager.queue.size`
    * `load_regulation.job_manager.queue.ttl`
* Configure HTTP dynamic buffers via `bondy.conf` options
    * `bondy.api_gateway_http.socket_opts.buffer.[min | max]`
    * `bondy.api_gateway_https.socket_opts.buffer.[min | max]`
    * `bondy.admin_api_http.socket_opts.buffer.[min | max]`
    * `bondy.admin_api_https.socket_opts.buffer.[min | max]`
* Minor fixes and Log improvements

## 1.0.0-rc.36
* Migration to Erlang OTP 27 (latest)
* Move `wamp` library as part of the umbrella as `bondy_wamp`
* New version of plum_db with solution to map key ordering encoding issue
  (using `deterministic` option in call to `term_to_binary/2`)
* WS dynamic buffers via `bondy.conf` options
    * `wamp.websocket.buffer.[min | max]`

## 1.0.0-rc.35
* No changes from previous version

## 1.0.0-rc.34
## Changes
* It is now an error to open a session to a Realm when security is disabled and using an `authmethod` other than anonymous.

## Fixes
* #42 - error when authentication using anonymous when realm's security is disabled (additional case)

## 1.0.0-rc.33
## Fixes
* #41 - error when authentication using anonymous when realm's security is disabled

## 1.0.0-rc.32
* Updated Dockerfile
    * Removed deprecated libraries
    * Upgraded OS and Erlang/OTP versions
    * New multi-arch Github action

## 1.0.0-rc.31
* Removed support for OTP25
* Updated Github Actions

## 1.0.0-rc.30
## Fixes
* Fixed a memory leak caused by the uncleaned `bondy_session_counter` table, which was used for session-scoped WAMP ID generation in the HTTP API Gateway. The new implementation uses random numbers for HTTP API Gateway requests instead of maintaining a counter. All logic related to WAMP message ID generation has been consolidated in the bondy_message_id module. Counters are not only used for WAMP sessions.


## 1.0.0-rc.29
## Changes
* Changed the `bondy_session_manager` pool worker selection to use the Session
 Id as opposed to the realm to distribute load evenly when a single realm is
 used

## Fixes
* Fixed sending a GOODBYE message only when session is close by the Router.


## 1.0.0-rc.28
## Fixes
* Upgraded `plum_db` with a fix to a bug causing a partition a crash when
  forcing a partition hashtree reset
* Upgraded `observer_cli` and `prometheus` dependencies
* Remove unused `bear` dependency

## 1.0.0-rc.27
## Changes
* Moved json encoding to `bondy_json` module which now uses the new `json` moduled instead of `jsone` when running on OTP27. In addition, float and date formatting has been implemented to mirror those existing in `jsone`. Also the default float format respects the deprecated `jsx` lib format for backwards compatibility.
* A new option `serializers.json.float_format` has been added to `bondy.conf` that takes a string representation of the options supported by `erlang:float_to_binary/2`.
* **NOTICE**: This only affects HTTP Gateway JSON encoding at the moment and not WAMP. This will be addressed in the next release.

## 1.0.0-rc.26
### Fixes
* Fixed bug in password hash comparison for version 1.0 passwords (PR #40)

## 1.0.0-rc.25
### Changes
* Removed `enacl` and `pbkdf2` libraries, replacing its functionality with
  Erlang's `public_key` and `crypto` applications for password hashing and WAMP
  Cryptosign.
* Upgraded several dependencies
**BREAKING CHANGE NOTICE**
* As a result of `enacl` removal we have temporarily retired support for the `argon2` algorithm until we finish an implementation via Rustler.

### Fixes
* Fixes a bug in `bondy_rbac:conca_role` function that affected the RBAC APIs.

## 1.0.0-rc.24
* Upgraded PlumDB and Partisan with fix to avoid partisan_plumree_brodcast to crash when the behaviour implementors raise an exception
* Fixes to Debian dockerfile
## 1.0.0-rc.23
### Changes
**BREAKING CHANGE NOTICE**
* This version replaces Leveldb with Rocksdb - Rocksdb storage is incompatible with Leveldb so if you rely on Bondy storing real information (realms, users, groups, grants, etc), you will need to export/import them using the `bondy.backup.create` and `bondy.backup.restore` WAMP procedures.
* Bug fix in bondy_registry_entry:dirty_delete/1

## 1.0.0-rc.22
* Fix CI for OTP26 docker variant

## 1.0.0-rc.21
### Fixed
* Fix checking user credentials changes in `on_merge` (#31)
* Fixes several bugs reported in #30:
    * Missing `authroles` in WAMP context for Oauth2 flow
    * Pattern matching exception in Bondy Dealer where the atom `no_proc` was wrongly used instead of `noproc`
    * Fix in bondy Oauth2 un be able to handle undefined as a "token_type" in the  `revoke_token` operation

## 1.0.0-rc.20
* Drop Min OTP version to OTP25 and CI workflow to publish Bondy build with OTP25 and OTP26

## 1.0.0-rc.19
* Upgrade Dockerfile to OTP 26.2.5 to avoid memory-related bugs in BEAM

## 1.0.0-rc.18
* Downgrade to OTP 26.2.2 to avoid issue with cgroups cpu_quota bug in 26.2.4 and avoid memory crash issue with 26.2.3 until 26.2.5 is released.

## 1.0.0-rc.17
### Fixed
* Fixes a bug when synchronising legacy formatted data

## 1.0.0-rc.16
### Fixed
* Bug introduced `1.0.0-rc.15` on JWT parsing

## 1.0.0-rc.15

### Added
- Partisan forwarding guarantees configuration.
   - `router.forward.ack`
   - `router.forward.retransmission`
   - `bridge.forward.ack`
   - `bridge.forward.retransmission`

### Changed
- Until Partisan guarantees are provided by a more scalable backend we are disabling them by default by removing the previously hardcoded configuration and defining the following `bondy.conf` options defaults
   - `router.forward.ack = on|off`
   - `router.forward.retransmission = on|off`
   - `bridge.forward.ack = on|off`
   - `bridge.forward.retransmission = on|off`
   -

### Fixed
- Fixed a bug that occurred in `bondy_rpc_laod_balancer` when entries are empty

## 1.0.0-rc.14

### Added
* Support for TCP/TLS proxy protocol and HTTP equivalent via headers
  `forwarded`, `x-real-ip`, `x-forwarded-for`. The algorithm searches for
  the presence of headers in that order and chooses the first Private IP found,
  returning the first IP Address if none are private.
    * New config options to enable/disable it
        * `wamp.tcp.proxy_protocol`
        * `wamp.tls.proxy_protocol`
        * `admin_api.http.proxy_protocol`
        * `admin_api.https.proxy_protocol`
        * `api_gateway.http.proxy_protocol`
        * `api_gateway.https.proxy_protocol`
        * `bridge.listener.tcp.proxy_protocol`
        * `bridge.listener.tls.proxy_protocol`
        * Default: `off`
    * New config options to define whether to reject connections when a
    `source_ip` address cannot be obtained from the proxy (`strict`) or
    fallback to the local IP address (`relaxed`).
        * `wamp.tcp.proxy_protocol.mode`
        * `wamp.tls.proxy_protocol.mode`
        * `admin_api.http.proxy_protocol.mode`
        * `admin_api.https.proxy_protocol.mode`
        * `api_gateway.http.proxy_protocol.mode`
        * `api_gateway.https.proxy_protocol.mode`
        * `bridge.listener.tcp.proxy_protocol.mode`
        * `bridge.listener.tls.proxy_protocol.mode`
        * Default: `relaxed`



### Fixes
* Fix bug in WAMP procedure `bondy.oauth2.token.revoke`
* Re-establish support for HTTP `x-forwarded-for` and `x-real-ip` headers
* Fixed logger formatter so that metadata values for keys not included in the
  template are included as part of the message.

## 1.0.0-rc.13
* Fixes #28 - default configuration value for Bridge Relay produces a crash. This happened because some of the Bridge Relay options in the schema were using `default` as opposed to `commented`. The result was an invalid configuration for a Bridge relayed called `name` when this should be empty.

## 1.0.0-rc.12

### Fixes
* Fixes #24 - missing command in Makefile target

### Changes
* Upgrades PlumDB to latest

## 1.0.0-rc.11

### Changes
* Upgrades Partisan to latest
* Upgrades OTP to latest

## 1.0.0-rc.10

### Fixes
* Fixes trying to restore non expired OAUTH2 refresh tokens based on its expiration time (issued at + expires in) from an old backup (tested case `0.41.6` version).

## 1.0.0-rc.9

### Fixes
* Fixes bug in enacl dependency via a fork

## 1.0.0-rc.8

### Fixes
* Fixes bug in authentication when migrating from Bondy version =< 0.8
* Change in Backup restore to avoid restoring and migrating expired OAUTH2 refresh tokens

## 1.0.0-rc.7
* Updated Docker image base OS version to match those of the new OTP26 images

## 1.0.0-rc.6
#### Fixes
* Upgrade Partisan with fixes to fast forward which was not working

## 1.0.0-rc.5
#### Fixes
* Upgrade PlumDB with fixes to hashtree encoding on OTP26
* PlumDB no creates a manifest will be used in the near future to enable database migration

## 1.0.0-rc.4
### Changes
* New config params `cluter.peer_ip` and `cluster.listen_addresses` based on updated Partisan

## 1.0.0-rc.3

### Changes
* Added support for IPv6 across all listeners
* Fixed port validaros accepting full port range (as opposed to previous rule which prescribed system ports)
* Added marketplace demo realm for testing
* Added Fly deployment
* Added dnsutils to Dockerimage
* Upgraded Partisan with support for IPv6 in DNS discovery.

```erlang
cluster.peer_discovery.type = dns
cluster.peer_discovery.config.record_type = aaaa
cluster.peer_discovery.config.nameservers.1 = fdaa::3
cluster.peer_discovery.config.query = bondy.internal
cluster.peer_discovery.config.node_basename = bondy
```

## 1.0.0-rc.2

### Changes
* The peer discovery capabilities was moved from bondy to Partisan. The interface remains very similar. The following two examples show how to configure the `list` and `dns` strategies in `bondy.conf`

```erlang
cluster.peer_discovery.enabled = on
cluster.peer_discovery.initial_delay = 10s
cluster.peer_discovery.polling_interval = 10s
cluster.peer_discovery.timeout = 5s
cluster.peer_discovery.type = list
cluster.peer_discovery.config.addresses = [127.0.0.1:18086]
```

```erlang
cluster.peer_discovery.enabled = on
cluster.peer_discovery.initial_delay = 10s
cluster.peer_discovery.polling_interval = 10s
cluster.peer_discovery.timeout = 5s
cluster.peer_discovery.type = dns
cluster.peer_discovery.config.record_type = fqdns
cluster.peer_discovery.config.query = bondy.internal
cluster.peer_discovery.config.node_basename = bondy
```

#### Fixes
* This revision addresses an issue in the Active Anti-Entropy (AAE) implementation of PlumDB and the latest version of Erlang/OTP. In the latest version of Erlang, the binary serialization of terms is not deterministic by default, causing the AAE merkle tree to compute different values for the same object in different nodes. As a result, the AAE sync continuously exchanges terms that are actually the same.


## 1.0.0-beta

### Added
 * Pattern matching now supports wildcards
 * Pattern-based Registration

#### General
* Upgraded to OTP 24

#### Security
* WAMP Cryptosign authentication
* WAMP Ticket-based authentication
* Same Sign-on and Single Sign-on (SSO Realms)
* Realm Prototypes
* Added libsodium (enacl lib)

#### Bondy Edge (EXPERIMENTAL)

* New Bridge Relay connection allows to link an edge router to a core/remote router. This syncs (at the moment) a single realm and forwards procedures and subscriptions to the remote.

### Fixed
* Fixes group ordering issue in processing of security (realm) configuration files.
    - bondy_realm topological ordering of groups within each realm according to their group membership relationship. If any cycles are found amongst groups, an error is raised.
    - Existing groups referred by name in the group's 'group' property are not fetched, so cycles might still be created once the new groups are stored on the database.
* Fixes a concurrency issue with busy clients, in particular when they end up calling themselves. This was produced by an unnecessary used of internal acknowledgments which have been removed
* Fixes the following issues: #6, #7, #8

### WAMP
* Erlang encoding now enforces WAMP-compatible data structures and tries to convert certain types e.g. pids while it fails with others.

### Changed
* Realm database representation
* User database representation
* Error types and description improvements
* Logging improvements
* Removed high cardinality labels in prometheus metrics (before we would tag each WAMP message stats with realm, session, message type etc. this is not good for stats databases like Prometheus).
* Added RBAC context caching to avoid computing the user grants on every request.
* Tickets database location: The location of the tickets changes on beta.64 onwards

## Known Issues

#### Security
* The RBAC context cache is not evicted or refreshed when a user is assigned to new realms or granted new permissions.

## 0.9.0
### Added

* `bondy.subscription.list` procedure
* First verstion of Retained messages
* Added a non-standard WAMP Authentication method `oauth2` based on OAuth2 JWT Tokens
    - Is equivalent to WAMP-Ticket authentication method but expects the secret to be a JWT produced by Bondy OAuth2
    - `authid` property value needs to be present and needs to match the JWT’s `sub` property value
* Added Bondy specific load balancing strategies through the standard  `REGISTER.Options.invoke` option:
    - queue_least_loaded
    - quede_least_loaded_sample
    - jump_consistent_hash (MUST not be used as this is experimental and the implementation will change with upcoming definitions from WAMP Specification)
* Added support for WS compression
    - now supports permessage-deflate websocket extension and enabled by default
    - added configuration option `wamp.websocket.compression_enabled`
    - added configuration option `wamp.websocket.deflate.level`
    - added configuration option `wamp.websocket.deflate.mem_level`
    - added configuration option `wamp.websocket.deflate.strategy`
    - added configuration option `wamp.websocket.deflate.server_context_takeover`
    - added configuration option `wamp.websocket.deflate.client_max_window_bits`
    - added configuration option `wamp.websocket.idle_timeout`
    - added configuration option `bondy.wamp_websocket.max_frame_size`
    - Not working with Mozilla as it seems to be sending a corrupted PING message

### Fixed

* Minor WAMP protocol fixes
* Several bug fixes during removal of an API Specification
    - Removal did not rebuilt the web server dispatch tables and thus the API removed was still active until reboot.
* Cleanup of session data when web server processes crash abnormally

### Changed
* Upgraded to Erlang 23
* Security data structures
* Security methods (more methods added and a clear distinction between 'anontmous' and 'trust')

## 0.8.8
### Added

* API Gateway
    * The API specification body object now supports any external-friendly data type e.g. erlang tuples, pids, references excluded.
    * Fixes a bug in the validation of the response body which failed in case the body was not a MOPS expression, a binary or map. Now all external-friendly types are allows e.g. numbers, booleans, strings, binaries, maps, lists and MOPS expressions. This allows to return static content i.e. not a result of evaluating a MOPS expression in any given type of action.
    * Upgraded MOPS which has better error reporting and support for a new function `random(N)` which returns N random members from a list. If the value random is applied is static, this will yield the same results on every request.

### Fixed

* API Gateway
    * Minor fixes to enhance error handling and logging
    * Fixed a case where an invalid API Specification can crash the gateway process during startup
* Configuration
    * Fixed an error in which private/default lager configuration would override user configuration (bondy.conf)
    * OAuth2
        * Fixed a bug on the removal of refresh token indices during refresh token revocation.
* Clustering
    * Fixed missing handler for WAMP ERROR(CALL) messages forwarded by a peer node

### Changed

* Configuration
    * The WAMP raw socket serialiser slot assignment is now configurable. Bondy provides Erlang (erl) and BERT serialisers in addition to JSON and Messagepack. This change allows the user to configure to which of the 13 available slots (3..15) are those serialisers mapped to.



## 0.8.7

### Added

- Added a controlled phased startup process
  - Bondy now starts in phases allowing to block on several steps using configuration parameters. The main benefit is to avoid starting up the WAMP client socket listeners before several subsystems have finish initialisation and/or some processes have been completed.
    - `startup.wait_for_store_partitions` - controls whether to block further stages until all db partitions have been initialised, this includes loading all data into those entities stored in ram and disk. Default is `on`.
    - `startup.wait_for_store_hashtrees` - defines whether Bondy will wait for the db hashtrees to be built before continuing with initialisation. Default is `on`.
    - `startup.wait_for_store_aae_exchange` - Defines whether Bondy will wait for the first active anti-entropy exchange to be finished before continuing with initialisation. These only works if Bondy is part of a cluster i.e. when Peer Discovery and Automatic Cluster join is enabled.
  - The Bondy Admin HTTP API listeners are started as soon as the store partitions and other subsystems are initialised. This allows for liveness probes to be able to check on Bondy and/or admin users to inspect and/or operate while the other phases are running.

### Fixed

- Several fixes to Security Configuration file format
  - `sources.usernames` now takes a string "any" of a list of usernames, including "anonymous"
  - `grants.roles` now takes a string "any" of a list of rolenames, including "anonymous"

## 0.8.6

- First implementation of Peer Discovery and Automatic Cluster join.
  - Implementation of DNS srv based discovery tested to work with Kubernetes DNS
- Finished Bondy Broker schema specification
- Added authorization controls for all WAMP verbs (register, unregister, call, cancel, publish, subscribe and unsubscribe). Authorization is managed by the existing Security subsystem which now can be configured using JSON files defined in the bondy.conf file (in addition to the WAMP and HTTP/REST APIs).
- Fixed WAMPRA (with salted password) authentication method.
  - This requires a rehash of the existing passwords. If you are migrating from an existing Bondy installation, the migration occurs lazily on the new user login (as we need the user to provide the password for Bondy to be able to rehash, as Bondy never stores clear text passwords).
- Refactoring of configuration via bondy.conf
  - Removed legacy config options,
  - Renamed a few a config options and introduced new ones to support static configuration via JSON files and new features like Peer Discovery and Automatic Cluster join.

## 0.8.2

- Migration to OTP 21.3 or higher.
- Upgraded all dependencies to support OTP 21

## 0.8.1

This version includes a complete redesign of event management and instrumentation.
The new `bondy_event_manager` is now the way for the different subsystems to asynchronously publish events (notifications) and offload all instrumentation to event handlers:

- `bondy_promethues` is an event handler that implements all prometheus instrumentation
- `bondy_wamp_meta_events` is an event handler that selectively re-published bondy events to WAMP Meta events.

### New Modules

- `bondy_event_manager` implements a form of supervised handlers similar to lager (logging library), by spawning a "watcher" processes per handler (module) under a supervision tree and restarting it when it crashes.

- `bondy_alarm_handler` replaces sasl’s default alarm_handler.

### Deprecated Modules

`bondy_stats` containing legacy exometer instrumentation was removed.

## 0.8.0

This version introduces an incompatibility with previous versions data storage. If you want to upgrade an existing installation you will need to use the bondy_backup module's functions or the Admin Backup API.

- Upgrade to plum_db 0.2.0 which introduces prefix types to determine which storage type to use with the following types supported: ram (ets-based storage), disk (leveledb) and ram_disk(ets and leveldb).
    - Registry uses `ram` storage type
    - All security resources use `ram_disk` storage type
    - Api Gateway (specs) and OAuth2 tokens use `disk` storage type
- Handling of migration in bondy_backup. To migrate from v0.7.1 perform a backup on Bondy v0.7.1 and then restore it on Bondy v0.7.2.

## 0.7.1
- New Trie data structure for bondy_registry
    - Bondy now uses Leapsight's `art` library to implement the registry index structure use to match RPC calls and PubSub subscriptions. `art`  provides a single-writter, multi-reader Radix Trie following the Adaptive Radix Tree algorithm. The implementation uses one gen_server and one ets table per trie and currently supports WAMP `exact` and `prefix` matching strategies. `wildcard` matching support is on its way.
- Internal wamp subscriptions
    - We have implemented a first version of an internal WAMP subscription so that Bondy internally can subscribe to WAMP events. This is done through new functions in bondy_broker and the new module bondy_broker_events
- OAuth 2 Security
    - Major changes to security subsystem including harmonisation of APIs, deduplication and bug fixes.
    - Use new internal wamp subscriptions to avoid coupling Bondy Security with Bondy API Gateway & OAuth.
        - Bondy Security modules publishe wamp events on entity actions e.g. user creation, deletion, etc.
        - Bondy API Gateway modules and bondy_api_gateway_client subscribe to the user delete events to cleanup OAuth tokens
    - Fixed a bug where internal security operations will not trigger token revocation.
        - Bondy API Gateway modules, i.e. are now implemented by calling Bondy Security modules e.g. bondy_security_user instead of calling bondy_security (former Basho Riak Core Security) directly. This will help in the refactoring of bondy_security and in addition all event publishing is centralised in bondy_security_user.
        - Implemented additional index for tokens to enable deletion of all users’ tokens
        - Added two db maintenance functions to (i) remove dangling tokens and (ii) rebuild the indices on an existing db
    - Added additional Internal wamp events to subsystems e.g. bondy_realm and bondy_backup

## 0.7.0

- Clustering
    - Completion of clustering implementation using partisan library (at the moment supporting the default peer service only, hyparview to be considered in the future)
    - bondy_router can now route WAMP messages across nodes. The internal load balancer prefers local callees by default, only when a local callee is not found for a procedure the invocation is routed to another node. Load balancer state is local and not replicated. Future global load balancing strategies based on ant-colony optimisation to be considered in the future.
    - `bondy-admin` (bondy_cli) implementation of cluster management commands (join, leave, kick-out and members)
- Storage and Replication
    - new storage based on plum_db which
        - uses lasp-lang/plumtree and lasp-lang/partisan to support data replication
        - provides more concurrency than plumtree and removes the capacity limitation imposed by the use of dets
- API Gateway
    - API Specs are replicated using plum_db. A single bondy_api_gateway gen_server process rebuilds the Cowboy dispatch table when API Spec updates are received from other nodes in the cluster (using plum_db pubsub capabilities)
- Registry
    - The registry entries are replicated using plum_db. This is not ideal as we are using disk for transient data but it is a temporary solution for replication and AAE, as we are planning to change the registry by a new implementation of a trie data structure at which point we might use plumtree and partisan directly avoiding storing to disk.
    - A single bondy_registry gen_server process rebuilds the in-memory indices when entry updates are received from other nodes in the cluster (using plum_db pubsub capabilities)
- bondy_backup
    - A new module that allows to backup the contents of the database to a file, and restore it.
    - Allows to migrate from previous versions that use plumtree (dets) to plum_db

## 0.6.6

- General
    - Removed unused modules
    - Minor error description fixes
    - Code tidy up
- Dependencies
    - cowboy, hackney, jsx, sidejob, promethus, lager and other dependencies upgraded
- Oauth2
    - Revoke refresh_token
    - Added client_device_id optional parameter for token request which will generate an inde mapping a Username/ClientDeviceId to a refresh_token to enabled revoking token by Username/ClientDeviceId.
    - JWT.iat property using unix erlang:system_time/1 instead of erlang:monotonic_time/1 (as users might want to use this property)
    - Token expiration is now configured via cuttlefish
- API Gateway
    - JSON errors no longer include the status_code property (this was redundant with HTTP Status Code and were sometimes inconsistent)
    - Added http_method in forward actions to enable transforming the upstream HTTP request method e.g. a GET can be transformed to a POST
    - API Gateway Spec now allows to use a mop expression for WAMP procedure URIs
    - New mops functions: min, max and nth on lists (equivalent to the lists module functions)
- Testing
    - Fixed mops suite bugs
    - Added oauth2 refresh_token CRUD test case, covering creation, refresh and revoke by token and by user/client_device_id

## 0.6.3

* Upgraded Cowboy dependency to 2.1.0
* Upgraded promethues_cowboy to latest and added cowboy metrics to prometheus endpoint
* Minor changes in function naming for enhanced understanding
* Minor fixes in options and defaults
