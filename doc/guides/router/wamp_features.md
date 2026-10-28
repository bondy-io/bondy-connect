# WAMP Features

This guide lists the WAMP features Bondy implements as a router, explains how
a session obtains them, and states the contracts of the RPC features that
Bondy extends or restricts.

## Features are build capabilities

The features Bondy announces are a property of the build, not of the
configuration. They are defined in `apps/bondy_router/include/bondy.hrl`
(`?DEALER_FEATURES` and `?BROKER_FEATURES`), seated in the application
environment at boot, and advertised in every `WELCOME` under
`roles.dealer.features` and `roles.broker.features`. There is no `bondy.conf`
key for any of them.

What a session may use is negotiated per session from its `HELLO`. For each
client role (`caller`, `callee`, `publisher`, `subscriber`), Bondy compares
the features the client announced with its own table for that role:

- A feature that both sides set to `true` is enabled.
- A feature that either side sets to `false` is disabled.
- A feature the client omits takes Bondy's value, except for the strict
  opt-in features `progressive_call_results`, `progressive_call_invocations` and
  `call_canceling`. A client that omits one of these is given `false`
  (`bondy_connect_conformance_SUITE:progressive_results_need_opt_in`;
  `bondy_connect_cancel_SUITE:kill_without_callee_support_skips`).

### Dealer

| Feature | Advertised |
| --- | --- |
| `progressive_call_results` | `true` |
| `progressive_call_invocations` | `true` |
| `call_timeout` | `true` |
| `call_canceling` | `true` |
| `caller_identification` | `true` |
| `payload_passthru_mode` | `true` |
| `pattern_based_registration` | `true` |
| `shared_registration` | `true` |
| `session_meta_api` | `true` |
| `registration_meta_api` | `true` |
| `reflection` | `true` |
| `caller_auth_claims` (Bondy only) | `true` |
| `sharded_registration` | `false` |
| `call_reroute` | `false` |
| `call_trustlevels` | `false` |
| `registration_revocation` | `false` |
| `testament_meta_api` | `false` |

### Broker

| Feature | Advertised |
| --- | --- |
| `payload_passthru_mode` | `true` |
| `publisher_identification` | `true` |
| `subscriber_blackwhite_listing` | `true` |
| `publisher_exclusion` | `true` |
| `pattern_based_subscription` | `true` |
| `event_retention` | `true` |
| `session_meta_api` | `true` |
| `reflection` | `true` |
| `sharded_subscription` | `false` |
| `publication_trustlevels` | `false` |
| `event_history` | `false` |
| `subscription_revocation` | `false` |
| `subscription_meta_api` | `false` |
| `acknowledge_event_received` (non-standard) | `false` |
| `acknowledge_subscriber_received` (non-standard) | `false` |

`reflection` is served by the `wamp.reflection.procedure.*`,
`wamp.reflection.topic.*` and `wamp.reflection.error.*` procedures (`list` and
`describe` for each).

## Call deadline

`CALL.Options._deadline` is a Bondy extension option. Its value is a positive
integer number of milliseconds, counted from the moment Bondy starts handling
the `CALL`. Any other value is ignored, and the call has no deadline.

- **Routed calls.** The deadline caps the call: the call expires at the
  earlier of its timeout and its deadline, and the caller receives
  `wamp.error.timeout`. For a progressive call, where each result or input
  chunk restarts the timeout, the deadline bounds the whole stream
  (`bondy_rpc_promise_SUITE:refresh_capped_by_deadline`,
  `bondy_connect_rpc_SUITE:progressive_deadline_caps_stream`).
- **Bondy's own procedures.** A `bondy.*` procedure that waits reads the same
  option and can only shorten its own wait, never lengthen it.
  `bondy.cluster.leave` bounds its survey of the remaining members with it, and
  an unanswered member counts as unsafe. `bondy.alarm.list`, `bondy.alarm.get`
  and `bondy.alarm.history` bound their cluster reads with it; a progressive
  `bondy.alarm.history` stream that runs out of deadline ends with
  `wamp.error.timeout` (`bondy_alarm_api_SUITE:a_stream_stops_at_the_deadline`).

## Call cancellation

`CANCEL` supports the modes `skip`, `kill` and `killnowait`, including when the
callee is connected to another cluster node: the caller's node relays the
`CANCEL` to the callee's node, which interrupts the callee
(`bondy_connect_cluster_rpc_SUITE:progressive_remote_cancel_interrupts_callee`).

- `skip` answers the caller at once and sends no `INTERRUPT`; a late result
  is discarded.
- `kill` sends an `INTERRUPT`; the callee's response settles the call.
- `killnowait` answers the caller at once and sends an `INTERRUPT`; a late
  result is discarded.

When a caller's session ends, Bondy sends `INTERRUPT` with mode `killnowait`
for each call it still has in flight, so the callee stops work nobody will
consume. A callee on the same node is interrupted directly. For a callee on
another node, the cancellation is relayed to that node
(`bondy_connect_cluster_rpc_SUITE:progressive_remote_caller_death_interrupts_callee`).

