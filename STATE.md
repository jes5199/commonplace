# Project state

## FRONTIER

> RENDERED 2026-08-27T14:47Z — TRUST UNTIL 2026-08-27T17:33Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

Ready: **333** · Blocked: **15**
- `CX-1ern` [p1] trust.json LOOKS EMPTY AND INERT AND IS LOAD-BEARING — deleting it silently flips the workspace from ENFORCING to PERMISSIVE (absent => accept_unsigned: true) — claimed_by: unclaimed
- `CX-27vt` [p1] Filesystem seam S1: CI ratchet that compiles core with sync/ and process/ EXCLUDED — assert the build RAN, and ship a tamper control that goes red — claimed_by: unclaimed
- `CX-3nf4` [p1] bd CLI cannot file/update/close tickets under enforce — cli/bd.ex passes no :signing_context, gate refuses, CLI prints a minted id anyway (create :105, update :151, close :160) — claimed_by: unclaimed
- `CX-4k36` [p1] chat-over-web bots: audit serve wiring + make real on the web chat surface — claimed_by: unclaimed
- `CX-4u03` [p1] Zone-ownership M2: growing zones — Tree.ChildMutation chokepoint + move-cleared zone-stamp — claimed_by: unclaimed
- `CX-579x` [p1] READ GATE UNSET on the live serve (COMMONPLACE_LOCAL_READ_GATE absent => permissive) — co-requisite of any attenuated write cert, not a follow-up; with egress open, readable = exfiltratable — claimed_by: unclaimed
- `CX-9rd3` [p1] Unified permission model — read + code perms on the cert backbone — claimed_by: unclaimed
- `CX-aq4g` [p1] State-projection hook TRUNCATES at ~2KB: FRONTIER survives, TRACKER-TRUST is dropped -- delivery keeps the claim and cuts the warning (confidence inversion) — claimed_by: unclaimed
- `CX-aya0` [p1] MUD-as-docs Inc-2: stateless-leaf verbs (look/examine/inventory/emote/say) doc-hosted via SourceDoc.compile + Gate-B — claimed_by: unclaimed
- `CX-bxsh` [p1] chat-over-mcp bots: audit + make real on the MCP chat surface (loom_send/loom_read) — claimed_by: unclaimed
- `CX-cj3t` [p1] (EPIC) MUD improvement — fix + harden the multiplayer MUD from dogfood findings — claimed_by: unclaimed
- `CX-dzfv` [p1] tix-migration step 3: cutover — all agents switch to tix verbs, bd sync daemon retired — claimed_by: unclaimed
- `CX-fogy` [p1] Verb-authoring M1: execute-safe cert at home-genesis + editable-flag gate fix (trust-core) — claimed_by: unclaimed
- `CX-g9ea` [p1] seed 16421 is a LEAD, NOT A HANDLE: population CHANGED between runs (2 failures -> 4; the Trust.ReadTest teardown race did NOT reproduce). Deterministic across all runs so far: MUD room_visibility_test.exs:372 renders no description - and it SURVIVED the CX-0hbs fix, so that is not the cause — claimed_by: unclaimed
- `CX-ght7` [p1] Chat-bots: genuine signed principals across all surfaces (web + mcp + worker) — claimed_by: unclaimed

## IN-FLIGHT

> RENDERED 2026-08-27T14:47Z — TRUST UNTIL 2026-08-27T17:33Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- None.

## RECENT CLOSES

> RENDERED 2026-08-27T14:47Z — TRUST UNTIL 2026-08-27T17:33Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- None.

## OPEN-WITH-BLOCKER

> RENDERED 2026-08-27T14:47Z — TRUST UNTIL 2026-08-27T17:33Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-2jfb` 8 of 9 RedLog.commit call sites write unsigned AND discard the refusal; at bursar.ex:827 the signer is defined four lines above — ✅ TIER A + TIER B LANDED @be28010 (impl @6d2ecfd).
- `CX-5le4` Bd.Frontier.Server never started in production — ready/blocked view-docs and dependency-hell alarm never fire on the serve — RIDER DONE @10a3156 (prophylactic only — the bead itself is untouched and still blocked on poll-vs-push).
- `CX-nyvm` Mode A vs Mode B serve boot-gate parity (bursar_on_boot found missing; audit other on-boot gates) — THIRD INSTANCE OF THIS PARITY TRAP (2026-08-05, from CX-fml6).

## TRACKER-TRUST

> RENDERED 2026-08-27T14:47Z — TRUST UNTIL 2026-08-27T17:33Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

VERDICT: DISCREPANCIES — 149/351 shipped-but-OPEN; 7/636 closed-but-unreferenced SHAPES; scanned 2026-08-27T13:52Z; export as_of 2026-08-27T13:52Z (age 0h 0m)
