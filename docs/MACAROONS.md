# Macaroons for MQTT Authorization

This document specifies how Commonplace uses macaroons to enforce publish/subscribe permissions at the MQTT broker layer (e.g., Mosquitto).

Related: `docs/MQTT.md` (topic structure and ports).

## Goals

- Enforce authorization for all MQTT clients (processes, devices, gateways) without putting ACL logic in every client.
- Make credentials **delegatable**: holders can attenuate (restrict) a token without contacting the issuer.
- Support fine-grained permissions over MQTT topics (publish vs subscribe) using topic filters.
- Keep the initial implementation **offline-verifiable** at the broker (no network call per message).

## Non-Goals (v1)

- Strong user identity or end-user login UX.
- Instant revocation of individual tokens (see “Revocation and Rotation”).
- Authorization for HTTP endpoints (`/docs/*`); this spec is MQTT-layer only.

## Components

### 1) Issuer (minting)

Creates “root” macaroons using a server-side secret key and attaches first-party caveats.

Implementation options (pick one for v1):
- A local CLI (e.g., `commonplace-macaroon mint …`) that reads the root key from disk.
- A localhost-only HTTP endpoint on `commonplace-server` that mints macaroons (guarded by an admin secret).
- Orchestrator integration (orchestrator mints per-process tokens and injects them via env vars).

### 2) Holder (client)

Connects to MQTT and presents a macaroon. Optionally attenuates it (adds stricter caveats) before handing it to a subprocess.

### 3) Verifier (Mosquitto auth plugin)

Validates macaroons and enforces publish/subscribe ACLs:
- At CONNECT time: verifies signature, checks time/audience/client-id caveats, parses ACL caveats.
- At PUBLISH/SUBSCRIBE time: checks topic access against parsed ACLs.

Optional (future): the plugin can call a local “auth verifier” service for third-party caveats / revocation.

## Token Transport (MQTT CONNECT)

For maximum client compatibility, macaroons are transported using MQTT username/password:

- `username`: optional human-readable actor name (for logging only).
- `password`: macaroon in URL-safe base64 (`base64url`) form.

If a client can’t set password, allow an alternate format:
- `username`: `macaroon`
- `password`: token

The broker must reject connections without a valid macaroon unless explicitly configured to allow anonymous access for development.

## Caveat Schema (Commonplace v1)

Macaroons carry first-party caveats. This spec defines a small set of caveat types with stable string encodings.

### Version

- `cp.v=1`

### Expiration (recommended)

- `cp.exp=<unix_seconds>`

Verifier rule: deny if current time is greater than `cp.exp`.

### Audience (recommended)

- `cp.aud=<broker_id>`

Use to prevent replay of a token against a different broker. `broker_id` can be a configured string (e.g., `dev`, `prod`, or a hostname).

### Bind to MQTT client id (optional)

- `cp.cid=<mqtt_client_id>`

Use to reduce token replay risk if stolen. This weakens delegatability (one token per client id).

### ACL (required)

ACL caveats define allowed publish/subscribe topic filters. Because macaroons can only be attenuated, ACL caveats must be interpreted as an **intersection**: every ACL caveat must allow the requested action.

Encoding:

- `cp.acl=<base64url(json)>`

Where `json` is:

```json
{
  "publish":   ["terminal/screen.txt/edits", "terminal/screen.txt/commands/restart"],
  "subscribe": ["terminal/screen.txt/edits", "terminal/screen.txt/events/#"],
  "both":      ["terminal/screen.txt/sync/observer-1"]
}
```

Rules:
- Arrays contain MQTT topic filters (`+` and `#`).
- `both` applies to both publish and subscribe checks.
- A request is allowed by an ACL caveat if it matches **any** filter in the relevant arrays.
- If multiple `cp.acl` caveats are present, the request must be allowed by **each** caveat (intersection).

This supports attenuation by adding an additional `cp.acl` caveat with a narrower allow-list.

## Authorization Rules

### CONNECT

On CONNECT, the verifier must:

1. Parse and decode macaroon from password.
2. Verify signature using the configured root key (and `cp.kid`/key id if implemented).
3. Evaluate non-topic caveats (`cp.v`, `cp.exp`, `cp.aud`, `cp.cid`).
4. Parse all `cp.acl` caveats and cache the result for the session.

If any step fails: deny connection.

### PUBLISH

Given a publish topic `t`:

- Allow iff every `cp.acl` caveat allows `publish` for `t` (including `both` filters).

### SUBSCRIBE

SUBSCRIBE uses topic *filters*. The verifier must ensure a requested subscription filter does not exceed allowed scope.

Two acceptable policies:

1. **Subset check (preferred)**: allow iff the requested filter is a subset of an allowed filter for `subscribe` (or `both`).
2. **Exact-match (v1 fallback)**: allow only if the requested filter string exactly equals an allowed filter string.

If subset logic isn’t implemented initially, start with exact-match and require clients to subscribe to explicit topics (Commonplace already tends to enumerate known paths rather than use broad wildcards).

## Minting and Delegation

### Mint (issuer)

Issuer produces a token with:
- `cp.v=1`
- at least one `cp.acl`
- a short `cp.exp` (hours/days), plus `cp.aud`
- optional `cp.cid`

### Attenuate (holder)

Holders can add caveats to restrict:
- shorter `cp.exp`
- narrower `cp.acl`
- bind to a specific `cp.cid` if desired

No root key required to attenuate.

## Revocation and Rotation

Macaroons are bearer tokens; v1 should assume **no instant revocation**.

Recommended v1 strategy:
- Short expirations (`cp.exp`)
- Periodic root key rotation (and invalidate old keys)

Optional future strategy:
- Add a third-party caveat that requires an online discharge from a local verifier service, enabling per-token revocation.

## Observability

Verifier should log structured deny reasons (at least):
- invalid signature / unknown key id
- expired
- audience mismatch
- client-id mismatch
- topic denied (publish/subscribe) including requested topic/filter

Commonplace processes should log the MQTT `client_id` they use so tokens can be bound when needed.

## Security Considerations

- Use TLS for MQTT if tokens traverse untrusted networks (otherwise macaroons can be sniffed and replayed).
- Treat macaroons as secrets (avoid printing tokens in logs).
- Prefer short-lived tokens and delegation via attenuation rather than minting broad, long-lived tokens.