Bondy sends `INTERRUPT` only to a callee that announced `call_canceling` in
its `HELLO`. For any other callee, `kill` and `killnowait` act as `skip`: the
caller is answered at once and the callee's late result is discarded, whether
the callee is on the caller's node or another
(`bondy_connect_cancel_SUITE:kill_without_callee_support_skips`,
`killnowait_without_callee_support_skips`;
`bondy_connect_cluster_rpc_SUITE:remote_kill_without_callee_support_skips`).

A `CANCEL` the caller may not make, because its role lacks `wamp.cancel` on
the procedure, gets no reply, since WAMP defines no `ERROR` for a `CANCEL`. The
call runs on and the caller receives its result
(`bondy_connect_cancel_SUITE:a_refused_cancel_leaves_the_call_running`).

## Call retries

`CALL.Options._retries` is a Bondy extension option. A positive integer asks
the dealer to route the call again when it gets no answer. Any other value is
ignored (`bondy_rpc_retry_SUITE:retries_that_are_not_an_integer_are_ignored`).
The dealer retries in two cases:

- The call timed out, or its callee was lost, and the registration set
  `REGISTER.Options._idempotent` to `true`. A procedure that did not set it is
  never retried, because its callee may already have run the call
  (`a_call_to_a_procedure_not_idempotent_is_not_retried`).
- The call found no registration. No callee ran it, so `_idempotent` does not
  apply. The call waits for a registration and backs off between attempts
  (`no_such_procedure_waits_for_a_registration`).

Each attempt counts against `_retries`. With a `_deadline`, no attempt starts
after the deadline (`no_attempt_starts_after_the_deadline`). Without one, the
call gets `_retries + 1` call timeouts
(`retries_without_a_deadline_use_the_call_timeouts`). A call that asks for
progressive results or sends progressive input is never retried, because the
caller may already hold part of its results
(`progressive_results_call_is_not_retried`,
`progressive_input_call_is_not_retried`). A forwarded call is retried on the
callee's node first, and on another node when that node has no registration
left (`bondy_rpc_retry_cluster_SUITE`).

## Shared registration

The first callee to register a URI decides whether more registrations are
allowed and which invocation rule applies (WAMP shared registration). The
check and the insert run in one registry partition process on the node, so
two concurrent `single` registrations of one URI on a node admit one and
refuse the other
(`bondy_registry_SUITE:concurrent_single_registrations_admit_one`).

## Publication filtering

The broker applies the `PUBLISH` options `exclude`, `eligible`, `exclude_me`,
`exclude_authid`, `eligible_authid`, `exclude_authrole` and
`eligible_authrole` to every subscription, whatever its match policy, and to
a retained event sent to a new subscriber
(`bondy_broker_publish_options_SUITE`). An `eligible` list that is empty, or
that the exclusions empty, delivers the event to no subscriber
(`empty_eligible_list_admits_no_one`,
`eligible_list_emptied_by_exclusion_admits_no_one`). A new subscriber receives
a retained event once (`retained_event_honours_the_lists`).

## Meta events

Bondy publishes `wamp.registration.on_register`,
`wamp.registration.on_unregister`, `wamp.subscription.on_subscribe` and
`wamp.subscription.on_unsubscribe`, as `wamp.meta_events` allows. It does not
publish `on_create` or `on_delete`. Those events mark a URI's first
registration or subscription and its last, and a cluster cannot decide
"first" and "last" for a URI without coordinating its nodes
(`bondy_meta_events_SUITE`). To learn whether a URI has registrations or
subscriptions, call the `wamp.registration.*` and `wamp.subscription.*` meta
procedures.

## Payload Passthru Mode and Bondy's procedures

A `CALL` that carries `Options.ppt_scheme` to a procedure that Bondy itself
implements (the `bondy.*` and `wamp.*` procedures, and internal callbacks) is
refused with `wamp.error.invalid_argument`, because Bondy cannot read a
passthru payload
(`bondy_internal_decode_SUITE:callback_procedure_refuses_payload_passthru`).

## URI validation

URI validation rejects every control character, `\x00` to `\x1F` and `\x7F`,
in both the `loose` and the `strict` rule
(`bondy_wamp_uri_SUITE:control_chars_rejected`).

A realm URI is validated with the same rule when the realm is created, so a
realm URI that contains NUL is refused. The storage layer also refuses a
NUL-bearing realm (`bondy_db_publish_list_test`, "a NUL-bearing realm is
refused").

## Protocol violations

Bondy aborts a session with `wamp.error.protocol_violation` when a message it
receives is not a valid WAMP message. Each of these cases aborts the session:

- A JSON or CBOR frame that does not decode, including a frame with
  trailing bytes or a malformed payload
  (`bondy_wamp_protocol_SUITE:invalid_json_is_a_decoding_error`,
  `invalid_cbor_is_a_decoding_error`,
  `a_malformed_payload_is_a_decoding_error`).
- A frame whose top level is not an array
  (`a_frame_that_is_not_an_array_is_an_invalid_message`).
- A request or session id that is not an integer from 0 to 2^53
  (`an_invalid_id_is_an_invalid_message`).
- A field of the wrong type (`a_field_of_the_wrong_type_is_an_invalid_message`).
- A `HELLO` that announces no role
  (`invalid_hello_roles_are_a_protocol_violation`).
- A term outside the WAMP data model in an `erl` frame, such as a tuple or
  an improper list
  (`a_term_outside_the_wamp_data_model_is_a_protocol_violation`).
