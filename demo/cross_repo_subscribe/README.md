# Cross-Repo Live Subscription — a read replica across trust roots

```
bash demo/cross_repo_subscribe/run_demo.sh
```

*"My **main** server subscribes to a doc on **the other** server; when the
other server edits it, my replica updates live — and a doc I was never
granted stays invisible."*

Two separate-rooted Commonplace workspaces as **two plain OS processes**.
No shared Erlang cookie, no epmd, no BEAM distribution — OTHER is just an
HTTP URL to MAIN. Reuses the cross-repo Slice-0 federation machinery: the
`PullClient` poll loop, `PeerTrust` root-pinning, and the `:read`-cert-gated
federation serve with existence-hiding.

## The cast

- **OTHER** (`other.exs`) — the host. A human root creates doc **D** and a
  second doc **E**. It mints a cross-root `:read` capability
  (`Trust.Read.grant`) whose **audience is MAIN's root key** and whose
  scope is `{:docs, [D]}` — **D only, never E**. Bandit serves the
  federation endpoints (bearer-token gated at the door, `:read`-cert gated
  per doc). Then it edits **D** three times on a ~2s timer, each a signed
  OTHER commit.

- **MAIN** (`main.exs`) — the subscriber, in a **separate trust domain**.
  It pins exactly one thing — OTHER's root pubkey (`PeerTrust.merge_peer_anchors`,
  anchored as `"peer:other"`). It configures OTHER as a federation peer,
  presents its `:read` cert for D, and runs `PullClient`'s periodic poll
  loop. Each tick it reconstructs D's replicated content and prints it — so
  as OTHER's three edits land, MAIN prints the content **updating live**.

## What you see

```
[OTHER] wrote: initial update 1
[MAIN]  D now: initial update 1
[OTHER] wrote: initial update 1 update 2
[MAIN]  D now: initial update 1 update 2
[OTHER] wrote: initial update 1 update 2 update 3
[MAIN]  D now: initial update 1 update 2 update 3
[MAIN]  E: denied/not-found (existence-hidden — no :read cert)
```

## The trust point

A **cross-trust-root LIVE read replica**: MAIN materializes OTHER's doc D
from commits verified against OTHER's **pinned root**, and its read is
**scoped by a `:read` cert**. The ungranted doc E is **existence-hidden** —
a denied request is byte-identical to a request for a doc that does not
exist (empty CID set), so MAIN cannot even tell E is there. WHO is asking is
resolved server-side from the authenticated bearer token, never from a
client-claimed value, so the cert's audience-binding can't be spoofed.

## Handshake (two-phase, via `$SHARED` files)

Both processes launch concurrently and rendezvous through a `mktemp`'d
`$SHARED` dir:

1. MAIN writes `main_pub.json` (its root identity + pubkey).
2. OTHER waits for it, mints the `:read` cert with **MAIN's root as
   audience**, serves, and publishes `manifest.json` (port, bearer token,
   OTHER's root pubkey, D uuid, E uuid, `:read`-cert cid) + `other_ready`.
3. MAIN waits for `other_ready`, pins OTHER's root, subscribes, and polls.
4. MAIN writes `main_done` with its exit code; `run_demo.sh` waits on it,
   prints the interleaved transcript sorted by wall-clock ms, and exits
   non-zero if propagation didn't happen.

`CP_KEEP_SHARED=1` keeps the scratch workspaces for inspection.

## Notes / honest scope

- **Identity trick.** OTHER's root `identity_uuid` is `"peer:other"` — the
  exact key `PeerTrust.merge_peer_anchors(name: "other")` pins it under —
  so MAIN's **write-import gate** (which fetches `trusted_identities` by the
  commit's signer identity) recognizes OTHER's root-signed D commits.
- **Full-state commits.** Each OTHER edit commits the full CRDT state
  (idempotent on replay), so MAIN reconstructs the complete text even from a
  partial chain.
- **Two mechanism touch-ups this demo surfaced** (both only reachable under
  *repeated* polling, which the single-shot `federation_real` demo never
  exercised):
  1. `PullClient.import_envelope` now treats an idempotent
     `:already_exists` re-import as a benign no-op instead of crashing the
     poll GenServer (a peer keeps serving a back-filled genesis in its CID
     set, and the local diff can re-offer it on a later poll).
  2. `import_with_translation` deliberately does not advance a puller's
     `:latest` for plain linear commits (CX-m3x preserves local heads; only
     merges self-adopt via `MergeAdopter`). MAIN never writes D locally, so
     it **fast-forwards its replica head** to the tip of OTHER's advertised
     chain each tick — a plain, safe linear catch-up.
- **Safety.** Scratch dirs under `mktemp -d /tmp/...`, a random high port,
  and cleanup that kills ONLY the exact demo scripts by path. It never
  touches `~/.commonplace`, any real data_dir, or a live serve.
