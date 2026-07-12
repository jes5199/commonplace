# Cross-Repo Pull Request — a proposal is DATA, the reviewer stays sovereign

```
bash demo/cross_repo_pull_request/run_demo.sh
```

*"Someone opens a pull request against **my** document. I stay sovereign — I
apply it as **my own** commit or I refuse it — and a **forged** PR cannot force
a change."*

Two separate-rooted Commonplace workspaces as **two plain OS processes**. No
shared Erlang cookie, no epmd, no BEAM distribution — each peer is just an HTTP
URL to the other. This is the cross-repo **B2 merge-request** mechanism
(`MergeRequest` / `Outbox` / `Apply`) riding on the Slice-0 federation seam
(`PullClient` poll loop + `PeerTrust` root-pinning + the `:read`-cert-gated
federation serve). Unlike the read-only `cross_repo_subscribe` demo, the
federation here is **bidirectional**: both peers serve *and* subscribe.

## The cast

- **REVIEWER** (`reviewer.exs`) — the sovereign. It OWNS doc **D** (`"spec v1"`),
  grants PROPOSER a scoped `:read` cert on D so PROPOSER can replicate it, and
  subscribes to PROPOSER's outbox. For each proposal it pulls, it runs
  `Apply.apply_proposal` — verifying the proposal's signature against the key it
  **pinned for PROPOSER**, then re-authoring an accepted delta as **its own
  signed commit** through its normal write path.

- **PROPOSER** (`proposer.exs`) — opens the PR, in a **separate trust domain**.
  It replicates D, authors a Yjs edit (`" + proposer's addition"`), signs it as a
  `MergeRequest`, and publishes it to its own append-only **outbox** (a doc it
  owns). Then a **stranger** keypair drops a **forged** proposal into the same
  outbox to prove the reviewer refuses it.

## The three money-shots

```
[REVIEWER] MONEY-SHOT #1 (proposal is DATA): I SEE 2 proposal(s) in PROPOSER's outbox,
[REVIEWER]   but D is STILL "spec v1" — a published proposal has changed NOTHING yet.
[REVIEWER] [REVIEWER] APPLIED PR (msg="please add my line") → D now: "spec v1 + proposer's addition"
[REVIEWER]   MONEY-SHOT #2 (REVIEWER sovereign): commit signer=REVIEWER (peer:reviewer), provenance=peer:proposer
[REVIEWER] [REVIEWER] REFUSED forged/unauthorized PR (bad_proposal) — D UNCHANGED, still "spec v1 + proposer's addition"
[REVIEWER]   MONEY-SHOT #3: a PR cannot force a merge. Authority stays with MY write-gate.
```

1. **PROPOSAL-IS-DATA** — after PROPOSER publishes, REVIEWER shows D **still
   unchanged**. Publishing a proposal changes nothing on its own.
2. **REVIEWER SOVEREIGN** — the applied commit is **REVIEWER-signed** with
   `provenance=peer:proposer`. Authority (the signer / write-gate) is REVIEWER;
   attribution (where the content came from) is PROPOSER. `authority ≠
   attribution`.
3. **FORGED PR REFUSED** — the stranger's proposal fails verification against
   PROPOSER's pinned key → `:bad_proposal` → D **UNCHANGED**. A PR cannot force a
   merge.

## The trust point

A **merge-request is DATA, not a capability.** Its signature proves
integrity + attribution ("this delta really came from B, untampered") and grants
**zero authority** over the target. Two cleanly-separated judgments: *who sent
this* (the proposal's carried signature vs the key the reviewer pinned for the
proposer, resolved **server-side** from which peer's outbox it arrived on — never
self-claimed) ⟂ *may this content be written* (the reviewer's **own write-gate**,
firing exactly as for a hand edit). Authority stays with the reviewer's own write
path; nobody can push a change into a repo they don't control.

## Handshake (two-phase, via `$SHARED` files)

Both processes launch concurrently and rendezvous through a `mktemp`'d
`$SHARED` dir, exchanging pubkeys mutually (each needs the other's root key as a
cert **audience**):

1. **Phase 1 — pubkey exchange.** REVIEWER writes `reviewer_pub.json`; PROPOSER
   writes `proposer_pub.json` (+ its outbox uuid). Each waits for the other's.
2. **Phase 2 — grant + serve.** REVIEWER mints a `:read` cert on **D** (audience =
   PROPOSER's root), serves federation, publishes `reviewer_manifest.json`
   (port, bearer token, root pubkey, D uuid, D-read-cert cid). PROPOSER mints a
   `:read` cert on its **outbox** (audience = REVIEWER's root), serves, publishes
   `proposer_manifest.json` (port, token, root pubkey, outbox uuid, outbox-read
   cert cid). The bearer token each hands the other is **identity-bound
   server-side** to that peer — the `:read`-cert gate resolves WHO is asking from
   the authenticated token, never from a client-claimed value.
3. **Phase 3 — subscribe.** PROPOSER pins REVIEWER's root, replicates D, authors
   and publishes its proposals. REVIEWER pins PROPOSER's root, subscribes to the
   outbox, and applies / refuses each proposal.
4. REVIEWER writes `reviewer_done` with its exit code; `run_demo.sh` waits on it,
   prints the interleaved transcript sorted by wall-clock, and independently
   greps the three money-shots.

`CP_KEEP_SHARED=1` keeps the scratch workspaces for inspection.

## Notes / honest scope

- **Identity trick.** Each root's `identity_uuid` is `"peer:reviewer"` /
  `"peer:proposer"` — the exact anchor key
  `PeerTrust.merge_peer_anchors(name: …)` pins it under — so the counterpart's
  **write-import gate** recognizes the other's root-signed commits.
- **Full-state deltas.** PROPOSER authors on D's replicated CRDT state, so its
  delta merges cleanly onto REVIEWER's head (the `" + proposer's addition"`
  insert references the shared base characters, no duplication).
- **Bidirectional fast-forward.** BOTH peers are read-only replicas of the
  other's doc (REVIEWER replicates the outbox; PROPOSER replicates D), and
  `import_with_translation` deliberately does not advance a puller's `:latest`
  for plain linear commits (CX-m3x). Each **fast-forwards only the doc it
  replicates** (never the doc it owns) — a safe linear catch-up.
- **CX-15ff.** `PullClient.import_envelope` tolerates an idempotent
  `:already_exists` re-import as a benign no-op (only reachable under *repeated*
  polling), so a re-offered back-filled genesis never crashes the poll GenServer.
- **Safety.** Scratch dirs under `mktemp -d /tmp/...`, random high ports, and
  cleanup that kills ONLY the exact demo scripts by path. It never touches
  `~/.commonplace`, any real data_dir, or a live serve.
