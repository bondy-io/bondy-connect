%% =============================================================================
%% SPDX-FileCopyrightText: 2016 - 2026 Leapsight
%% SPDX-License-Identifier: Apache-2.0
%% =============================================================================

-module(bondy_connect_secret_resolver_aws_sm).
-moduledoc """
AWS Secrets Manager provider for `bondy_connect_secret_resolver`.

Resolved by convention: `bondy_connect_secret_resolver` dispatches provider `aws_sm` to
`bondy_connect_secret_resolver_<aws_sm>` = this module's `fetch/1`. It lives here (rather
than in the dependency-light `bondy_connect_lib` core) because it carries the
`erlcloud` dependency.

Returns the raw `SecretString` bytes. A caller that stores several values in one
JSON secret (e.g. the HTTP Connector service secrets) decodes and field-maps on top;
a caller wanting a single JSON field passes `field => <<"...">>`.
""".

-include_lib("kernel/include/logger.hrl").

-export([ensure_transport/0]).
-export([fetch/1]).

%% =============================================================================
%% API
%% =============================================================================

-doc """
Fetches a secret from AWS Secrets Manager.

`Ref` requires `secret_id` and `region`; an optional `field` extracts a single
key from a JSON `SecretString`. Returns the raw bytes (or the field's value) as a
`binary()`.

Returns `{error, aws_credentials_not_found}` when `erlcloud` finds no
credentials, and the provider's reason when AWS rejects the request. Anything
else `erlcloud` raises propagates to the caller with the arguments in its top
stack frame replaced by their arity, since they can hold the secret
(`bondy_http_connector_secret_resolver_SUITE:aws_sm_no_credentials/1`,
`aws_sm_unexpected_raise_propagates/1`, `aws_sm_raise_carries_no_arguments/1`).
""".
-spec fetch(bondy_connect_secret_resolver:ref()) ->
    {ok, binary()} | {error, term()}.

fetch(#{secret_id := SecretId, region := Region} = Ref) ->
    try
        ok = ensure_transport(),
        case erlcloud_aws:auto_config() of
            {ok, Config0} ->
                Config = erlcloud_aws:service_config(
                    <<"sm">>, to_list(Region), Config0
                ),
                get_secret_value(SecretId, Region, Ref, Config);
            undefined ->
                ?LOG_ERROR(#{
                    description => <<"No AWS credentials found">>,
                    secret_id => SecretId,
                    region => Region
                }),
                {error, aws_credentials_not_found}
        end
    catch
        error:Reason:Stacktrace ->
            bondy_sensitive:raise(error, Reason, Stacktrace)
    end;
fetch(Ref) ->
    {error, {invalid_ref, Ref}}.

-doc """
Give `lhttpc` usable TLS defaults, if nothing else has.

`erlcloud` talks to AWS over `lhttpc`, which sends `{verify, verify_peer}` with
no CA certificates unless its application environment says otherwise -- and
since OTP 26 `ssl` rejects that pair outright with
`{options, incompatible, [{verify, verify_peer}, {cacerts, undefined}]}`. So
every AWS call fails, at the transport, before any credential is even offered.

This lives here, beside the only code in Bondy that makes such a call, because
it is a precondition of *this* provider rather than of whatever happens to have
started first. Arming it from another application's startup would make the AWS
secret provider work only on a node where that application had also started:
`bondy_connect_secret_resolver` is in `bondy_connect_lib` and is reached from realm key
encryption, the master key and outbound mail, none of which have any reason to
know that -- and the resulting failure names TLS options and no part of the
actual cause.

Idempotent, and never overrides a configured value: an operator who has set
`lhttpc`'s `ssl_options` has said something more specific than this can.
""".
-spec ensure_transport() -> ok.

ensure_transport() ->
    case application:get_env(lhttpc, ssl_options) of
        undefined ->
            application:set_env(
                lhttpc, ssl_options, bondy_cert_manager:ssl_opts()
            );
        {ok, _} ->
            ok
    end.

%% =============================================================================
%% PRIVATE
%% =============================================================================

%% @private
get_secret_value(SecretId, Region, Ref, Config) ->
    case erlcloud_sm:get_secret_value(SecretId, [], Config) of
        {ok, Proplist} ->
            SecretString = proplists:get_value(<<"SecretString">>, Proplist),
            extract(SecretString, maps:get(field, Ref, undefined));
        {error, Reason} ->
            ?LOG_ERROR(#{
                description =>
                    <<"Failed to fetch secret from AWS Secrets Manager">>,
                secret_id => SecretId,
                region => Region,
                reason => Reason
            }),
            %% Return the raw provider reason; callers add their own context
            %% (e.g. `{secret_resolution_failed, Service, Reason}`).
            {error, Reason}
    end.

%% @private
extract(SecretString, undefined) when is_binary(SecretString) ->
    {ok, SecretString};
extract(SecretString, Field) when is_binary(SecretString) ->
    case bondy_connect_secret_resolver:decode_json_object(SecretString) of
        {ok, #{Field := Value}} when is_binary(Value) ->
            {ok, Value};
        {ok, #{Field := _}} ->
            {error, {secret_field_not_string, Field}};
        {ok, #{}} ->
            {error, {secret_field_not_found, Field}};
        {error, _} = Error ->
            Error
    end;
extract(_Other, _Field) ->
    {error, secret_string_missing}.

%% @private
to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V).
