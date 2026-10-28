# CHANGELOG

## Unreleased
### Changes:
- A callee answers an INTERRUPT with `ERROR` for the INVOCATION, as the WAMP
  spec requires, instead of `ERROR` for the INTERRUPT. A `kill` cancel now
  settles the call at the router.
- An in-VM (`local`) peer receives the arguments that a peer on a socket sent;
  the router's adapter decodes a payload that arrives still encoded, where the
  peer used to see empty arguments.
- The in-VM (`local`) transport forwards nothing after the router aborts the
  session; a request already queued in the connection returns
  `{error, closed}`, as over a socket. The `bondy_connect_local` handler
  behaviour's `forward/2` may return `{stop, Abort}`.
- A callee handler of a progressive call that also asked for progressive
  results gets both the `input` and the `progress` fun. Handler details no
  longer carry the WAMP `progress` flag; the `input` fun stands for it.
- A callee discards a progressive call chunk that arrives after its handler
  replied, instead of running the handler again with that chunk.
- `send_input/4` and `finish_input/4` return `{error, input_finished}` without
  sending once the stream's final chunk was sent.
- `send_input/4` and `finish_input/4` return the transport's error when a chunk
  is not sent, instead of `ok`.
- `call_stream/5` returns `{error, #{kind := client, reason :=
  feature_not_supported}}` without sending when the router did not announce
  `progressive_call_invocations`, instead of a CALL that ends the session.
- Pre-1.0 API normalisation onto `{ok, _}` / `{error, _}` across the callee
  handler contract, `call*`, `publish`, and `bondy_connect_dispatch:worker_pid/2`:
  - Callee handler returns collapse from seven forms
    (`{reply, _}` / `{reply, _, _}` / `ok` / `noreply` / `{error, _}` /
    `{error, _, _}` / `{error, _, _, _}`) to three:
    `ok` | `{ok, #{args => _, kwargs => _}}` | `{error, #{uri := _, args => _,
    kwargs => _}}`. `noreply` is removed (it was a synonym for `ok`).
  - `call/2..5`, `call_async/3..5`, `call_stream/5`, `register/3,4`,
    `unregister/2`, `subscribe/3,4`, `unsubscribe/2` and the new
    `publish_ack/3,4,5` now return a discriminated `{error, #{kind := wamp,
    uri := _, ...} | #{kind := client, reason := _}}` instead of a union of
    a WAMP-error map and a bare atom.
  - `publish/3,4,5` stays fire-and-forget only (`ok | {error, term()}`) and
    now rejects an explicit `acknowledge => true` in `Opts` with
    `{error, badarg}`; `publish_ack/3,4,5` is the new acknowledged-publish
    API, returning `{ok, PublicationId}`.
  - `bondy_connect_dispatch:worker_pid/2` returns `{error, not_found}`
    instead of a bare `error`.
