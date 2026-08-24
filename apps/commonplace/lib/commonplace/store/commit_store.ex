defmodule Commonplace.Store.CommitStore do
  # CX-mg8s: upper bound for CubDB key-range scans over binary keys.
  # MUST exceed every possible key. `<<255>>` does NOT: Erlang compares
  # binaries lexicographically and a shorter binary that is a PREFIX of a
  # longer one sorts LOWER, so `<<255>>` is smaller than any longer key
  # beginning with 0xFF. Defined here, above every use — as a module
  # attribute it is `nil` at any point textually before its definition,
  # and `nil` (an atom) sorts BELOW all binaries, which silently empties
  # the range instead of widening it.
  @max_key_binary :binary.copy(<<255>>, 64)
  @doc_commit_index_version 1
  @doc_commit_index_state_key {:doc_commit_index, :state}
  @doc_commit_index_ready {:ready, @doc_commit_index_version}
  @doc_commit_index_backfill_chunk 1_000

  # BUILD-1 §3: the accepted-head index backfill's resume/verified state.
  # `{:rebuilding, cursor}` (cursor = last-processed doc_uuid) survives a
  # kill; only a complete pass sets `{:ready, v}`, so a "corpus-verified"
  # read (§4's fallback removal) requires :ready — a half-run cannot present
  # as complete. Mirrors the doc_commit_index state shape.
  @accepted_head_index_version 1
  @accepted_head_index_state_key {:accepted_head_index, :state}
  @accepted_head_index_ready {:ready, @accepted_head_index_version}

  @moduledoc """
  The persistent storage layer for Commonplace's commit Merkle DAG —
  one singleton `GenServer` over a single CubDB instance at
  `<data_dir>/commits/`. Every observable change to every document in
  the workspace ends up here as a commit; nothing in the system
  reconstructs doc state without consulting this store.

  ## What's in the store

  CubDB is a single key/value space, partitioned by tuple-keyed
  namespaces:

      {:commit, commit_id}                  — the Commit struct itself.
      {:latest, doc_uuid}                   — pointer to the head commit
                                              on the local branch of
                                              `doc_uuid`'s DAG.
      {:merge_point, target, source}        — the source-side commit id
                                              that was last folded into
                                              `target` from `source`
                                              (incremental merge bound).
      {:last_merge_commit, target, source}  — the target-side commit id
                                              produced by that merge.
      {:latest_merge_head, target}          — most-recent target-side
                                              merge commit from *any*
                                              source. Used by red-channel
                                              audit / merge bookkeeping.
      {:attestation, attestation_id}        — gold-channel attestation
                                              records (CX-9rl).
      {:latest_attestation, doc_uuid}       — head of the attestation
                                              chain for `doc_uuid`.
      {:bd_issue_doc, doc_uuid}             — append-only CREATED intent
                                              for a bd issue document.
      {:bd_issue_doc_superseded, doc_uuid}  — append-only recorded correction
                                              for a backfill row that lacked
                                              an issue creation declaration.

  (Attestations are proof-of-authorship records on the **gold** color-
  channel — see `Commonplace.Dataflow.Channel` for the channel
  vocabulary. They live here because they must be durably bound
  alongside the commits they attest; `Commonplace.Gold.Chain` owns
  their API, CommitStore is only their durable tier.)

  Commits are append-only — `do_write_commit/6` and friends use
  `CubDB.put_multi/2` so the new `{:commit, id}` row and the
  `{:latest, doc_uuid}` advance land atomically. Commit-shaped rows
  (`{:commit, id}`, `{:attestation, id}`) are immutable once
  written; head pointers (`{:latest, _}`, `{:latest_attestation, _}`,
  `{:merge_point, _, _}`, `{:last_merge_commit, _, _}`,
  `{:latest_merge_head, _}`) are rewritten as the head advances.

  ## The `:latest` pointer

  `:latest` is the **local** head of a doc's DAG. It is per-node, not
  global. Two nodes in the same cluster can have different `:latest`
  for the same `doc_uuid` until catch-up sync runs; cross-node merging
  — reconciling two nodes' divergent `:latest` heads back into one — is
  a separate concern (see `Commonplace.Store.CrossEpochMerge`).

  **Every write of `:latest` goes through one private function,
  `put_latest/5` (CX-jfok, design §4 build-shape item 2 / §7 R1).** It
  writes the pointer and the caller's commit rows in one `put_multi`,
  then dispatches a post-advance invariant alarm. Adding a head-advance
  site means calling it; a direct `{:latest, _}` write anywhere in
  `apps/commonplace/lib` fails the source-scan test in
  `test/commonplace/store/invariant_choke_test.exs`. See that function's
  comment for why the surface is a choke rather than an enumerated list.

  Three operations touch `:latest`:

    1. **Local writes** (`create_commit`, `create_chained_commit`,
       `create_snapshot_commit`, `write_snapshot_cas`,
       `write_prebuilt_commit_cas`, `do_write_commit/6`) advance
       `:latest` to the new commit id, unconditionally for plain
       creates and conditionally for the CAS variants.
    2. **`set_latest/3`** — explicit re-point, used when a caller has
       already validated a commit and wants to install it as the new
       head (e.g. cross-epoch merge writes the merge commit, then
       calls `set_latest`).
    3. **`import_commit/3`** (catch-up sync, CX-bv3 / CX-ch5) —
       persists the commit row but **only** advances `:latest` when
       there is no existing `:latest` for that uuid. If a local
       `:latest` already exists, the imported commit is stored as a
       sibling (a divergent commit off a shared ancestor, kept but
       off the `:latest` linear walk) and `:latest` is left alone.
       This is what stops a remote catch-up burst from clobbering a
       newer local head.

  ## Chained vs imported writes

  These two paths exist because they serve different roles:

    * `create_commit/6` / `create_chained_commit/5` build a brand-new
      commit *here*. The commit is content-addressed at construction
      time (`Commit.new/4`), signed via the signing context (see
      "Signing" below), persisted, and `:latest` is moved to it.
      `create_chained_commit/5` reads the current `:latest` inside the
      same `handle_call` and uses it as `parent_id` — the read+write
      atomicity is the *whole point*; see CX-l7j below.
    * `import_commit/3` accepts a fully-formed `Commit{}` struct from
      a peer. The id is re-verified against the bytes via
      `Commit.verify_id/1` (CX-gwz — defends against a hostile peer
      retagging a delta as `kind: :snapshot` to skip history); the
      content is passed through a namespace validator (CX-ch5 — the
      default is `Namespace.validate_commit_from_db/2`, which checks
      the snapshot-parent chain for membership, rejecting a commit
      whose claimed lineage the node never authorized so a peer can't
      graft forged history onto a doc's namespace); on success the
      commit row is written and `:latest` is **only** advanced if the
      doc has no existing local head.

  Use `create_*` for local edits. Use `import_commit` for everything
  arriving over the wire — even if you're tempted to call
  `create_commit` because "the data's the same." Importing as a
  create clobbers a newer local `:latest` and silently orphans local
  work; see the CLAUDE.md note "use `import_commit` (not
  `create_commit`) when storing remote commits."

  ## Atomicity of `create_chained_commit/5` (CX-l7j)

  The "read latest, build a child off it, write the child" sequence
  must never let two concurrent writers both observe the same
  `:latest`, both produce children rooted at the same parent, and
  both write — the second writer's `:latest` bump would win and the
  first writer's commit, though persisted as a row, would be silently
  dropped from every linear walk that started at `:latest`.

  The ORIGINAL fix (pre-CX-3erd) bundled the whole read+build+sign+write
  sequence inside one `handle_call`, so the GenServer mailbox serialized
  concurrent writers per doc — correctness rested on nothing else
  running between the read and the write.

  CX-3erd hoists the CPU-heavy build+sign work OUT of that serialized
  section (see `Commonplace.Store.CommitBuilder` and
  `CommitStoreClient`'s local-mode `create_chained_commit/5`): the
  client now reads `:latest`, builds+signs the commit in its OWN
  process, and lands it via `put_built_commit/4`, a CAS'd verb. The
  trust structure changed, but the invariant didn't:

    * The caller-side read is **never** the source of correctness.
      CubDB supports concurrent readers via MVCC snapshots, so the
      read is safe to run outside the mailbox; it may simply be
      *stale* by the time the write reaches the store.
    * Correctness rests entirely on the CAS check that
      `put_built_commit/4` runs INSIDE the store's serialized
      `handle_call`, comparing `:latest` to the exact value the
      caller observed before it built. A stale read costs a retry
      (`{:error, :parent_moved}` — the client rebuilds against the
      fresh `:latest` and tries again, bounded, then falls back to
      the legacy serialized verb below), never a wrong write. This is
      the exact same structure `write_snapshot_cas/5` already had.
    * CX-l7j's invariant is therefore now **CAS-rejection** instead of
      **mailbox-bundling** — two racing writers can no longer both
      silently land children on the same parent; the loser is told
      so explicitly and retries.

  The two `{:create_commit, ...}` / `{:create_chained_commit, ...}`
  `handle_call` clauses below (via `do_write_commit/6`) are the
  RETAINED legacy serialized path — still real bundling, still
  correct — used by remote-mode callers (who have no local CubDB
  handle to read from) and as `CommitStoreClient`'s fallback once the
  bounded caller-side retry loop is exhausted (pathological, sustained
  contention only).

  Callers that don't need the "chain to current latest" semantics —
  e.g. snapshot construction that compares-and-swaps against an
  observed parent — use `write_snapshot_cas/5` or
  `write_prebuilt_commit_cas/2`, which encode the same atomicity
  with explicit CAS rejection (`{:error, :parent_moved}`) instead of
  silent re-anchoring. `put_built_commit/4` is a third member of this
  CAS family, differing only in what it CASes against (an
  independently-supplied `expected_parent_id` rather than
  `commit.parent_id`) and in optionally landing a genesis row
  alongside.

  `import_commit/3` needs no such bundling. It doesn't derive a parent
  from a `:latest` read — the commit arrives with its `parent_id`
  already fixed — so there's no read-then-write window for two writers
  to race over. Its only `:latest` interaction is the conditional
  advance, itself serialized by the GenServer mailbox.

  ## Snapshots and the umbrella metadata (CX-6sc, CX-bgy, CX-u7p)

  Three layers of "snapshot" exist:

    1. `create_snapshot_commit/4` — primitive that chains a
       caller-supplied snapshot payload onto the current `:latest`
       and tags `kind: :snapshot`. Readers that know snapshots
       (notably `DocBuilder.reconstruct_doc/2`) short-circuit the
       backward walk on hitting one.
    2. `snapshot/2` — convenience that reconstructs the doc,
       generates a deterministic snapshot via
       `Snapshotter.build_snapshot/3`, and calls
       `create_snapshot_commit`. The deterministic-anyone property —
       `Snapshotter` is built to emit byte-identical output for the
       same parent state — means two nodes snapshotting the same
       parent produce byte-identical `update`s and `derivation_map`s,
       so *anyone* can mint the canonical snapshot.
    3. `write_snapshot_cas/5` — atomic CAS variant of #1. The caller
       (typically `Snapshotter`) has already built the payload and
       commits it iff `:latest` still equals `expected_parent_id`.
       Two callers that observed the same parent produce the same
       commit id (CX-umz deterministic-anyone) and the second write
       collapses to a no-op.

  The "umbrella" snapshot metadata (`snapshot_parents`,
  `derivation_map`, `snapshotter_version`) is built by `Snapshotter`
  and passed through verbatim. CommitStore stamps `kind: :snapshot`
  itself so callers cannot forget it.

  ## Genesis stamping (CX-fzi, CX-m3x, CX-a04)

  Every `:regular` commit needs a parent — either an earlier commit
  on the same DAG or the doc's deterministic genesis. Two pieces of
  back-fill machinery handle this:

    * `ensure_genesis/2` is the explicit primitive — `Commit.genesis/1`
      is a pure function of the uuid, so calling it twice returns the
      same struct and stores to the same id. `:latest` is **not**
      touched; this is just "make sure the genesis commit row exists."
    * `CommitBuilder.resolve_genesis/3` (private, CX-3erd — formerly
      this module's own `maybe_stamp_genesis/3`) — when a caller
      passes `parent_id = nil` for a uuid that has no `:latest`,
      resolve the genesis id and use it as the parent. Pre-umbrella
      docs that already have a `:latest` keep the nil parent (legacy
      hatch — empty metadata, no `:kind`): back-filling a genesis
      ancestor beneath already-written history would change those
      commits' parent chains and ids, so the hatch deliberately leaves
      pre-umbrella docs untouched. Unlike `ensure_genesis/2`, this
      variant does not write the genesis row itself (it can't — it
      may run in the caller's process, see CX-3erd below); the row
      rides along with whichever put lands the commit.
    * `CommitBuilder.stamp_snapshot_parent/3` (private, CX-a04,
      formerly this module's own `maybe_stamp_snapshot_parent/3`) —
      `:regular` commits inherit `snapshot_parent` from the parent's
      `Namespace.current_namespace/1` unless the caller set one
      explicitly. Non-`:regular` and legacy-empty metadata are
      left untouched.

  Both now live in `Commonplace.Store.CommitBuilder` (CX-3erd) so the
  server-serialized path (`do_write_commit/6`) and the caller-side
  hoisted path (`CommitStoreClient`'s local-mode `create_commit` /
  `create_chained_commit`) run the EXACT SAME implementation — there
  is exactly one place genesis/snapshot_parent stamping semantics can
  be defined, so the two paths can never silently diverge.

  ## PubSub broadcast contract (CX-4im)

  Every successful write fans out on **two** Phoenix.PubSub topics:

      "commits:<doc_uuid>"   {:commit, doc_uuid, commit.id, metadata}
      "blue:<doc_uuid>"      {:commit, doc_uuid, commit.id, metadata}

  Both topics carry the same message shape. The duality is a
  known wart documented in CX-4im — `commits:` is the historical
  storage-layer topic, `blue:` is the color-channel topic that
  `Tree.DocCache`, `WikiLive`, `TreeLive`, and other UI subscribers
  hang off of. Until they're unified, the write path emits both so
  that CommandRouter-initiated writes (MCP, CLI) reach UI subscribers
  the same way Document.Server edits do.

  Broadcast happens **after** the CubDB write returns. There is no
  rollback on PubSub failure — a subscriber that crashed will miss
  the event, and the durable record is the row in CubDB, not the
  broadcast.

  The CAS variants emit the same pair. `import_commit/3` deliberately
  does *not* broadcast — catch-up sync produces large bursts of
  commits and the historical subscribers (UI live views, DocCache)
  would re-reconstruct on every one. The catch-up path uses its own
  end-of-burst signal instead.

  Telemetry emits in parallel with PubSub:

      [:commonplace, :commit, :create]                        (writes)
      [:commonplace, :commit, :latest_read]                   (reads, CX-o8tx)
      [:commonplace, :commit, :rejected, :id_mismatch]        (CX-gwz)
      [:commonplace, :commit, :rejected, :namespace_mismatch] (CX-ch5)
      [:commonplace, :commit, :rejected, :unknown_reference]  (CX-fbs6)

  R4c rung-0 write-path instrumentation (CX-9hql) adds three more,
  documented in full in `Commonplace.Telemetry`'s moduledoc:

      [:commonplace, :commit_store, :call]         (per WRITE-verb handle_call)
      [:commonplace, :commit_store, :write_cpu]     (CPU breakdown: build/sign/validate/persist)
      [:commonplace, :commit_store, :queue_depth]   (periodic mailbox-depth poll)

  `:latest_read` exists so the reflog amortization tests
  (`Reflog.Snapshot`, CX-o8tx) can prove that clean subtrees were
  short-circuited without a read. Production cost is negligible
  when no handler is attached.

  ## Signing (CX-hoj, CX-o3r7)

  Commit signing is opt-in and per-write. `CommitBuilder.build/6` (CX-3erd
  — the single build pipeline shared by `do_write_commit/6` and the
  caller-side hoisted path) calls `CommitBuilder.maybe_sign_commit/2`
  with the `:signing_context` option:

    * `%Commonplace.Crypto.SigningContext{}` — sign with the
      supplied identity + private key. MCP-bound sessions use this
      so commits attest to the agent's identity rather than the
      human's default key.
    * `:unsigned` — explicitly skip signing even when a global key
      is configured. MCP-MVP agent commits use this to avoid
      inheriting the human's identity.
    * `nil` (default) — fall back to the global
      `Commonplace.Store.SecretStore` key. If the SecretStore
      isn't running or has no key, the commit is unsigned.
      Preserved as legacy behavior for callers that haven't been
      updated.

  The CAS write paths (`write_snapshot_cas/5`,
  `write_prebuilt_commit_cas/2`) do **not** wire signing-context
  forwarding — snapshot construction happens above this layer and
  prebuilt commits are already assembled by the caller. This is a
  layering choice, not an idempotency constraint: signatures sit
  *outside* the content address (they never change a commit id), so
  the omission is only about where the signing context is threaded,
  not about keeping deterministic-anyone writes byte-identical. Signed
  callers route through `create_commit` / `create_chained_commit`.

  ## CommitStoreClient access discipline

  Callers should route through `Commonplace.Store.CommitStoreClient`,
  not call CommitStore directly. The client is a thin dispatcher that
  routes to either the local GenServer or a remote `serve` node
  depending on whether the CLI is running standalone or against a
  long-lived BEAM. Direct `CommitStore.foo/n` calls work when the
  process is local but silently break the "talk to serve" mode that
  the CLI uses to share a single CubDB across invocations.

  Tests can pass a custom server pid; the client normalizes its
  `server` argument so the CLI alias resolves to the real
  CommitStore but explicit pids pass through.

  ## Single-opener exclusion (`<data_dir>/commits.lock`, CX-2479)

  Before `init/1` opens CubDB at all it takes a **non-blocking exclusive
  `flock(2)`** on `<data_dir>/commits.lock` via `Commonplace.Flock`.
  If another live process holds it, `init/1` returns
  `{:stop, {:commits_store_locked, detail}}` — it does not open, does not
  probe, does not archive, does not touch a byte on disk.

  **The exclusion is the flock. The file's CONTENT is a hint, not a
  claim.** We write our OS pid and node name into the lock file purely so
  a human reading a refusal has somewhere to start; nothing reads it to
  decide whether to proceed, and a stale pid in it grants nobody
  anything. (The pre-CX-2479 arrangement was exactly the opposite: a pid
  string a second process overwrote before proceeding. That is how two
  appenders landed on one CubDB file. `Commonplace.CLI.acquire_db_lock/1`
  was a second, unrelated copy of that scheme over this same file; CX-x8jk
  deleted it, and the CLI now refuses or routes before it ever reaches a
  direct open — see `Commonplace.CLI.Access`.)

  The lock file sits in `data_dir`, deliberately **outside** the
  `commits/` directory that crash recovery renames, so one continuous
  hold spans archive-and-restart. See `acquire_commits_lock/1`.

  Release is by fd close: `terminate/2` unlocks best-effort, and the
  kernel releases on process death regardless (the fd lives in a NIF
  resource on this process's heap). Measured: reacquire after
  `Process.exit(pid, :kill)` succeeds in 0ms, so an immediate supervisor
  restart never deadlocks against its dead predecessor. There is
  deliberately **no takeover path** — a takeover is how a live holder
  gets evicted and the corruption returns.

  ## CubDB crash recovery (`init/1`)

  CubDB occasionally fails to open after an unclean shutdown. Rather
  than crash the whole supervision tree on boot — which would brick
  the workspace — `init/1` probes the database with a full key scan
  (CX-xrds: deepened from the original take-1 probe, which only
  touched a single entry and could miss corruption located later in
  the file), and on failure archives the corrupt dir to
  `<path>.corrupt.<unix-ts>` and starts fresh. This is **lossy** by
  design: a corrupt commits/ DB cannot be recovered in-process, and
  the alternative is an unbootable workspace. The
  `<path>.corrupt.<ts>` directory is preserved on disk for
  out-of-band recovery — see `salvage_corrupt_archive/2` below.

  **CX-pm68: archive-and-fresh is gated on prior-world evidence.** The
  paragraph above describes what happens on a dir with no history. If
  `<data_dir>/root` exists — a world was here — `init/1` instead returns
  `{:stop, {:refusing_fresh_reinit, detail}}`, archives nothing, and
  changes nothing on disk. Silently serving an empty store in that
  situation is how an enforce-mode serve ended up on a fresh world writing
  genesis docs: the substrate could not tell empty-because-broke from
  empty-because-new, so it kept going. Recovery is a human decision
  (truncate-to-last-valid-header, or `salvage_corrupt_archive/2`). The
  deliberate fresh start is available but is a recorded act:
  `COMMONPLACE_ACCEPT_FRESH_REINIT=1` / `:accept_fresh_reinit`, which
  proceeds AND writes a `{:fresh_reinit_fact, <iso8601>}` row into the
  fresh store naming the archived predecessor. See
  `prior_world_evidence?/1` for why the root pointer is the evidence and
  not anything inside `commits/`.

  The scan is bounded by **time, not count**: it runs in a supervised
  `Task` capped at `Application.get_env(:commonplace,
  :corruption_probe_timeout_ms, 5_000)` milliseconds. A raise during
  the scan means real corruption → archive-and-recover. A timeout
  means the store is just large — availability wins over paranoia, so
  a timeout is logged as a partial scan, including its lower-bound entry
  count and the fact that its covered fraction is unknown, and treated as
  HEALTHY rather than triggering a lossy rename of a store that may be
  perfectly fine. Completed scans log their entry count too, making
  declining coverage visible across restarts. This keeps `init/1`'s
  boot-time cost bounded regardless of store size while still catching
  corruption anywhere in a store that scans within the timeout.

  Recovery granularity stays **whole-store**: `init/1` never attempts
  per-key quarantine of a corrupt CubDB (a materially bigger design —
  CubDB offers no supported way to skip past a damaged region mid-scan
  and keep using the same handle). What CX-xrds adds instead is
  `salvage_corrupt_archive/2`, an out-of-band tool that opens an
  archived `.corrupt.<ts>` directory **read-only in a separate
  process**, walks whatever entries are still readable (rescuing
  per-entry so one bad record doesn't abort the walk), and
  re-imports each recovered commit into a live store via the normal
  `import_commit/3` front door — content-addressed, so re-importing
  an already-present commit is a safe no-op and Gate A/B validation
  still applies to every salvaged commit.

  The `open_cubdb/1` helper traps exits while starting CubDB so an
  init crash in CubDB itself doesn't take the GenServer down before
  the recovery branch runs. Any pending `:EXIT` message from a
  failed CubDB process is drained before the trap is restored.

  ## Merge bookkeeping

  Four keys track merge state per `(target, source)` pair:

    * `:merge_point` — the source-side commit id last folded in.
      Used by `Tree.Merge` to find the lower bound for an
      incremental three-way merge so re-merges skip already-folded
      commits.
    * `:last_merge_commit` — the target-side commit produced by
      that merge. Forms the upper bound used by audit / reflog.
    * `:latest_merge_head` — the same target-side id, but keyed by
      target alone. Answers "was this target ever merged from
      anywhere?" without iterating all sources.
    * Storage is direct K/V — no DAG walking required for these
      bookkeeping reads.

  ## Worked example

  A local edit, the orphan its split predecessor used to cause, and a
  clobber-safe import — for doc A whose `:latest` starts at `c1`:

      # 1. Local chained write.
      create_chained_commit(A, update, ...)
      #   reads :latest (c1) and writes child c2 INSIDE one handle_call,
      #   advances :latest -> c2, broadcasts on commits:A and blue:A.
      #   Because read+write share one mailbox slot, a second concurrent
      #   writer can't also read c1 and root a child there (CX-l7j) — it
      #   observes c2 and chains off it instead of orphaning c2.

      # 2. CAS snapshot — two nodes both observed parent c2.
      write_snapshot_cas(A, payload, expected_parent_id: c2)
      #   first writer: :latest still c2 -> writes snapshot s1, :latest -> s1.
      #   second writer: :latest now s1 (!= c2) -> {:error, :parent_moved},
      #   a clean no-op. Both nodes computed the same s1 id anyway
      #   (deterministic-anyone), so nothing is lost.

      # 3. Import a peer's sibling — clobber-protected.
      import_commit(%Commit{id: c3, parent_id: c1, ...})
      #   verify_id passes, namespace validator passes; c3 row is stored.
      #   A already has a local :latest (s1), so :latest is LEFT at s1
      #   and c3 is kept as a divergent sibling off c1 — newer local work
      #   is never silently replaced. A later Tree.Merge reconciles them.

  ## Invariants

    * Commits are immutable. `{:commit, id}` rows are never
      overwritten with new content (idempotent re-puts of the same
      bytes are fine).
    * `:latest` always points at a stored commit. Concurrent
      writers per doc are serialized through the GenServer mailbox.
    * Imported commits never clobber a present local `:latest`.
    * Every successful local write broadcasts on both
      `commits:<uuid>` and `blue:<uuid>`.
    * Every successful local write emits
      `[:commonplace, :commit, :create]` telemetry.
    * `verify_id/1` runs before any `import_commit` is trusted.

  ## What this module is NOT

    * **Not the CRDT layer.** Yelixer owns CRDT semantics; this
      module only stores opaque update bytes.
    * **Not the read path.** Reconstruction lives in
      `Tree.DocBuilder` (and cached results in `Tree.DocCache`);
      this module returns raw commits.
    * **Not the namespace validator.** That logic lives in
      `Commonplace.Store.Namespace`; CommitStore just wires it into
      `import_commit/3`.
    * **Not the merge engine.** `Tree.Merge` and
      `Store.CrossEpochMerge` compute merge updates; CommitStore
      stores their output.
    * **Not the signing engine.** `Commonplace.Crypto.Signing` does
      the actual signing; CommitStore decides *whether* to invoke
      it based on the per-call context.
    * **Not the remote transport.** `CommitStoreClient` handles
      local-vs-remote routing.
    * **Not the attestation API.** `Commonplace.Gold.Chain` owns the
      gold-channel attestation surface and calls into CommitStore's
      `{:store_attestation, ...}` / `{:latest_attestation, ...}` /
      `{:attestation_chain, ...}` handle_calls directly via
      `GenServer.call/2`. There are deliberately no public wrappers
      here — attestation verbs live with their owner; CommitStore is
      just the durable tier.

  ## Cross-version handle_call shapes

  Two pairs of `handle_call` clauses match arity-shorter tuples
  that no current public function emits:

      {:create_commit, doc_uuid, update, parent_id, metadata}
      {:create_chained_commit, doc_uuid, update, metadata}

  These exist for cross-version `GenServer.call/2` from older
  client builds (notably CLI escripts pinned to a pre-CX-o3r7
  release) connecting to a newer `serve` node. New clients always
  send the longer tuple with the trailing `opts` keyword list; old
  clients send the shorter shape and the handler delegates to the
  full path with `opts = []`. Drop these only after a release
  audit confirms no in-flight escripts still emit the short form.
  """

  use GenServer
  require Logger

  alias Commonplace.Store.{Commit, CommitBuilder}
  alias Commonplace.Trust.CodeDocHeuristic

  # Shared ceiling for commit_log walks (CX-klpi). Callers that hit
  # exactly this many results should treat the log as possibly-truncated
  # — the walk stopped because it hit the cap, not because it reached
  # the genesis commit.
  @max_commit_log_limit 10_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Persist a commit at a caller-supplied `parent_id` and advance
  `:latest` to it.

  The lowest-level write entry point — callers that already know
  exactly which commit they want to chain off use this. For the
  "chain off whatever is currently latest" semantics that virtually
  all local edits want, use `create_chained_commit/5` so the
  read+write is atomic (CX-l7j).

  `parent_id = nil` on a doc that has no prior `:latest` triggers
  deterministic-genesis stamping (CX-m3x): the genesis commit row
  is materialized and used as the parent. Pre-umbrella docs that
  already have a `:latest` retain legacy behavior — the nil parent
  is preserved.

  `opts[:signing_context]` selects the signing identity for this
  commit; see the module-level "Signing" section. `opts[:writer]` accepts
  `{module, function}` for local-write denial attribution. It is carried
  only into a refusal record and is never inferred from `doc_uuid`.
  """
  def create_commit(
        server \\ __MODULE__,
        doc_uuid,
        update,
        parent_id,
        metadata \\ %{},
        opts \\ []
      ) do
    GenServer.call(
      server,
      {:create_commit, doc_uuid, update, parent_id, metadata, opts}
    )
  end

  @doc """
  Create a commit that automatically chains to the latest commit on
  this UUID.

  CX-l7j: the read-latest + write-commit pair is atomicized inside a
  single `handle_call` so the GenServer mailbox serializes concurrent
  writers per-UUID. A prior split across two GenServer calls let two
  callers read the same `:latest`, both write chained to the same
  parent, and produce siblings — the second write's `:latest` bump won
  and the first was silently orphaned from linear walks.

  `opts[:writer]` has the same denial-attribution contract as
  `create_commit/6`.
  """
  def create_chained_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}, opts \\ []) do
    GenServer.call(server, {:create_chained_commit, doc_uuid, update, metadata, opts})
  end

  @doc """
  Create a snapshot commit (CX-u7p compaction primitive).

  Chains normally to the latest commit so replication walks back through
  history as usual, but tags the commit metadata with `kind: :snapshot`.
  Readers that know about snapshots (see `DocBuilder.reconstruct_doc/2`)
  short-circuit the backward walk on hitting one and apply only the
  snapshot plus any newer commits chained on top.

  The snapshot's `update` payload should be a self-contained Yjs update
  encoding the full materialized observable state under a single
  client_id (see `Yelixer.Doc.snapshot_update/1`). Applied to a fresh
  `Doc.new()`, it must reproduce the source doc's observable content.
  """
  def create_snapshot_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}) do
    metadata = Map.put(metadata, :kind, :snapshot)

    parent_id =
      case latest_commit(server, doc_uuid) do
        {:ok, commit} -> commit.id
        :none -> nil
      end

    create_commit(server, doc_uuid, update, parent_id, metadata)
  end

  @doc """
  Create an umbrella-shaped snapshot commit for `doc_uuid` (CX-6sc /
  CX-bgy build 5).

  Reconstructs the doc from its current `:latest`, emits a deterministic
  snapshot via `Yelixer.Doc.snapshot_update/1`, and tags the commit
  with the full umbrella metadata:

      %{kind: :snapshot,
        snapshot_parents: [namespace(parent)],
        derivation_map: %{source_snapshot_hash => %{new_id => old_id}},
        snapshotter_version: N}

  `namespace(parent)` is `Namespace.current_namespace(parent_commit)`
  — for a `:regular` parent this is the inherited `snapshot_parent`;
  for a `:genesis` or `:snapshot` parent it's the parent's own id.

  The MVP triggers on explicit caller invocation only — there is no
  automatic cadence. Two independent nodes snapshotting the same
  parent produce the same `update` bytes and the same `derivation_map`
  contents (deterministic-anyone property — see tests).

  Returns `{:ok, snapshot_commit}`, `{:error, :not_found}` if the doc has
  no `:latest` commit, or `{:error, {:nested_subtypes, names}}` if the doc
  carries CRDT sub-types nested inside maps/arrays that cannot be snapshotted
  without data loss (R5 guard, CX-tdkq.5 — refusing keeps the full chain).
  """
  def snapshot(server \\ __MODULE__, doc_uuid) do
    case latest_commit(server, doc_uuid) do
      :none ->
        {:error, :not_found}

      {:ok, parent} ->
        case Commonplace.Store.Snapshotter.build_snapshot(server, doc_uuid, parent) do
          {:ok, update_bytes, metadata} ->
            commit = create_snapshot_commit(server, doc_uuid, update_bytes, metadata)
            {:ok, commit}

          {:error, {:nested_subtypes, _names}} = error ->
            error
        end
    end
  end

  @doc """
  Atomically write a snapshot commit to `doc_uuid` iff the current
  `:latest` equals `expected_parent_id` (CX-4e2g).

  The compare-and-swap is performed inside the GenServer handle_call,
  so concurrent callers that observed the same parent produce the
  same commit id (deterministic-anyone, CX-umz) and collapse to a
  single write; callers whose observed parent has since been
  superseded receive `{:error, :parent_moved}` and can treat the
  operation as a no-op.

  The caller is responsible for computing `update` + `metadata` (via
  `Snapshotter.build_snapshot/3`). The `:kind => :snapshot` tag is
  stamped here so callers cannot forget it.
  """
  @spec write_snapshot_cas(GenServer.server(), String.t(), binary(), map(), binary()) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def write_snapshot_cas(server \\ __MODULE__, doc_uuid, update, metadata, expected_parent_id) do
    GenServer.call(
      server,
      {:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id}
    )
  end

  @doc """
  Atomically persist a pre-built commit and advance `:latest` iff the
  current `:latest` for the commit's doc still matches `commit.parent_id`
  (CX-4qn1).

  Unlike `write_snapshot_cas/5`, the commit struct is already fully
  assembled by the caller — the caller is expected to have derived it
  from `Merger.merge/4` (or another byte-deterministic builder) so its
  content-addressed id is already bound to its parent. Two callers that
  observed the same `:latest` and merged against the same counterpart
  will produce the same commit id; the CAS makes the second writer a
  no-op. Callers whose `:latest` observation is stale get
  `{:error, :parent_moved}`.

  Idempotent for same-id re-writes: CubDB's `put_multi` collapses
  duplicates, and `:latest` is re-pointed to the same id.
  """
  @spec write_prebuilt_commit_cas(GenServer.server(), Commit.t()) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def write_prebuilt_commit_cas(server \\ __MODULE__, %Commit{} = commit) do
    GenServer.call(server, {:write_prebuilt_commit_cas, commit})
  end

  @doc """
  Atomically persist a caller-BUILT commit — the CX-3erd hoisted write
  path's landing verb.

  Unlike `write_prebuilt_commit_cas/2` (whose CAS compares `:latest` to
  `commit.parent_id`), the CAS here compares `:latest` to the
  independently-supplied `expected_parent_id` — the value the caller
  observed `:latest` to be *before* it ran `CommitBuilder.build/6`
  (`nil` means "expect no `:latest` yet"). This is what lets
  `create_commit`'s explicit-parent writes (whose `commit.parent_id`
  may be an arbitrary caller-supplied id, not derived from `:latest` at
  all) share this same landing verb as `create_chained_commit`'s
  observed-latest writes: both pass whatever they read `:latest` as
  right before building, and CAS-fail only if that specific observation
  went stale.

  When `genesis` is non-nil (the caller's build newly resolved a
  genesis parent — see `CommitBuilder.resolve_genesis/3`), it rides the
  SAME `put_multi` as the commit + `:latest` rows, so genesis and the
  first real commit land atomically together. Two concurrent
  first-writers on a fresh doc both compute the same genesis id
  (`Commit.genesis/1` is pure); the loser's CAS fails and it retries
  chained onto the winner instead of double-writing genesis (idempotent
  either way — `put_multi` collapses same-bytes duplicates).

  Returns `{:ok, commit}` on a successful land, `{:error, :parent_moved}`
  on CAS mismatch (nothing written).
  """
  @spec put_built_commit(GenServer.server(), Commit.t(), binary() | nil, Commit.t() | nil) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def put_built_commit(
        server \\ __MODULE__,
        %Commit{} = commit,
        expected_parent_id,
        genesis \\ nil
      ) do
    GenServer.call(server, {:put_built_commit, commit, expected_parent_id, genesis})
  end

  @doc false
  def put_built_commit(server, %Commit{} = commit, expected_parent_id, genesis, opts)
      when is_list(opts) do
    GenServer.call(server, {:put_built_commit, commit, expected_parent_id, genesis, opts})
  end

  @doc """
  Deadline-aware landing for the CX-gc7q ticket-create chain.

  The caller supplies both the absolute monotonic deadline carried from
  the MCP boundary and the remaining-time call timeout derived immediately
  before this seam. The absolute value also rides in the request so queued
  work can refuse without persisting after the caller's wait expires.
  """
  @spec put_built_commit(
          GenServer.server(),
          Commit.t(),
          binary() | nil,
          Commit.t() | nil,
          integer(),
          pos_integer()
        ) :: {:ok, Commit.t()} | {:error, :parent_moved | :deadline_expired}
  def put_built_commit(
        server,
        %Commit{} = commit,
        expected_parent_id,
        genesis,
        deadline,
        timeout
      )
      when is_integer(deadline) and is_integer(timeout) and timeout > 0 do
    GenServer.call(
      server,
      {:put_built_commit, commit, expected_parent_id, genesis, deadline},
      timeout
    )
  end

  @doc false
  def put_built_commit(
        server,
        %Commit{} = commit,
        expected_parent_id,
        genesis,
        opts,
        deadline,
        timeout
      )
      when is_list(opts) and is_integer(deadline) and is_integer(timeout) and timeout > 0 do
    GenServer.call(
      server,
      {:put_built_commit, commit, expected_parent_id, genesis, opts, deadline},
      timeout
    )
  end

  @doc """
  Expose the live CubDB handle for `server` (wraps `resolve_db/1`).

  Public so `Commonplace.Store.CommitStoreClient`'s CX-3erd caller-side
  build path can run `CommitBuilder.build/6`'s point-reads (genesis /
  `:latest` / `snapshot_parent` lookups) in the CALLING process, exactly
  like the R4(a) read helpers (`get_commit/2`, `latest_commit/2`, etc.)
  already do — never a `GenServer.call` into this store's own mailbox.
  Only writes need the serialized section; `db_handle/1` hands out
  nothing but read access to CubDB, which supports concurrent readers
  safely (MVCC snapshots).
  """
  @spec db_handle(GenServer.server()) :: CubDB.t()
  def db_handle(server \\ __MODULE__), do: resolve_db(server)

  @doc """
  Return the `Commonplace.Store.TrustSideStore` name/pid registered as this
  CommitStore instance's companion (R4c carve-out). Defaults to the bare
  module name when the instance was started without an explicit
  `:trust_side_store` opt (e.g. a bare `CommitStore.start_link/1` in a test
  that never touches capability/execute_clean behavior). Resolved via
  `persistent_term`, same pattern as `resolve_db/1`, so it's a cheap
  same-process read for callers (notably `CommitStoreClient`) that need to
  address the correct companion instance in a multi-trio test suite.
  """
  @spec trust_side_store_name(GenServer.server()) :: GenServer.server()
  def trust_side_store_name(server \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, :trust_side_store, server}, nil) do
      nil -> GenServer.call(server, :get_trust_side_store)
      name -> name
    end
  end

  @doc """
  Return the `Commonplace.Store.PendingImports` name/pid registered as this
  CommitStore instance's companion (R4c carve-out). See
  `trust_side_store_name/1` for the resolution pattern.
  """
  @spec pending_imports_name(GenServer.server()) :: GenServer.server()
  def pending_imports_name(server \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, :pending_imports, server}, nil) do
      nil -> GenServer.call(server, :get_pending_imports)
      name -> name
    end
  end

  @doc """
  Return a MapSet of every commit id persisted for `doc_uuid`, including
  commits that are NOT reachable from `:latest` (i.e. siblings imported
  via `import_commit/2` that have no descendant on the local head's
  chain). Unlike `commit_ids_for_doc/2`, this scans the commit index
  rather than walking backward from `:latest`, so it finds siblings
  that were imported but never merged in.
  """
  @spec all_commit_ids_for_doc(GenServer.server(), String.t()) :: MapSet.t()
  def all_commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
    do_all_commit_ids_for_doc(resolve_db(server), doc_uuid)
  end

  @doc """
  Authoritative membership: does `doc_uuid` own `commit_id`? An O(1)
  point-read on the `{:doc_commit, doc_uuid, commit_id}` index row — the
  same authoritative doc→commit map `all_commit_ids_for_doc/2` reduces,
  read for one id instead of a range.

  ⭐ Ownership is decided by the index KEY, never by a commit struct's
  `.doc_uuid` field (a debug trace of the first writer, excluded from the
  content address and stale after forks / shared across convergent-genesis
  or imported ids — `commit.ex`). A commit can be indexed under a doc whose
  uuid its struct does not name; this answers by possession, which is what
  `CommitReader.at/3`'s cell scoping rests on.

  Fails loud when the index is not ready — no silent `false`, which a caller
  cannot distinguish from a genuine absence (same discipline as
  `do_all_commit_ids_for_doc/2`'s refusal to full-scan a half-built index).
  """
  @spec doc_has_commit?(GenServer.server(), String.t(), binary()) :: boolean()
  def doc_has_commit?(server \\ __MODULE__, doc_uuid, commit_id) do
    do_doc_has_commit?(resolve_db(server), doc_uuid, commit_id)
  end

  @doc """
  The doc's accepted-head set from the durable index — the incrementally
  maintained equivalent of `Commonplace.Store.AcceptedHeads.of/2`'s scan.

  Returns `{:ok, MapSet.t(commit_id)}` (the non-dominated frontier,
  including `:latest`) or `:none` when the doc has no commits. The index
  is maintained forward through the head-update seam (`put_latest/5` for
  advances, `put_bare_commit_with_index/2` for genesis and sibling
  imports); legacy documents written before the seam existed are filled
  by the increment-3 backfill and until then may report an incomplete set
  here. A point-read, no DAG walk.
  """
  @spec accepted_heads_indexed(GenServer.server(), String.t()) :: {:ok, MapSet.t()} | :none
  def accepted_heads_indexed(server \\ __MODULE__, doc_uuid) do
    do_accepted_heads_indexed(resolve_db(server), doc_uuid)
  end

  defp do_accepted_heads_indexed(db, doc_uuid) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      _latest -> {:ok, CubDB.get(db, {:accepted_heads, doc_uuid}) || MapSet.new()}
    end
  end

  @doc """
  BUILD-1 §3 backfill: write one chunk of derived full head-sets and
  advance the resume state, ATOMICALLY (rows + state in one put_multi, so a
  kill cannot leave rows written past the recorded cursor).

  `rows` :: `[{doc_uuid, MapSet.t()}]` (each an already-derived, verified
  frontier); `state` :: `{:rebuilding, cursor}` (cursor = last doc_uuid in
  this chunk) or `:ready` for the final chunk. The write goes through the
  choke-sanctioned `accepted_heads_backfill_row/2`.
  """
  @spec put_backfilled_accepted_heads(GenServer.server(), [{String.t(), MapSet.t()}], term()) ::
          :ok
  def put_backfilled_accepted_heads(server \\ __MODULE__, rows, state) do
    GenServer.call(server, {:put_backfilled_accepted_heads, rows, state})
  end

  @doc """
  The accepted-head-index backfill state: `{:ready, v}` once a complete
  pass finished, `{:rebuilding, cursor}` mid-run, or `:absent` if never run.
  §4 removes SiblingMerger's scan-fallback only when this reads `{:ready, v}`
  — a half-run (incl. a kill) never presents as complete.
  """
  @spec accepted_head_backfill_state(GenServer.server()) :: term()
  def accepted_head_backfill_state(server \\ __MODULE__) do
    CubDB.get(resolve_db(server), @accepted_head_index_state_key) || :absent
  end

  @doc "The `{:ready, v}` value that marks the backfill complete for this version."
  @spec accepted_head_index_ready() :: term()
  def accepted_head_index_ready, do: @accepted_head_index_ready

  @doc """
  Fork-lineage `{:doc_commit}` backfill (the "(a) round",
  `docs/plans/2026-08-21-doc-commit-backfill-brief.md`): write the missing
  membership rows for ONE doc, atomically (one `put_multi`).

  Every row is `{:doc_commit, doc_uuid, commit_id} => true` for the given
  `doc_uuid` — the caller derives `commit_ids` from a chain walk; this verb
  only writes membership facts. The index is many-to-many by design, so
  dual membership (ancestor doc AND forked doc) is coherent, not a new
  state.

  Refuses unless the index state reads ready (`{:error,
  {:doc_commit_index_not_ready, state}}`): backfilling into a half-built
  index would be repaired-then-erased by the in-flight rebuild. The state
  key itself is NEVER written here — readiness is the boot rebuild's to
  flip, exclusively.
  """
  @spec put_backfilled_doc_commit_index_rows(GenServer.server(), String.t(), [binary()]) ::
          :ok | {:error, {:doc_commit_index_not_ready, term()}}
  def put_backfilled_doc_commit_index_rows(server \\ __MODULE__, doc_uuid, commit_ids)
      when is_binary(doc_uuid) and is_list(commit_ids) do
    # Explicit finite timeout, generous for the chunked writes the caller
    # sends (≤ @put_chunk rows/call): pass 2 of the live (a) run died on
    # the DEFAULT 5s here when a >10k-row chain arrived as one call. A
    # big margin over a small chunk, still finite so a wedged server
    # fails loud instead of hanging a migration forever.
    GenServer.call(server, {:put_backfilled_doc_commit_index_rows, doc_uuid, commit_ids}, 60_000)
  end

  @doc """
  Look up a single commit by id. Returns `{:ok, commit}` or `:none`.
  Does not walk the DAG and does not consult `:latest` — pure
  point-read on the `{:commit, id}` row.
  """
  def get_commit(server \\ __MODULE__, commit_id) do
    do_get_commit(resolve_db(server), commit_id)
  end

  @doc "Persist a verified, immutable SLA tombstone receipt; never removes commit rows."
  def store_sla_tombstone(%Commonplace.Store.SlaTombstone{} = tombstone) do
    store_sla_tombstone(__MODULE__, tombstone)
  end

  def store_sla_tombstone(server, %Commonplace.Store.SlaTombstone{} = tombstone) do
    GenServer.call(server, {:store_sla_tombstone, tombstone})
  end

  @doc "Read the store-assigned eviction-authority position for a tombstone."
  def get_sla_tombstone_position(server \\ __MODULE__, tombstone_id) do
    Commonplace.Store.EvictionAuthorityLedger.tombstone_position(
      resolve_db(server),
      tombstone_id
    )
  end

  @doc "Read the store-assigned activation position for an eviction anchor."
  def get_eviction_anchor_activation_position(server \\ __MODULE__, anchor_id) do
    Commonplace.Store.EvictionAuthorityLedger.activation_position(resolve_db(server), anchor_id)
  end

  @doc "Activate a configured eviction anchor, citing the ratification CID."
  def activate_eviction_anchor(server \\ __MODULE__, anchor_id, ratification_cid) do
    GenServer.call(server, {:activate_eviction_anchor, anchor_id, ratification_cid})
  end

  @doc "Read an eviction anchor's ratification-citing activation event."
  def get_eviction_anchor_activation(server \\ __MODULE__, anchor_id) do
    Commonplace.Store.EvictionAuthorityLedger.activation(resolve_db(server), anchor_id)
  end

  @doc "Read the store-assigned retirement position for an eviction anchor."
  def get_eviction_anchor_retirement_position(server \\ __MODULE__, anchor_id) do
    Commonplace.Store.EvictionAuthorityLedger.retirement_position(resolve_db(server), anchor_id)
  end

  @doc "Retire a configured eviction anchor at the next store-assigned ledger position."
  def retire_eviction_anchor(server \\ __MODULE__, anchor_id) when is_binary(anchor_id) do
    GenServer.call(server, {:retire_eviction_anchor, anchor_id})
  end

  @doc "Compare two positions in the store-owned eviction-authority ordering domain."
  def eviction_authority_position_before?(server \\ __MODULE__, first, second) do
    Commonplace.Store.EvictionAuthorityLedger.before?(resolve_db(server), first, second)
  end

  @doc "Find and verify the SLA tombstone covering a commit id, or return `:none`."
  def get_sla_tombstone_for_commit(server \\ __MODULE__, commit_id) do
    db = resolve_db(server)

    case CubDB.get(db, {:sla_tombstone_for_commit, commit_id}) do
      nil ->
        :none

      tombstone_id ->
        case CubDB.get(db, {:sla_tombstone, tombstone_id}) do
          nil ->
            {:error, {:sla_tombstone_index_corrupt, commit_id, tombstone_id}}

          tombstone ->
            case Commonplace.Store.SlaTombstone.verify(
                   tombstone,
                   Commonplace.Trust.config(),
                   store: server
                 ) do
              :ok -> {:ok, tombstone}
              {:error, reason} -> {:error, {:invalid_sla_tombstone, reason}}
            end
        end
    end
  end

  @doc """
  Persist a capability cert (CX-tdkq.22b). Content-addressed by its CID;
  idempotent. The cert is the immutable trust VALUE — not a CRDT doc.

  R4c carve-out: this is now a thin back-compat shim. The actual row lives
  in `Commonplace.Store.TrustSideStore`, and the `handle_call` below
  delegates to it (raises if this instance's TrustSideStore companion isn't
  running — see `trust_side_store_name/1`). Retained here because
  `Commonplace.Store.CommitStoreClient`'s remote mode addresses this
  GenServer's registered name directly over BEAM distribution.
  """
  def store_capability(server \\ __MODULE__, %Commonplace.Trust.Capability{} = cap) do
    GenServer.call(server, {:store_capability, cap})
  end

  @doc """
  Fetch a capability cert by CID. Returns `{:ok, cap}` or `:none`. Pure
  point-read, runs in the caller process (mirrors `get_commit/2`).
  """
  def get_capability(server \\ __MODULE__, cid) do
    case CubDB.get(resolve_db(server), {:capability, cid}) do
      nil -> :none
      cap -> {:ok, cap}
    end
  end

  @doc """
  Persist an immutable chit (`Commonplace.Store.Chit`). Content-addressed
  by its cid; idempotent — same cid means same content by construction,
  so re-storing overwrites with an equal value.

  The handler recomputes the cid BEFORE writing (`Chit.verify_cid/1`,
  the same id-gate-first posture as `import_commit`): a chit whose
  claimed cid does not match its own content is refused with
  `{:error, {:cid_mismatch, computed, claimed}}`, never silently stored.

  ⛔ Deliberately NOT routed through the doc-commit write verbs
  (`write_snapshot_cas` / `write_prebuilt_commit_cas` /
  `put_built_commit` / `put_latest`): a chit is a side-object VALUE, not
  a doc-head advance — storing one must never move a `{:latest}` pointer
  or fire commit PubSub. The write touches ONLY the `{:chit, cid}` row.
  """
  def store_chit(server \\ __MODULE__, %Commonplace.Store.Chit{} = chit) do
    GenServer.call(server, {:store_chit, chit})
  end

  @doc """
  Fetch a chit by cid. Returns `{:ok, chit}` or `:none`. Pure point-read
  on the `{:chit, cid}` row in the caller process (mirrors
  `get_capability/2` / `get_commit/2`) — returns the stored term
  uncoerced.
  """
  def get_chit(server \\ __MODULE__, cid) do
    case CubDB.get(resolve_db(server), {:chit, cid}) do
      nil -> :none
      chit -> {:ok, chit}
    end
  end

  @doc """
  Enumerate every stored chit cid, in key order. Read-only bounded range
  select over the `{:chit, cid}` keyspace — the enumeration seam the
  `:chit_ancestry` resting-state invariant re-verifies the corpus
  through (`Commonplace.Invariants.Registry`). Runs in the caller
  process (mirrors `all_doc_uuids/1`).
  """
  @spec all_chit_cids(GenServer.server()) :: [binary()]
  def all_chit_cids(server \\ __MODULE__) do
    do_all_chit_cids(resolve_db(server))
  end

  # --- execute_clean watermark cache (CX-tdkq.27) ---
  #
  # A node-LOCAL, NON-SYNCED derived verdict: "is the chain ending at this
  # snapshot/commit execute-clean under the trust config fingerprinted by `fp`?"
  # It is NOT a commit and NOT part of any commit's content address — federation
  # never reads or writes these keys, so the phase-2.5 deterministic-snapshot
  # property is untouched. Keying on `fp` (a fingerprint of the trusted set) means
  # a trust-config change self-invalidates stale verdicts. Correctness never
  # depends on it: Gate B's continue-default re-walks full append-only history on a
  # miss. See `Commonplace.Trust.authorized_to_execute?`.
  #
  # R4c carve-out: the underlying rows now live in
  # `Commonplace.Store.TrustSideStore`. Reads stay direct db point-reads here
  # (no TrustSideStore process needed — mirrors `get_capability/2`); the
  # mutating verbs (`put_execute_clean/4`, `flush_execute_clean/1`) delegate
  # to TrustSideStore, so an instance exercising these needs its
  # TrustSideStore companion running (e.g. via `Commonplace.Store.Supervisor`).

  @doc """
  Read a cached execute-clean verdict. `{:ok, boolean}` or `:miss`. Pure point-read
  in the caller process (mirrors `get_capability/2`).
  """
  @spec get_execute_clean(GenServer.server(), term(), binary()) :: {:ok, boolean()} | :miss
  def get_execute_clean(server \\ __MODULE__, fp, commit_id) do
    do_get_execute_clean(resolve_db(server), fp, commit_id)
  end

  @doc """
  Cache an execute-clean verdict. Fire-and-forget cast — a lost write just means
  the verdict is recomputed on the next walk, so the compile hot path never blocks
  on cache I/O. Forwarded to `Commonplace.Store.TrustSideStore` (cast-to-cast,
  still fire-and-forget end to end).
  """
  @spec put_execute_clean(GenServer.server(), term(), binary(), boolean()) :: :ok
  def put_execute_clean(server \\ __MODULE__, fp, commit_id, bool) when is_boolean(bool) do
    GenServer.cast(server, {:put_execute_clean, fp, commit_id, bool})
  end

  @doc "Drop every execute-clean cache entry (e.g. on a trust-config change — CX-tdkq.21)."
  @spec flush_execute_clean(GenServer.server()) :: :ok
  def flush_execute_clean(server \\ __MODULE__), do: GenServer.call(server, :flush_execute_clean)

  # --- revocation records (CX-bepn) ---
  #
  # Thin back-compat shims, same shape as store_capability/get_capability:
  # the actual rows live in `Commonplace.Store.TrustSideStore`; retained
  # here because `CommitStoreClient`'s remote mode addresses this
  # GenServer's registered name directly over BEAM distribution.

  @doc "Persist a revocation record (CX-bepn design §1/§8 step 2). See `TrustSideStore.store_revocation/2`."
  def store_revocation(server \\ __MODULE__, %Commonplace.Trust.Revocation{} = rev) do
    GenServer.call(server, {:store_revocation, rev})
  end

  @doc "Fetch every revocation filed against `revoked_cid`. `[]` if none. Pure point-read."
  def get_revocations(server \\ __MODULE__, revoked_cid) do
    case CubDB.get(resolve_db(server), {:revocation, revoked_cid}) do
      nil -> []
      list -> list
    end
  end

  @doc "The per-store revocation-set watermark (design §4). Pure point-read."
  def revocation_set_hash(server \\ __MODULE__) do
    case CubDB.get(resolve_db(server), {:revocation_meta, :set_hash}) do
      nil -> 0
      hash -> hash
    end
  end

  @doc """
  Return the local head commit for `doc_uuid` as `{:ok, commit}`,
  or `:none` if the doc has no `:latest` entry on this node.

  Emits a `[:commonplace, :commit, :latest_read]` telemetry event so
  the reflog amortization tests (CX-o8tx) can prove that clean
  subtrees were short-circuited without a read.
  """
  def latest_commit(server \\ __MODULE__, doc_uuid) do
    do_latest_commit(resolve_db(server), doc_uuid)
  end

  @doc "Walk the commit chain for a doc, returning commits newest-first."
  def commit_log(server \\ __MODULE__, doc_uuid, opts \\ []) do
    do_commit_log(resolve_db(server), doc_uuid, opts)
  end

  @doc """
  The shared ceiling for `commit_log/3` walks (CX-klpi). Callers that
  pass this as `:limit` and get back exactly this many results should
  treat the log as possibly-truncated — the walk may have stopped
  before reaching genesis.
  """
  # CX-ggdv: overridable so the cap-truncation branch of the bounded pin
  # walk can be exercised by a test. Reaching it for real needs a chain
  # deeper than 10,000 commits with no snapshot in range — buildable only
  # against production-sized history, which is how it stayed untested.
  # Nothing in production sets this; the default is the shipped cap.
  @spec max_commit_log_limit() :: pos_integer()
  def max_commit_log_limit,
    do: Application.get_env(:commonplace, :max_commit_log_limit, @max_commit_log_limit)

  @doc """
  Paged variant of `commit_log/3` (CX-klpi held half): walk the commit
  chain newest-first starting AT `commit_id` (inclusive) instead of at
  the doc's `:latest`. Lets a caller that already consumed one page
  (e.g. from `commit_log/3`) continue the walk from the last commit's
  `parent_id` without re-fetching from the head.

  Same option/return shape as `commit_log/3` — a bare list, newest-first,
  bounded by `opts[:limit]` (default 100). A result shorter than the
  requested limit means the walk ran out of chain (hit a missing parent
  or `nil`), not that it was denied.

  ## `until_snapshot: true` (CX-ggdv)

  Stop the walk **at and including** the first `%{kind: :snapshot}`
  commit encountered. A snapshot commit is a self-contained encoding of
  the doc state at that point, so no reader ever needs its ancestors —
  every walk that ends in `trim_to_latest_snapshot/1` was fetching (and
  deserializing) those ancestors only to throw them away.

  This is the store-side half of walk-bounding: the stop happens where
  the rows are, so the pre-snapshot commits are never read off disk and
  never cross the GenServer/`:erpc` boundary. `Commonplace.Tree.DocBuilder.chain_to/4`
  is the caller that makes pin reads O(distance-to-nearest-snapshot)
  instead of O(total chain length).

  Note the walk is a pure `parent_id` walk and stays doc-agnostic: a
  chain that crosses into a foreign `doc_uuid` (fork lineage, 2.2% of
  docs) is traversed exactly as before.
  """
  @spec commit_log_from(GenServer.server(), String.t() | nil, keyword()) :: [Commit.t()]
  def commit_log_from(server \\ __MODULE__, commit_id, opts \\ []) do
    do_commit_log_from(resolve_db(server), commit_id, opts)
  end

  @doc "Return a MapSet of all document UUIDs that have a `:latest` entry."
  def all_doc_uuids(server \\ __MODULE__) do
    do_all_doc_uuids(resolve_db(server))
  end

  @doc "Return at most `limit` document UUIDs, refusing after reading one control row beyond it."
  def all_doc_uuids_bounded(server \\ __MODULE__, limit) when is_integer(limit) and limit > 0 do
    do_all_doc_uuids_bounded(resolve_db(server), limit)
  end

  @doc """
  World-B audit (plan #13407): the full-population data, read in a SINGLE
  UNBOUNDED pass over the whole keyspace, routing each key by its shape:

    * `p_latest`         — doc_uuids from `{:latest, doc_uuid}` (= `all_doc_uuids`)
    * `ids_from_structs` — commit ids from `{:commit, id}` KEYS — ground-truth
                           commit objects, by id only. It deliberately does NOT
                           read the struct value's `.doc_uuid`, a debug trace of
                           the first writer (excluded from the id hash, stale
                           after forks — `commit.ex:52`), which is NOT ownership.
    * `doc_commit_ids`   — `%{doc_uuid => MapSet(commit_ids)}` from
                           `{:doc_commit, doc_uuid, id}` keys — the authoritative
                           doc→commit map, `{:latest}`-independent, GROUPED so a
                           later pass can partition orphans by their commit set
                           (e.g. genesis-only vs has-content — plan #14166/#14170).
                           `p_doccommit` (its keys) and `ids_from_doc_index` (the
                           union of its values) are derived by the audit.

  ⛔ WHY ONE UNBOUNDED PASS, NOT PER-KEYSPACE `min_key/max_key` SCANS (plan
  #14155). Two bounded scans that shared the CX-mg8s `<<255>>` range-bound idiom
  would drop the SAME high ids from BOTH `{:commit}` and `{:doc_commit}`; Axis B's
  diff (`ids_from_structs` vs `ids_from_doc_index`) would then come back empty and
  FALSELY certify the reference, while Axis A runs on a truncated population and
  misses orphans among the dropped ids — both axes defeated silently, green. That
  is a shared-IMPLEMENTATION common-mode failure the pure `verdict/1` controls
  cannot see (it lives in the fetch). An UNBOUNDED `CubDB.select` has no range
  bound to get wrong, so the common mode cannot exist. `commit_population_audit_test`
  pins this with an enumerator-level positive control: a key ABOVE the historical
  suspect bound (`<<255, …>>`) MUST appear in the scan.

  O(store) — the unbounded scan deserializes every value; the run is host-gated
  (§3 ceremony + `MemorySwapMax=0`) for exactly this cost. Same idiom as the
  recovery `walk_and_salvage` (unbounded select + shape filter).
  """
  @spec population_scan(GenServer.server()) :: %{
          p_latest: MapSet.t(),
          ids_from_structs: MapSet.t(),
          doc_commit_ids: %{optional(String.t()) => MapSet.t()}
        }
  def population_scan(server \\ __MODULE__) do
    do_population_scan(resolve_db(server))
  end

  @doc """
  The import enumeration: every document that is importable, plus its head
  pointer where it has one, from ONE unbounded pass over the keyspace.

  `population_scan/1` already answers most of this, but it reports
  `p_latest` as doc_uuids ONLY — presence of a head, not which commit the
  head is. Import needs the commit id itself, because a head pointer is
  the default pin offered to the destination. Rather than have the caller
  reach for `db_handle/1`, the pass lives here, in the layer that owns the
  handle.

    * `owned` — doc_uuids from `{:doc_commit, doc_uuid, _}` keys. THE
      ownership fact: `{:latest}`-independent and fork-safe. Never
      `commit.doc_uuid`, which is a first-writer trace (`commit.ex:52`),
      excluded from the id hash and measured wrong for 116 docs.
    * `heads` — `%{doc_uuid => commit_id}` from `{:latest, doc_uuid}`.

  Both populations come from the SAME traversal, which is what makes them
  comparable at all: two passes could see two different stores. And the
  pass is UNBOUNDED for the CX-mg8s reason carried throughout this module
  — a range bound shared by both keyspaces drops the same high end from
  both, so the difference between them comes back empty and certifies a
  truncated population as clean.

  O(store): deserializes every value. Import is a one-shot migration
  operation, not a request path.
  """
  @spec import_population(GenServer.server()) :: %{
          owned: MapSet.t(),
          heads: %{optional(String.t()) => binary()}
        }
  def import_population(server \\ __MODULE__) do
    do_import_population(resolve_db(server))
  end

  @doc """
  The `{:doc_commit}` index readiness state (`@doc_commit_index_ready` when
  built). World-B checks this before trusting the `{:doc_commit}` populations:
  a not-ready index scanned fully is partial/interrupted, and its doc_uuids are
  NOT authoritative — the audit reports index-unavailable rather than emitting
  a fabricated full-population diff over a half-built index.
  """
  def doc_commit_index_state(server \\ __MODULE__) do
    CubDB.get(resolve_db(server), @doc_commit_index_state_key)
  end

  @doc "The value `doc_commit_index_state/1` returns when the index is fully built."
  def doc_commit_index_ready, do: @doc_commit_index_ready

  @doc "Return the append-only set of bd issue-document UUIDs recorded as CREATED."
  def bd_issue_doc_uuids(server \\ __MODULE__) do
    do_bd_issue_doc_uuids(resolve_db(server))
  end

  @doc "Append one pre-existing issue document to the CREATED index (one-time backfill only)."
  def append_bd_issue_doc(server \\ __MODULE__, doc_uuid) when is_binary(doc_uuid) do
    GenServer.call(server, {:append_bd_issue_doc, doc_uuid})
  end

  @doc "Return recorded issue-index backfill corrections keyed by document UUID."
  def bd_issue_doc_supersessions(server \\ __MODULE__) do
    do_bd_issue_doc_supersessions(resolve_db(server))
  end

  @doc "Record an immutable correction that supersedes a spurious backfill index row."
  def append_bd_issue_doc_supersession(server \\ __MODULE__, doc_uuid, reason)
      when is_binary(doc_uuid) do
    GenServer.call(server, {:append_bd_issue_doc_supersession, doc_uuid, reason})
  end

  @doc "Check if `ancestor_id` is an ancestor of `descendant_id` in the commit DAG."
  def is_ancestor?(server \\ __MODULE__, ancestor_id, descendant_id) do
    do_is_ancestor(resolve_db(server), ancestor_id, descendant_id)
  end

  @doc """
  Point `doc_uuid`'s `:latest` at an existing commit without
  creating a new one. The caller is responsible for ensuring the
  target commit is already persisted and that re-pointing is
  causally safe — there is no ancestry check here.

  Used by cross-epoch merge to install a pre-built merge commit
  (CX-fdjh) and by tests that need to construct specific DAG
  shapes. Not a substitute for the CAS variants when concurrent
  writers might race.
  """
  def set_latest(server \\ __MODULE__, doc_uuid, commit_id) do
    GenServer.call(server, {:set_latest, doc_uuid, commit_id})
  end

  @doc "Return a MapSet of all commit IDs for a document (walks the chain)."
  def commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
    collect_commit_ids(resolve_db(server), doc_uuid)
  end

  @doc """
  Idempotently stamp the deterministic genesis commit for `doc_uuid`
  (CX-fzi). Returns `{:ok, genesis}`.

  Genesis is a pure function of `doc_uuid` (see `Commit.genesis/1`), so
  two calls for the same uuid return the same commit and store to the
  same id. `:latest` is NOT touched — callers wire genesis in as the
  parent of the first real commit themselves (deferred to the bead that
  flips on namespace validation). This is the primitive; auto-wiring
  into `create_commit` is explicitly out of scope for CX-fzi.
  """
  def ensure_genesis(server \\ __MODULE__, doc_uuid) do
    GenServer.call(server, {:ensure_genesis, doc_uuid})
  end

  @doc """
  Store a commit without updating :latest. Used for catch-up sync.

  Accepts an optional `:validator` keyword function of arity 1 that
  receives the incoming commit and returns `:ok | {:error, reason}`.
  When rejected, the commit is NOT persisted and `:latest` is NOT
  modified (CX-bv3). The default validator is a no-op stub that
  accepts every commit; CX-ch5 replaces the default with the real
  Yelixer namespace-membership check once the primitive lands.
  """
  def import_commit(server \\ __MODULE__, commit, opts \\ []) do
    GenServer.call(server, {:import_commit, commit, opts})
  end

  @doc """
  CX-xrds: out-of-band salvage for a `.corrupt.<ts>` archive directory
  left behind by `init/1`'s recovery path (see the moduledoc "CubDB
  crash recovery" section).

  Recovery granularity elsewhere in this module stays whole-store —
  this is deliberately NOT per-key quarantine wired into `init/1`
  itself. It's a separate, explicitly-invoked tool: opens the archived
  CubDB **read-only, in its own process**, so it never touches (or
  risks corrupting further) the archive, then streams every
  `{:commit, id}` entry it can still read and re-imports each one into
  `target_server` (a live `CommitStore` pid/name, default
  `__MODULE__`) via the normal `import_commit/3` front door — so Gate
  A id-verification and Gate B trust/namespace validation apply to
  every salvaged commit exactly as they would to a freshly-written
  one, and re-importing a commit already present in the target store
  is a safe no-op (content-addressed idempotency).

  Each entry is read and imported inside its own `rescue`/`catch`, so
  one damaged record doesn't abort the walk — the corruption that put
  the store here rarely announces itself in advance.

  Returns `{:ok, %{salvaged: n, skipped: n}}` on success (`skipped`
  counts entries that failed to read, failed to decode, or were
  rejected by `import_commit/3`'s validation), or `{:error, reason}`
  if the archive itself couldn't be opened at all.
  """
  def salvage_corrupt_archive(corrupt_dir, target_server \\ __MODULE__) do
    # CX-2479: this open is deliberately NOT under the commits.lock. It
    # opens a `commits.<ts>.corrupt` ARCHIVE directory — a path no live
    # CommitStore ever holds open, already renamed out of the store's
    # position — so it cannot become a second appender on the live store.
    # The live store it writes INTO is reached through `import_commit/3`
    # on the running `target_server`, i.e. through that store's own
    # lock-holding process, which is the sanctioned door.
    case CubDB.start_link(data_dir: corrupt_dir, auto_file_sync: false, auto_compact: false) do
      {:ok, db} ->
        try do
          {:ok, walk_and_salvage(db, target_server)}
        after
          CubDB.stop(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp walk_and_salvage(db, target_server) do
    keys =
      try do
        db
        |> CubDB.select()
        |> Stream.filter(fn {key, _value} -> match?({:commit, _id}, key) end)
        |> Stream.map(fn {key, _value} -> key end)
        |> Enum.to_list()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    Enum.reduce(keys, %{salvaged: 0, skipped: 0}, fn key, acc ->
      salvage_one(db, key, target_server, acc)
    end)
  end

  defp salvage_one(db, key, target_server, acc) do
    case CubDB.get(db, key) do
      %Commonplace.Store.Commit{} = commit ->
        case import_commit(target_server, commit) do
          result when result in [:ok, :already_exists] ->
            %{acc | salvaged: acc.salvaged + 1}

          _other ->
            %{acc | skipped: acc.skipped + 1}
        end

      _other ->
        %{acc | skipped: acc.skipped + 1}
    end
  rescue
    _ -> %{acc | skipped: acc.skipped + 1}
  catch
    _, _ -> %{acc | skipped: acc.skipped + 1}
  end

  @doc """
  Legacy pass-through — retained for back-compat.

  Prior to CX-ch5 this was the default validator; the real default is
  now `Commonplace.Store.Namespace.validate_commit_from_db/2`, invoked
  directly from `handle_call({:import_commit, ...})` with the state's
  CubDB handle. Callers that still pass this function explicitly via
  `validator:` get stub pass-through behavior, matching the pre-swap
  contract.
  """
  def default_namespace_validator(_commit), do: :ok

  @doc "Find the most recent common ancestor between two UUID chains."
  def find_common_ancestor(server \\ __MODULE__, uuid_a, uuid_b) do
    do_find_common_ancestor(resolve_db(server), uuid_a, uuid_b)
  end

  @doc "Store the commit ID of the source at the time of a merge, for incremental merging."
  def set_merge_point(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_merge_point, target_uuid, source_uuid, commit_id})
  end

  @doc "Retrieve the stored merge point commit ID for a (target, source) pair."
  def get_merge_point(server \\ __MODULE__, target_uuid, source_uuid) do
    CubDB.get(resolve_db(server), {:merge_point, target_uuid, source_uuid})
  end

  @doc "Record the target's head commit after any merge (keyed by target+source and target-only)."
  def set_last_merge_commit(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_last_merge_commit, target_uuid, source_uuid, commit_id})
  end

  @doc "Get the target's head commit after the most recent merge from any source."
  def get_latest_merge_head(server \\ __MODULE__, target_uuid) do
    CubDB.get(resolve_db(server), {:latest_merge_head, target_uuid})
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    # sol/s-snapshot-fresh-s3: freeze the caller's cwd before join/lock/CubDB use;
    # compaction creates by path and otherwise re-resolves a relative store under mix.
    data_dir = opts |> Keyword.fetch!(:data_dir) |> Path.expand()
    flock_module = Keyword.get(opts, :flock_module, Commonplace.Flock)
    path = Path.join(data_dir, "commits")

    # CX-2479: take the exclusion BEFORE any CubDB open. See
    # `acquire_commits_lock/1`.
    case acquire_commits_lock(data_dir, flock_module) do
      {:ok, lock_ref} -> init_locked(opts, name, data_dir, path, lock_ref)
      {:stop, _} = stop -> stop
    end
  end

  defp init_locked(opts, name, data_dir, path, lock_ref) do
    File.mkdir_p!(path)

    # R4c carve-out: the names of this instance's companion processes
    # (Commonplace.Store.TrustSideStore, Commonplace.Store.PendingImports).
    # Default to `nil` — NOT the bare module names — so a bare
    # `CommitStore.start_link/1` (started standalone, e.g. by a test that
    # only exercises plain commit reads/writes) never silently addresses
    # whatever process happens to be registered under the production
    # default name (notably the real singleton `Commonplace.Application`
    # boots for the whole test run). `nil` is a genuine "no companion"
    # sentinel: pending-import casts become no-ops (see
    # `maybe_notify_landed/2` / `maybe_enqueue_pending/4` below) and the capability/
    # execute_clean shims raise if actually invoked (correctly — those
    # verbs need `Commonplace.Store.Supervisor`'s trio wiring, which always
    # passes explicit names, never relies on this default).
    trust_side_store = Keyword.get(opts, :trust_side_store, nil)
    pending_imports = Keyword.get(opts, :pending_imports, nil)

    # CX-jfok: the post-advance invariant alarm's mailbox (see
    # `put_latest/5`). A NAME, not a pid, and dispatch is a plain cast —
    # so a store started before/without the dispatcher (tests, one-shot
    # CLI, library embedding) writes exactly as it did before. Injectable
    # so a test can register itself as the dispatcher.
    invariant_dispatcher =
      Keyword.get(opts, :invariant_dispatcher, Commonplace.Invariants.Dispatcher)

    local_write_gate = Keyword.get(opts, :local_write_gate, :ambient)

    case open_cubdb(path) do
      {:ok, db} ->
        case probe_integrity(db) do
          :ok ->
            ready(
              name,
              db,
              data_dir,
              trust_side_store,
              pending_imports,
              invariant_dispatcher,
              local_write_gate,
              lock_ref
            )

          {:error, reason} ->
            CubDB.stop(db)

            refuse_or_recover(
              :probe,
              reason,
              name,
              data_dir,
              path,
              trust_side_store,
              pending_imports,
              invariant_dispatcher,
              local_write_gate,
              lock_ref
            )
        end

      {:error, reason} ->
        refuse_or_recover(
          :open,
          reason,
          name,
          data_dir,
          path,
          trust_side_store,
          pending_imports,
          invariant_dispatcher,
          local_write_gate,
          lock_ref
        )
    end
  end

  @root_pointer_file "root"

  @doc """
  CX-pm68: did a world already exist in this `data_dir`?

  True iff `<data_dir>/root` — the workspace root-document pointer
  (`Commonplace.Workspace.root_uuid/0` reads it) — is present.

  **Why the root pointer and not the commits store itself.** The question
  being asked is "was there a world here before this boot?", and it is
  being asked precisely at the moment the commits store is unreadable. Any
  evidence read out of `commits/` is evidence the corruption event could
  have destroyed, so a missing signal there is indistinguishable between
  "never existed" and "just got eaten" — a check that cannot tell those
  apart cannot be allowed to authorize erasure. `root` is a SEPARATE
  small file, written once at workspace init and never touched by the
  commit-write path, so a corrupt-store event cannot remove it. Its
  presence is therefore positive evidence of a prior world that survives
  the very failure this guard fires on.
  """
  def prior_world_evidence?(data_dir) do
    File.exists?(Path.join(data_dir, @root_pointer_file))
  end

  @doc """
  CX-pm68 override: has an operator explicitly consented to a fresh
  re-init over a prior world?

  Application env `:accept_fresh_reinit`, bridged from
  `COMMONPLACE_ACCEPT_FRESH_REINIT` in `config/runtime.exs` the same way
  `:local_write_gate` is. Defaults to `false` — fail closed. This is a
  deliberate, recorded act, never an ambient default: when it is used, the
  fresh store carries a `{:fresh_reinit_fact, <iso8601>}` row saying so.
  """
  def accept_fresh_reinit? do
    Application.get_env(:commonplace, :accept_fresh_reinit, false) == true
  end

  # CX-pm68. BOTH archive-and-start-fresh sites (probe-corrupt and
  # failed-open) funnel through here.
  #
  # What was wrong: both sites silently substituted an EMPTY store and kept
  # serving. This morning that put an enforce-mode serve on a fresh empty
  # world, writing genesis docs — the substrate cannot tell
  # empty-because-new from empty-because-broke, so it treated a destroyed
  # world as a new one and started filling it in.
  #
  # An empty dir must still boot (first boot, and every test fixture), so
  # the discriminator is prior-world EVIDENCE, not corruption severity.
  defp refuse_or_recover(
         site,
         reason,
         name,
         data_dir,
         path,
         trust_side_store,
         pending_imports,
         invariant_dispatcher,
         local_write_gate,
         lock_ref
       ) do
    require Logger

    cond do
      not prior_world_evidence?(data_dir) ->
        Logger.warning(
          "CubDB #{site_phrase(site)} (#{inspect(reason)}). No prior-world evidence " <>
            "(no #{Path.join(data_dir, @root_pointer_file)}) — treating as a first boot, " <>
            "archiving and starting fresh."
        )

        recover_cubdb(
          name,
          path,
          trust_side_store,
          pending_imports,
          invariant_dispatcher,
          local_write_gate,
          lock_ref,
          nil
        )

      accept_fresh_reinit?() ->
        Logger.warning(
          "CubDB #{site_phrase(site)} (#{inspect(reason)}). A PRIOR WORLD EXISTS " <>
            "(#{Path.join(data_dir, @root_pointer_file)} present) but :accept_fresh_reinit " <>
            "is set — proceeding with archive-and-fresh by explicit operator consent. " <>
            "A {:fresh_reinit_fact, <iso8601>} row is being written into the fresh store " <>
            "so this empty world is durably marked empty-because-broke, not " <>
            "empty-because-new. (CX-pm68)"
        )

        recover_cubdb(
          name,
          path,
          trust_side_store,
          pending_imports,
          invariant_dispatcher,
          local_write_gate,
          lock_ref,
          reason
        )

      true ->
        detail = %{
          data_dir: data_dir,
          corrupt_path: path,
          reason: reason,
          evidence: :root_file_present,
          override: override_instructions()
        }

        Logger.error("""
        CommitStore: REFUSING TO BOOT — will not re-initialize an empty world over a prior one.
          Corrupt commits store: #{path}
          CubDB #{site_phrase(site)}: #{inspect(reason)}
          Prior world EXISTS: #{Path.join(data_dir, @root_pointer_file)} is present, so this \
        workspace held a world before this boot.
          NO archive and NO re-initialization was performed. Nothing on disk was changed.
          Recovery is a HUMAN/OPERATOR decision, not an automatic one. Options:
            * truncate-to-last-valid-header on the damaged .cub, then reopen;
            * salvage what is readable with \
        Commonplace.Store.CommitStore.salvage_corrupt_archive/2 into a fresh store;
            * if the empty world is genuinely what you want: #{override_instructions()}
        (CX-pm68)\
        """)

        {:stop, {:refusing_fresh_reinit, detail}}
    end
  end

  defp site_phrase(:probe), do: "corrupt on probe"
  defp site_phrase(:open), do: "failed to open"

  defp override_instructions do
    "set COMMONPLACE_ACCEPT_FRESH_REINIT=1 (app env :accept_fresh_reinit) and reboot — " <>
      "this is a deliberate, recorded act and the fresh store will carry a " <>
      ":fresh_reinit_fact row naming the archived predecessor."
  end

  @commits_lock_file "commits.lock"

  @doc """
  The `<data_dir>/commits.lock` path (CX-2479). Public so operators and
  tests can name the file the exclusion actually lives on.
  """
  def commits_lock_path(data_dir), do: Path.join(data_dir, @commits_lock_file)

  # CX-2479. Two appenders on one CubDB directory corrupted the live store.
  #
  # THE EXCLUSION IS THE flock(2), NOT THE FILE CONTENT. Before this, the
  # only thing at `<data_dir>/commits.lock` was a pid string that a second
  # process cheerfully overwrote before proceeding — advisory prose,
  # `kill -0` alive-check and all. (`Commonplace.CLI.acquire_db_lock/1`
  # kept a second copy of that scheme over this same file until CX-x8jk
  # deleted it.) The pid+node line we write here is DIAGNOSTIC ONLY: a hint for a
  # human staring at a refusal, never a proof of who holds the lock and
  # never consulted to decide whether to proceed. The kernel decides.
  #
  # WHY data_dir/commits.lock AND NOT commits/commits.lock: `recover_cubdb`
  # archives by RENAMING the `commits/` directory. A lock file inside that
  # directory would travel with the archive and the fd would point at a
  # path no longer in the store's position — the exclusion would silently
  # stop covering the fresh `commits/`. Living one level up in `data_dir`,
  # the lock file is untouched by the rename, so one continuous hold covers
  # open → archive → fresh-open with no window. (Same reason
  # `Workspace.Lock` puts `serve.lock` in `data_dir`.)
  #
  # Non-blocking: `Flock.try_lock/2`, not the fail-open
  # `with_exclusive_lock/3` helper — the whole point is to fail CLOSED.
  defp acquire_commits_lock(data_dir, flock_module) do
    require Logger
    path = commits_lock_path(data_dir)

    File.mkdir_p!(data_dir)
    File.touch!(path)

    # Read the incumbent's hint BEFORE we overwrite it with our own.
    hint = Commonplace.Store.LockRefusal.holder_hint(path)

    case try_flock(flock_module, path) do
      {:ok, ref} ->
        File.write(path, "#{System.pid()} #{node()}\n")
        {:ok, ref}

      {:flock_unavailable, load_reason} ->
        remedy = flock_unavailable_remedy(load_reason)

        Logger.error("""
        CommitStore: refusing to open #{Path.join(data_dir, "commits")} — flock_nif.so is \
        unavailable, so single-opener exclusion cannot be guaranteed.
          #{remedy}
        No CubDB open was attempted. (CX-a449)\
        """)

        {:stop, {:flock_unavailable, remedy}}

      {:error, reason} ->
        detail = %{
          lock_path: path,
          holder_hint: hint,
          reason: reason,
          sanctioned_access: sanctioned_access_message()
        }

        Logger.error("""
        CommitStore: refusing to open #{Path.join(data_dir, "commits")} — the commits store is \
        LOCKED by another live process (flock on #{path}, #{inspect(reason)}).
          Holder hint (NOT proof — diagnostic content of the lock file): #{detail.holder_hint}
          #{detail.sanctioned_access}
        No CubDB open was attempted; nothing on disk was touched. (CX-2479)\
        """)

        {:stop, {:commits_store_locked, detail}}
    end
  end

  defp try_flock(flock_module, path) do
    case Code.ensure_loaded(flock_module) do
      {:module, ^flock_module} ->
        try do
          apply(flock_module, :try_lock, [path, :exclusive])
        rescue
          error in [UndefinedFunctionError, ErlangError] ->
            {:flock_unavailable, Exception.message(error)}
        catch
          :error, :undef -> {:flock_unavailable, :undef}
        end

      {:error, reason} ->
        {:flock_unavailable, reason}
    end
  end

  defp flock_unavailable_remedy(reason) do
    "flock NIF load failed (#{inspect(reason)}). Reinstall or rebuild the CLI so " <>
      "commonplace/priv/flock_nif.so is present and loadable; refusing the local " <>
      "CommitStore rather than opening it without an OS lock."
  end

  # CX-2479 rider: the incident's trigger was a legitimate read need going
  # through an illegitimate door. A refusal that only says "no" breeds the
  # workaround; this names the sanctioned door instead. CX-x8jk moved the
  # prose to Commonplace.Store.LockRefusal so the CLI's tool-layer refusal
  # says exactly the same thing without a second copy to drift.
  defp sanctioned_access_message,
    do: Commonplace.Store.LockRefusal.sanctioned_access_message()

  # R4(a): publish the CubDB handle so reads can run in the caller process
  # against it directly, never queuing behind a write in this GenServer's
  # mailbox (CX-tdkq.4). Keyed by the registered name so isolated test stores
  # and the production singleton don't collide; resolve_db/1 falls back to a
  # cheap `:get_db` call for callers that hold a pid rather than the name.
  #
  # R4c carve-out: the R11 pending-imports queue and the capability/
  # execute_clean rows no longer live in this GenServer's state — they were
  # extracted to `Commonplace.Store.TrustSideStore` (capability certs +
  # execute_clean watermarks) and `Commonplace.Store.PendingImports` (the R11
  # retry queue). This state only remembers WHICH instances of those
  # companion processes belong to this CommitStore, so the back-compat shims
  # below know where to delegate.
  defp ready(
         name,
         db,
         data_dir,
         trust_side_store,
         pending_imports,
         invariant_dispatcher,
         local_write_gate,
         lock_ref
       ) do
    ensure_doc_commit_index(db)
    :persistent_term.put({__MODULE__, :db, name}, db)
    :persistent_term.put({__MODULE__, :trust_side_store, name}, trust_side_store)
    :persistent_term.put({__MODULE__, :pending_imports, name}, pending_imports)
    queue_poller = maybe_start_queue_poller(name)

    {:ok,
     %{
       db: db,
       data_dir: data_dir,
       name: name,
       queue_poller: queue_poller,
       trust_side_store: trust_side_store,
       pending_imports: pending_imports,
       invariant_dispatcher: invariant_dispatcher,
       local_write_gate: local_write_gate,
       # CX-2479: the flock(2) hold on <data_dir>/commits.lock. Released
       # in terminate/2 — and by the kernel regardless, since the fd lives
       # in a NIF resource owned by this process's heap, which the VM frees
       # (running the resource destructor, hence close(2), hence release)
       # when the process dies for ANY reason including :kill. Measured
       # 2026-08-06: reacquire after Process.exit(holder, :kill) succeeded
       # in 0ms, so a supervisor restarting immediately never deadlocks
       # against its own dead predecessor. No takeover logic is needed or
       # wanted — a takeover path is precisely how a real holder gets
       # evicted and the store gets two appenders again.
       lock_ref: lock_ref
     }}
  end

  # CX-9hql (R4c rung-0): start the companion mailbox-depth poller unless
  # disabled via `config :commonplace, commit_store_queue_poll_ms: nil | false`
  # (disabled by default in the test env — see config/test.exs). Started
  # unlinked so a poller crash never takes the store down; it only monitors
  # us, not vice versa.
  defp maybe_start_queue_poller(name) do
    case Application.get_env(:commonplace, :commit_store_queue_poll_ms, 5_000) do
      ms when is_integer(ms) and ms > 0 ->
        case Commonplace.Store.CommitStoreQueuePoller.start(
               target_pid: self(),
               store_name: name,
               interval_ms: ms
             ) do
          {:ok, pid} -> pid
          _ -> nil
        end

      _disabled ->
        nil
    end
  end

  @impl true
  def terminate(_reason, %{name: name} = state) do
    :persistent_term.erase({__MODULE__, :db, name})
    :persistent_term.erase({__MODULE__, :trust_side_store, name})
    :persistent_term.erase({__MODULE__, :pending_imports, name})

    case Map.get(state, :queue_poller) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    release_commits_lock(state)

    :ok
  end

  def terminate(_reason, state), do: release_commits_lock(state)

  # CX-2479: best-effort, never crashes. terminate/2 runs on paths where
  # the resource may already be gone (double-stop, VM shutdown); a raising
  # terminate would turn a clean stop into a crash report and, worse, skip
  # nothing useful — the kernel releases the flock on process death anyway.
  defp release_commits_lock(state) when is_map(state) do
    case Map.get(state, :lock_ref) do
      nil -> :ok
      ref -> Commonplace.Flock.unlock(ref)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp release_commits_lock(_state), do: :ok

  defp open_cubdb(path) do
    # Trap exits so CubDB init crashes don't kill us
    old_trap = Process.flag(:trap_exit, true)

    result =
      try do
        CubDB.start_link(
          data_dir: path,
          auto_file_sync: true,
          auto_compact: true
        )
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, reason}
        kind, reason -> {:error, {kind, reason}}
      end

    # Drain any EXIT message from the failed CubDB process
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, old_trap)
    result
  end

  defp recover_cubdb(
         name,
         path,
         trust_side_store,
         pending_imports,
         invariant_dispatcher,
         local_write_gate,
         lock_ref,
         fresh_reinit_reason
       ) do
    # CX-2479: the lock is NOT released around this rename. It lives at
    # <data_dir>/commits.lock — a sibling of the `commits/` directory being
    # renamed, not a child of it — so the rename neither moves the locked
    # file nor invalidates the fd. One continuous hold spans archive and
    # fresh-open; there is no window in which a second opener could slip in
    # and start writing the fresh store alongside us.
    archive_path = archive_corrupt_db(path)

    {:ok, db} =
      CubDB.start_link(
        data_dir: path,
        auto_file_sync: true,
        auto_compact: true
      )

    write_fresh_reinit_fact(db, archive_path, fresh_reinit_reason)

    ready(
      name,
      db,
      Path.dirname(path),
      trust_side_store,
      pending_imports,
      invariant_dispatcher,
      local_write_gate,
      lock_ref
    )
  end

  # CX-pm68 rider: when an operator overrode the refusal, the fresh store
  # records WHY it is empty, before it serves a single read. This is the
  # empty-because-broke / empty-because-new distinction made durable and
  # in-band: anything later inspecting this store — a human, an audit, a
  # future guard — can see that this world replaced a broken one and where
  # the predecessor's bytes went. `nil` reason means no prior world existed
  # (a genuine first boot), and nothing is written: an empty store with no
  # fact row means empty-because-new, and that must stay the common case.
  defp write_fresh_reinit_fact(_db, _archive_path, nil), do: :ok

  defp write_fresh_reinit_fact(db, archive_path, reason) do
    CubDB.put(db, {:fresh_reinit_fact, DateTime.utc_now() |> DateTime.to_iso8601()}, %{
      predecessor_archive: archive_path,
      reason: inspect(reason),
      evidence: :root_file_present
    })
  end

  @impl true
  def handle_call({:create_commit, doc_uuid, update, parent_id, metadata}, _from, state) do
    instrumented(:create_commit, doc_uuid, fn ->
      commit = do_write_commit(:create_commit, state, doc_uuid, update, parent_id, metadata, [])
      {:reply, commit, state}
    end)
  end

  @impl true
  def handle_call(
        {:put_built_commit, %Commit{} = commit, expected_parent_id, genesis, deadline},
        from,
        state
      )
      when is_integer(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, :deadline_expired}, state}
    else
      handle_call({:put_built_commit, commit, expected_parent_id, genesis, []}, from, state)
    end
  end

  @impl true
  def handle_call(
        {:put_built_commit, %Commit{} = commit, expected_parent_id, genesis, opts, deadline},
        from,
        state
      )
      when is_list(opts) and is_integer(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, :deadline_expired}, state}
    else
      handle_call({:put_built_commit, commit, expected_parent_id, genesis, opts}, from, state)
    end
  end

  @impl true
  def handle_call(
        {:create_commit, doc_uuid, update, parent_id, metadata, opts},
        _from,
        state
      ) do
    instrumented(:create_commit, doc_uuid, fn ->
      commit = do_write_commit(:create_commit, state, doc_uuid, update, parent_id, metadata, opts)
      {:reply, commit, state}
    end)
  end

  @impl true
  def handle_call(
        {:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id},
        _from,
        state
      ) do
    instrumented(:write_snapshot_cas, doc_uuid, fn ->
      case CubDB.get(state.db, {:latest, doc_uuid}) do
        ^expected_parent_id ->
          metadata = Map.put(metadata, :kind, :snapshot)

          commit = Commit.new(doc_uuid, update, expected_parent_id, metadata)
          warn_if_non_system_cas(commit, :snapshot_cas)
          commit = maybe_sign_commit(commit)

          put_latest(state, doc_uuid, commit.id, :snapshot_cas, commit_rows(commit))

          :telemetry.execute(
            [:commonplace, :commit, :create],
            %{system_time: System.system_time()},
            %{doc_uuid: doc_uuid}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "commits:#{doc_uuid}",
            {:commit, doc_uuid, commit.id, metadata}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "blue:#{doc_uuid}",
            {:commit, doc_uuid, commit.id, metadata}
          )

          {:reply, {:ok, commit}, state}

        _other ->
          {:reply, {:error, :parent_moved}, state}
      end
    end)
  end

  @impl true
  def handle_call({:write_prebuilt_commit_cas, %Commit{} = commit}, _from, state) do
    instrumented(:write_prebuilt_commit_cas, commit.doc_uuid, fn ->
      # Phase 2.5 (CX-tdkq.24): a prebuilt commit is a system-minted merge
      # (Merger/CrossEpochMerge → Commit.new, never signed). Node-sign it
      # so strict mode accepts it. Signing is over the id, which is already
      # bound — so the CAS dedup (keyed on id) is unaffected.
      #
      # CX-hoj: only system kinds (:snapshot / :merge) are meant to reach
      # this bare (no signing_context) call — a future user-payload path
      # through prebuilt-CAS must not silently inherit ambient/node
      # identity, so warn + telemetry loudly if one ever does.
      warn_if_non_system_cas(commit, :prebuilt_cas)
      commit = maybe_sign_commit(commit)

      case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
        latest_id when latest_id == commit.parent_id ->
          put_latest(state, commit.doc_uuid, commit.id, :prebuilt_cas, commit_rows(commit))

          :telemetry.execute(
            [:commonplace, :commit, :create],
            %{system_time: System.system_time()},
            %{doc_uuid: commit.doc_uuid}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "commits:#{commit.doc_uuid}",
            {:commit, commit.doc_uuid, commit.id, commit.metadata}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "blue:#{commit.doc_uuid}",
            {:commit, commit.doc_uuid, commit.id, commit.metadata}
          )

          {:reply, {:ok, commit}, state}

        _other ->
          {:reply, {:error, :parent_moved}, state}
      end
    end)
  end

  @impl true
  def handle_call(
        {:put_built_commit, %Commit{} = commit, expected_parent_id, genesis},
        from,
        state
      ) do
    handle_call({:put_built_commit, commit, expected_parent_id, genesis, []}, from, state)
  end

  @impl true
  def handle_call(
        {:put_built_commit, %Commit{} = commit, expected_parent_id, genesis, opts},
        _from,
        state
      )
      when is_list(opts) do
    instrumented(:put_built_commit, commit.doc_uuid, fn ->
      {cas_result, persist_ns} =
        timed(fn ->
          case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
            ^expected_parent_id ->
              # CX-qat5.3: the local-write gate runs HERE — after the CAS
              # match (so a stale-parent retry never even reaches the trust
              # check) and BEFORE put_multi (so a rejection persists
              # nothing, including the piggy-backed genesis row — see
              # local_write_gate_check/3).
              case local_write_gate_check(commit, state, opts) do
                :ok ->
                  extra_rows =
                    case genesis do
                      %Commit{} = g -> commit_rows(g)
                      nil -> []
                    end ++ commit_rows(commit)

                  put_latest(state, commit.doc_uuid, commit.id, :put_built_commit, extra_rows)

                {:error, _reason} = error ->
                  error
              end

            _other ->
              :parent_moved
          end
        end)

      case cas_result do
        :ok ->
          emit_write_cpu(:put_built_commit, commit.doc_uuid, 0, 0, 0, persist_ns)

          :telemetry.execute(
            [:commonplace, :commit, :create],
            %{system_time: System.system_time()},
            %{doc_uuid: commit.doc_uuid}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "commits:#{commit.doc_uuid}",
            {:commit, commit.doc_uuid, commit.id, commit.metadata}
          )

          Phoenix.PubSub.broadcast(
            Commonplace.PubSub,
            "blue:#{commit.doc_uuid}",
            {:commit, commit.doc_uuid, commit.id, commit.metadata}
          )

          {:reply, {:ok, commit}, state}

        :parent_moved ->
          {:reply, {:error, :parent_moved}, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end)
  end

  # R4(a): hand a caller the live CubDB handle. O(1), no disk I/O — the cheap
  # fallback for resolve_db/1 when persistent_term has no entry for the given
  # server reference (e.g. a pid rather than the registered name).
  @impl true
  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  @impl true
  def handle_call(:get_trust_side_store, _from, state) do
    {:reply, state.trust_side_store, state}
  end

  @impl true
  def handle_call(:get_pending_imports, _from, state) do
    {:reply, state.pending_imports, state}
  end

  # execute_clean cache (CX-tdkq.27). Read also exposed as a remote-routable call
  # for clustered stores; writes are casts; flush is a call.
  @impl true
  def handle_call({:get_execute_clean, fp, commit_id}, _from, state) do
    {:reply, do_get_execute_clean(state.db, fp, commit_id), state}
  end

  @impl true
  def handle_call(:flush_execute_clean, _from, state) do
    # R4c carve-out: delegate to this instance's TrustSideStore companion —
    # it owns the execute_clean rows now. Synchronous on purpose (callers
    # need the guarantee stale verdicts are wiped before this returns).
    reply = Commonplace.Store.TrustSideStore.flush_execute_clean(state.trust_side_store)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:all_commit_ids_for_doc, doc_uuid}, _from, state) do
    {:reply, do_all_commit_ids_for_doc(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:doc_has_commit, doc_uuid, commit_id}, _from, state) do
    {:reply, do_doc_has_commit?(state.db, doc_uuid, commit_id), state}
  end

  @impl true
  def handle_call({:create_chained_commit, doc_uuid, update, metadata}, from, state) do
    handle_call(
      {:create_chained_commit, doc_uuid, update, metadata, []},
      from,
      state
    )
  end

  @impl true
  def handle_call(
        {:create_chained_commit, doc_uuid, update, metadata, opts},
        _from,
        state
      ) do
    instrumented(:create_chained_commit, doc_uuid, fn ->
      parent_id =
        case CubDB.get(state.db, {:latest, doc_uuid}) do
          nil -> nil
          commit_id -> commit_id
        end

      commit =
        do_write_commit(
          :create_chained_commit,
          state,
          doc_uuid,
          update,
          parent_id,
          metadata,
          opts
        )

      {:reply, commit, state}
    end)
  end

  @impl true
  def handle_call({:get_commit, commit_id}, _from, state) do
    {:reply, do_get_commit(state.db, commit_id), state}
  end

  @impl true
  def handle_call({:get_sla_tombstone_for_commit, commit_id}, _from, state) do
    reply =
      case CubDB.get(state.db, {:sla_tombstone_for_commit, commit_id}) do
        nil ->
          :none

        tombstone_id ->
          case CubDB.get(state.db, {:sla_tombstone, tombstone_id}) do
            nil ->
              {:error, {:sla_tombstone_index_corrupt, commit_id, tombstone_id}}

            tombstone ->
              case Commonplace.Store.SlaTombstone.verify(
                     tombstone,
                     Commonplace.Trust.config(),
                     store: state.name
                   ) do
                :ok -> {:ok, tombstone}
                {:error, reason} -> {:error, {:invalid_sla_tombstone, reason}}
              end
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_sla_tombstone_position, tombstone_id}, _from, state) do
    reply = Commonplace.Store.EvictionAuthorityLedger.tombstone_position(state.db, tombstone_id)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_eviction_anchor_activation_position, anchor_id}, _from, state) do
    reply =
      Commonplace.Store.EvictionAuthorityLedger.activation_position(state.db, anchor_id)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_eviction_anchor_activation, anchor_id}, _from, state) do
    reply = Commonplace.Store.EvictionAuthorityLedger.activation(state.db, anchor_id)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:activate_eviction_anchor, anchor_id, ratification_cid}, _from, state) do
    reply =
      with {:ok, _anchor} <- configured_eviction_anchor(Commonplace.Trust.config(), anchor_id),
           {:ok, position, rows} <-
             Commonplace.Store.EvictionAuthorityLedger.prepare_activation(
               state.db,
               anchor_id,
               ratification_cid
             ) do
        if rows != [], do: :ok = CubDB.put_multi(state.db, rows)
        {:ok, position}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_eviction_anchor_retirement_position, anchor_id}, _from, state) do
    reply =
      Commonplace.Store.EvictionAuthorityLedger.retirement_position(state.db, anchor_id)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:eviction_authority_position_before, first, second}, _from, state) do
    reply = Commonplace.Store.EvictionAuthorityLedger.before?(state.db, first, second)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:retire_eviction_anchor, anchor_id}, _from, state) do
    reply =
      with {:ok, _anchor} <- configured_eviction_anchor(Commonplace.Trust.config(), anchor_id),
           {:ok, position, rows} <-
             Commonplace.Store.EvictionAuthorityLedger.prepare_retirement(state.db, anchor_id) do
        if rows != [], do: :ok = CubDB.put_multi(state.db, rows)
        {:ok, position}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(
        {:store_sla_tombstone, %Commonplace.Store.SlaTombstone{} = tombstone},
        _from,
        state
      ) do
    result =
      case CubDB.get(state.db, {:sla_tombstone, tombstone.id}) do
        ^tombstone ->
          with :ok <-
                 Commonplace.Store.SlaTombstone.verify(
                   tombstone,
                   Commonplace.Trust.config(),
                   store: state.name
                 ),
               :ok <- ensure_tombstone_indexes_available(state.db, tombstone) do
            :ok
          end

        nil ->
          with {:ok, anchor} <-
                 Commonplace.Store.SlaTombstone.authorize_registration(
                   tombstone,
                   Commonplace.Trust.config(),
                   state.name
                 ),
               :ok <- ensure_tombstone_indexes_available(state.db, tombstone),
               {:ok, _position, ledger_rows} <-
                 Commonplace.Store.EvictionAuthorityLedger.prepare_registration(
                   state.db,
                   anchor.id,
                   tombstone.id
                 ) do
            index_rows =
              [{{:sla_tombstone, tombstone.id}, tombstone}] ++
                Enum.map(tombstone.commit_ids, fn commit_id ->
                  {{:sla_tombstone_for_commit, commit_id}, tombstone.id}
                end)

            :ok = CubDB.put_multi(state.db, ledger_rows ++ index_rows)
          end

        _other ->
          with {:ok, _anchor} <-
                 Commonplace.Store.SlaTombstone.authorize_registration(
                   tombstone,
                   Commonplace.Trust.config(),
                   state.name
                 ) do
            {:error, :sla_tombstone_id_collision}
          end
      end

    reply =
      case result do
        :ok -> :ok
        {:error, {:sla_tombstone_conflict, _commit_id, _existing_id}} = error -> error
        {:error, reason} -> {:error, {:invalid_sla_tombstone, reason}}
        other -> other
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:store_chit, %Commonplace.Store.Chit{} = chit}, _from, state) do
    # Gate first, write second (import_commit's posture): nothing about a
    # chit's fields is trustworthy until its claimed cid matches the hash
    # of its own content. Storing a mismatching chit under its forged key
    # would hand every future reader a value whose self-check can never
    # pass — refuse loudly instead of writing.
    reply =
      case Commonplace.Store.Chit.verify_cid(chit) do
        :ok ->
          # Idempotent by value: same cid = same content by construction,
          # so an overwrite of an existing row is a no-op. The write
          # touches ONLY the {:chit, cid} row — no {:latest} pointer, no
          # PubSub (see store_chit/2's doc for why that is load-bearing).
          :ok = CubDB.put(state.db, {:chit, chit.cid}, chit)
          {:ok, chit.cid}

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, state}
  end

  # Remote-compat shim (mirrors {:get_capability, cid}): local callers
  # take the pure point-read in get_chit/2; CommitStoreClient's remote
  # mode addresses this GenServer's registered name over BEAM
  # distribution and needs a handle_call shape to land on.
  @impl true
  def handle_call({:get_chit, cid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:chit, cid}) do
        nil -> :none
        chit -> {:ok, chit}
      end

    {:reply, reply, state}
  end

  # Remote-compat shim (mirrors :all_doc_uuids): local callers take the
  # pure range-read in all_chit_cids/1.
  @impl true
  def handle_call(:all_chit_cids, _from, state) do
    {:reply, do_all_chit_cids(state.db), state}
  end

  @impl true
  def handle_call({:latest_commit, doc_uuid}, _from, state) do
    {:reply, do_latest_commit(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:commit_log, doc_uuid, opts}, _from, state) do
    {:reply, do_commit_log(state.db, doc_uuid, opts), state}
  end

  @impl true
  def handle_call({:commit_log_from, commit_id, opts}, _from, state) do
    {:reply, do_commit_log_from(state.db, commit_id, opts), state}
  end

  @impl true
  def handle_call(:all_doc_uuids, _from, state) do
    {:reply, do_all_doc_uuids(state.db), state}
  end

  @impl true
  def handle_call({:all_doc_uuids_bounded, limit}, _from, state) do
    {:reply, do_all_doc_uuids_bounded(state.db, limit), state}
  end

  @impl true
  def handle_call(:bd_issue_doc_uuids, _from, state) do
    {:reply, do_bd_issue_doc_uuids(state.db), state}
  end

  @impl true
  def handle_call({:append_bd_issue_doc, doc_uuid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:latest, doc_uuid}) do
        nil ->
          {:error, :missing_doc}

        _commit_id ->
          CubDB.put(state.db, {:bd_issue_doc, doc_uuid}, true)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:append_bd_issue_doc_supersession, doc_uuid, reason}, _from, state) do
    key = {:bd_issue_doc_superseded, doc_uuid}

    reply =
      cond do
        CubDB.get(state.db, {:bd_issue_doc, doc_uuid}) != true ->
          {:error, :missing_issue_doc_row}

        is_nil(CubDB.get(state.db, key)) ->
          CubDB.put(state.db, key, reason)

        CubDB.get(state.db, key) == reason ->
          :ok

        true ->
          {:error, {:supersession_conflict, CubDB.get(state.db, key)}}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:is_ancestor, ancestor_id, descendant_id}, _from, state) do
    {:reply, do_is_ancestor(state.db, ancestor_id, descendant_id), state}
  end

  @impl true
  def handle_call({:set_latest, doc_uuid, commit_id}, _from, state) do
    put_latest(state, doc_uuid, commit_id, :set_latest)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:commit_ids_for_doc, doc_uuid}, _from, state) do
    {:reply, collect_commit_ids(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:accepted_heads_indexed, doc_uuid}, _from, state) do
    {:reply, do_accepted_heads_indexed(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:put_backfilled_accepted_heads, rows, backfill_state}, _from, state) do
    index_rows =
      Enum.map(rows, fn {doc_uuid, set} -> accepted_heads_backfill_row(doc_uuid, set) end)

    # Rows + the resume cursor land in ONE put_multi: a kill cannot leave
    # index rows written past the recorded cursor, so resume is exact and a
    # half-run never reads as :ready.
    CubDB.put_multi(state.db, index_rows ++ [{@accepted_head_index_state_key, backfill_state}])
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put_backfilled_doc_commit_index_rows, doc_uuid, commit_ids}, _from, state) do
    # Readiness is a precondition, not a side effect: rows land only
    # against a ready index, and the state key is never touched here
    # (readiness-gate hygiene, backfill brief acceptance 6).
    case CubDB.get(state.db, @doc_commit_index_state_key) do
      @doc_commit_index_ready ->
        rows = Enum.map(commit_ids, fn id -> {{:doc_commit, doc_uuid, id}, true} end)
        CubDB.put_multi(state.db, rows)
        {:reply, :ok, state}

      other ->
        {:reply, {:error, {:doc_commit_index_not_ready, other}}, state}
    end
  end

  @impl true
  def handle_call({:ensure_genesis, doc_uuid}, _from, state) do
    genesis = Commit.genesis(doc_uuid)
    put_bare_commit_with_index(state.db, genesis)
    {:reply, {:ok, genesis}, state}
  end

  @impl true
  def handle_call({:import_commit, commit}, from, state) do
    handle_call({:import_commit, commit, []}, from, state)
  end

  @impl true
  def handle_call({:import_commit, commit, opts}, _from, state) do
    instrumented(:import_commit, commit.doc_uuid, fn ->
      # CX-gwz: verify the claimed content address BEFORE trusting any
      # metadata on the commit — a hostile peer could retag a delta as
      # `%{kind: :snapshot}` and drive reconstruction to skip history.
      # Timed as part of the "validate" write_cpu phase (CX-9hql) —
      # federation/catch-up import bursts are the credible source of
      # rung-2 mailbox pressure, so import_commit's CPU share matters.
      {verify_result, verify_ns} = timed(fn -> Commonplace.Store.Commit.verify_id(commit) end)

      case verify_result do
        :ok ->
          handle_validated_import(commit, opts, state, verify_ns)

        {:error, {:id_mismatch, computed, claimed}} ->
          emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, verify_ns, 0)

          :telemetry.execute(
            [:commonplace, :commit, :rejected, :id_mismatch],
            %{system_time: System.system_time()},
            %{
              claimed_id: claimed,
              computed_id: computed,
              doc_uuid: commit.doc_uuid
            }
          )

          {:reply, {:error, {:id_mismatch, computed, claimed}}, state}
      end
    end)
  end

  @impl true
  def handle_call({:find_common_ancestor, uuid_a, uuid_b}, _from, state) do
    {:reply, do_find_common_ancestor(state.db, uuid_a, uuid_b), state}
  end

  @impl true
  def handle_call({:set_merge_point, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:merge_point, target_uuid, source_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_merge_point, target_uuid, source_uuid}, _from, state) do
    result = CubDB.get(state.db, {:merge_point, target_uuid, source_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_last_merge_commit, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:last_merge_commit, target_uuid, source_uuid}, commit_id)
    # Also store a target-only key so we can check "was this target merged from any source?"
    CubDB.put(state.db, {:latest_merge_head, target_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_latest_merge_head, target_uuid}, _from, state) do
    result = CubDB.get(state.db, {:latest_merge_head, target_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:store_attestation, doc_uuid, attestation}, _from, state) do
    CubDB.put_multi(state.db, [
      {{:attestation, attestation.id}, attestation},
      {{:latest_attestation, doc_uuid}, attestation.id}
    ])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:store_capability, %Commonplace.Trust.Capability{} = cap}, _from, state) do
    instrumented(:store_capability, nil, fn ->
      # R4c carve-out: delegate to this instance's TrustSideStore companion,
      # which owns the {:capability, cid} row and notifies PendingImports
      # (CX-tdkq.22e) once the cert is durably stored.
      reply = Commonplace.Store.TrustSideStore.store_capability(state.trust_side_store, cap)
      {:reply, reply, state}
    end)
  end

  @impl true
  def handle_call({:get_capability, cid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:capability, cid}) do
        nil -> :none
        cap -> {:ok, cap}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:store_revocation, %Commonplace.Trust.Revocation{} = rev}, _from, state) do
    # R4c carve-out shape: delegate to this instance's TrustSideStore
    # companion, which owns the {:revocation, cid} row + the :set_hash
    # watermark (atomic multi-put — see TrustSideStore's moduledoc).
    reply = Commonplace.Store.TrustSideStore.store_revocation(state.trust_side_store, rev)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_revocations, revoked_cid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:revocation, revoked_cid}) do
        nil -> []
        list -> list
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:revocation_set_hash, _from, state) do
    reply =
      case CubDB.get(state.db, {:revocation_meta, :set_hash}) do
        nil -> 0
        hash -> hash
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:latest_attestation, doc_uuid}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil ->
        {:reply, :none, state}

      att_id ->
        case CubDB.get(state.db, {:attestation, att_id}) do
          nil -> {:reply, :none, state}
          att -> {:reply, {:ok, att}, state}
        end
    end
  end

  @impl true
  def handle_call({:attestation_chain, doc_uuid, limit}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil ->
        {:reply, [], state}

      att_id ->
        chain = collect_attestation_chain(state.db, att_id, limit, [])
        {:reply, chain, state}
    end
  end

  # execute_clean watermark cache write (CX-tdkq.27) — fire-and-forget.
  # R4c carve-out: forwarded to TrustSideStore's own cast (cast-to-cast, so
  # this stays fire-and-forget end to end). A no-op if this instance's
  # TrustSideStore companion isn't running — same "lost write, recomputed on
  # next walk" tolerance the doc above already promises.
  @impl true
  def handle_cast({:put_execute_clean, fp, commit_id, bool}, state) do
    Commonplace.Store.TrustSideStore.put_execute_clean(
      state.trust_side_store,
      fp,
      commit_id,
      bool
    )

    {:noreply, state}
  end

  defp handle_validated_import(commit, opts, state, verify_ns) do
    {validation_result, validation_ns} = timed(fn -> import_validation(commit, opts, state) end)
    validate_ns = verify_ns + validation_ns

    case validation_result do
      :ok ->
        case CubDB.get(state.db, {:commit, commit.id}) do
          nil ->
            {state, persist_ns} = timed(fn -> do_store_imported(commit, state) end)
            emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, persist_ns)
            # R11 / R4c carve-out: a freshly-landed commit may be the
            # reference (or the cert) an earlier out-of-order arrival was
            # waiting on. Notify this instance's PendingImports companion
            # (a no-op when this instance has none configured — see
            # `maybe_notify_landed/2`); it re-submits its whole held queue
            # through THIS SAME import_commit/3 front door.
            maybe_notify_landed(state, commit.id)
            {:reply, :ok, state}

          _existing ->
            emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
            {:reply, :already_exists, state}
        end

      # CX-tdkq.22e: a commit awaiting its authorizing cert DEFERS (the cert
      # may land later), exactly like a namespace out-of-order reference.
      {:error, {:trust, :awaiting_capability}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
        maybe_enqueue_pending(state, commit, opts, :awaiting_capability)

        {:reply, {:error, {:trust_rejected, :awaiting_capability}}, state}

      # R1: other trust rejections are HARD — they never resolve by waiting.
      {:error, {:trust, reason}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)

        :telemetry.execute(
          [:commonplace, :commit, :rejected, :trust],
          %{system_time: System.system_time()},
          denial_metadata(:enforce, commit, reason)
        )

        {:reply, {:error, {:trust_rejected, reason}}, state}

      # CX-obfb: a delta-merge (merge_parents non-empty, or a
      # MergeSnapshotter-shaped 2+ element snapshot_parents) targeting a
      # code doc is a HARD reject — it never resolves by waiting, same
      # rationale as R1 trust rejections. The classifier is best-effort
      # content-sniffing (Commonplace.Trust.CodeDocHeuristic), so this is
      # defense-in-depth alongside the sibling-merge and explicit-merge
      # seams, not a substitute for Gate B.
      {:error, {:code_doc_delta_merge, _doc_uuid} = reason} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)

        :telemetry.execute(
          [:commonplace, :commit, :rejected, :code_doc_delta_merge],
          %{system_time: System.system_time()},
          %{doc_uuid: commit.doc_uuid, commit_id: commit.id}
        )

        {:reply, {:error, reason}, state}

      {:error, {:namespace, reason}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
        emit_namespace_rejection(commit, reason)
        # R11: hold the rejected commit and retry once its dependency lands.
        maybe_enqueue_pending(state, commit, opts, reason)
        {:reply, {:error, {:namespace_rejected, reason}}, state}
    end
  end

  # R4c carve-out: `state.pending_imports` is `nil` unless this instance was
  # started with an explicit companion (see `init/1`) — notably, always
  # non-nil when started via `Commonplace.Store.Supervisor`, always `nil`
  # for a standalone `CommitStore.start_link/1`. `nil` means "this instance
  # has no PendingImports companion," so these are no-ops rather than
  # addressing whatever process happens to be registered under the bare
  # `Commonplace.Store.PendingImports` module name (which, in a running
  # `Commonplace.Application` — including during the test suite — is a
  # REAL, unrelated singleton; silently talking to it would leak held
  # commits across otherwise-isolated test instances).
  defp maybe_notify_landed(%{pending_imports: nil}, _commit_id), do: :ok

  defp maybe_notify_landed(%{pending_imports: pending_imports}, commit_id),
    do: Commonplace.Store.PendingImports.notify_landed(pending_imports, commit_id)

  defp maybe_enqueue_pending(%{pending_imports: nil}, _commit, _opts, _reason), do: :ok

  defp maybe_enqueue_pending(%{pending_imports: pending_imports}, commit, opts, reason),
    do: Commonplace.Store.PendingImports.enqueue(pending_imports, commit, opts, reason)

  # The full import validation pipeline — trust gate, THEN the
  # no-delta-merge-on-code-docs guard, THEN namespace — run identically
  # by the initial import and the R11 retry, so a commit deferred for one
  # reason (e.g. an absent cert) is re-checked against ALL gates when it
  # is retried (never bypasses an earlier check).
  defp import_validation(commit, opts, state) do
    with :ok <- trust_check(commit, state),
         :ok <- code_doc_delta_merge_check(commit, state),
         :ok <- namespace_check(commit, opts, state) do
      :ok
    end
  end

  # CX-obfb: forbid delta-merges from landing on code docs. Gate B
  # (`Commonplace.Trust.authorized_to_execute?`) walks a doc's commit
  # chain via `parent_id` only, so a merge commit's `merge_parents`
  # side-line — or a MergeSnapshotter two-parent snapshot — is never
  # visited by the execute-authorization walk, even though its absorbed
  # bytes reach a compile read. Rather than teach the walk to traverse
  # merge edges, code-doc convergence is required to happen by
  # re-authorship instead: an `:execute`-authorized signer mints a
  # regular full-state commit.
  #
  # `state.name` (not the routing default) is threaded through so the
  # classifier's reconstruct read resolves THIS store's CubDB handle —
  # safe to call from inside this GenServer's own handle_call because
  # `reconstruct_snapshot` bottoms out in `resolve_db/1`, which reads a
  # `:persistent_term` handle directly rather than `GenServer.call`ing
  # back into this same (currently busy) process.
  defp code_doc_delta_merge_check(commit, state) do
    if delta_merge_shaped?(commit) and CodeDocHeuristic.code_doc?(commit.doc_uuid, state.name) do
      {:error, {:code_doc_delta_merge, commit.doc_uuid}}
    else
      :ok
    end
  end

  # A delta-merge commit is either:
  #   - a `:translate`-style merge: non-empty `merge_parents`, or
  #   - a MergeSnapshotter-style merge-snapshot: `metadata.snapshot_parents`
  #     carrying 2+ entries (the two-parent shape; a normal single-lineage
  #     snapshot carries exactly one).
  defp delta_merge_shaped?(%Commit{merge_parents: merge_parents}) when merge_parents != [],
    do: true

  defp delta_merge_shaped?(%Commit{metadata: %{snapshot_parents: snapshot_parents}})
       when is_list(snapshot_parents) and length(snapshot_parents) > 1,
       do: true

  defp delta_merge_shaped?(_commit), do: false

  defp trust_check(commit, state) do
    # Thread this store's own name so the phase-3 capability path fetches
    # certs from THIS db (not the routing default).
    case Commonplace.Trust.authorized?(
           commit,
           :write,
           {:doc, commit.doc_uuid},
           resolved_trust_config(state),
           state.name
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:trust, reason}}
    end
  end

  # ── CX-qat5.3: the local-write gate ──────────────────────────────────
  #
  # The third `Trust.authorized?` call-site family (Gate A gates
  # federation import, Gate B gates code execution — this gates every
  # LOCALLY-created commit at the CommitStore create seam, mirroring
  # import_validation's `trust_check/2` above: same verifier, same
  # `{:doc, doc_uuid}` scope, same store-name threading for the
  # deadlock-safety reasoning (phase-3 capability fetches must read via
  # `state.name`, never `GenServer.call` back into this store's own
  # mailbox).
  #
  # Three-position knob (`Application.get_env(:commonplace,
  # :local_write_gate, :dry_run)`):
  #
  #   * `:off`     — skip the check entirely (emergency escape hatch).
  #   * `:dry_run` — run the check; a would-deny is logged + given
  #     telemetry but the write still lands. DEFAULT — under the
  #     workspace's default permissive trust config `authorized?`
  #     returns `:ok` for everything, so this is a no-op observation
  #     window until a workspace flips `accept_unsigned: false` /
  #     pins identities.
  #   * `:enforce` — a would-deny is REJECTED: nothing is persisted,
  #     a red event fires on the doc's topic, and
  #     `{:error, {:trust_rejected, reason}}` is returned to the
  #     caller instead of the commit.
  #
  # Genesis commits (synthetic, unsigned, `kind: :genesis`) are exempt —
  # mirroring the exemption Gate B's `authorized_to_execute?` walk
  # already gives genesis. In practice the primary commit gated here is
  # never genesis-shaped (genesis rides ALONGSIDE a real commit as the
  # `built.genesis` / CAS `genesis` companion, never as the gated
  # struct itself) — this clause is a defensive backstop, and it is
  # exactly what makes "genesis rides only when the gated commit
  # passes" true: the companion genesis row is written in the SAME
  # `put_multi` as the gated commit, so it never lands independently of
  # whether the gate accepted the write it rode in with.
  defp local_write_gate_check(%Commit{metadata: %{kind: :genesis}}, _state, _opts), do: :ok

  defp local_write_gate_check(commit, state, opts) do
    # Workspace class-gating at this root-attach seam also class-gates the
    # auto-execution mint surface: a cell refuses __processes.json unless its
    # class explicitly declares that root entry. Keeping this before the trust
    # knob means `:local_write_gate = :off` cannot bypass workspace class.
    with :ok <-
           Commonplace.Workspace.RootWritePolicy.check(commit, state.name, state.data_dir) do
      trust_local_write_gate_check(commit, state, opts)
    else
      {:error, reason} ->
        Logger.warning(
          "CommitStore: root attach DENIED by workspace profile " <>
            "doc_uuid=#{commit.doc_uuid} reason=#{inspect(reason)}"
        )

        {:error, {:trust_rejected, reason}}
    end
  end

  defp trust_local_write_gate_check(commit, state, opts) do
    case resolved_local_write_gate(state) do
      :off ->
        :ok

      mode when mode in [:dry_run, :enforce] ->
        # CX-fogy: use `authorized_to_write?` (not a fixed `:write`) so a
        # CODE-content write FORKS the required capability by re-running the
        # safe-verb allowlist on the after-state — a valid sandboxed safe-verb
        # needs `:define_verb` (the citizen's home grant), raw/unsafe code needs
        # `:execute` (Gate-B, node-only), data needs `:write`. Fail-closed to
        # `:execute`. See `Trust.authorized_to_write?` for the interim layering
        # note + the (c)-refined destination.
        case Commonplace.Trust.authorized_to_write?(
               commit,
               {:doc, commit.doc_uuid},
               resolved_trust_config(state),
               state.name
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            handle_local_write_denial(mode, commit, reason, writer_identity(opts))
        end
    end
  end

  defp resolved_local_write_gate(%{local_write_gate: :ambient}),
    do: Commonplace.Trust.local_write_gate()

  defp resolved_local_write_gate(%{local_write_gate: gate})
       when gate in [:off, :dry_run, :enforce],
       do: gate

  defp resolved_trust_config(%{local_write_gate: :ambient}), do: Commonplace.Trust.config()

  defp resolved_trust_config(%{data_dir: data_dir}), do: Commonplace.Trust.config(data_dir)

  defp handle_local_write_denial(:dry_run, commit, reason, writer) do
    Logger.warning(
      "CommitStore: local write would be DENIED by trust gate (dry_run — write still lands) " <>
        "doc_uuid=#{commit.doc_uuid} commit_id=#{Base.encode16(commit.id, case: :lower)} " <>
        "reason=#{inspect(reason)} writer=#{inspect(writer)}"
    )

    Commonplace.Trust.DenialCounter.increment()

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      local_write_denial_metadata(:dry_run, commit, reason, writer)
    )

    :ok
  end

  defp handle_local_write_denial(:enforce, commit, reason, writer) do
    Logger.warning(
      "CommitStore: local write DENIED by trust gate (enforce) " <>
        "doc_uuid=#{commit.doc_uuid} commit_id=#{Base.encode16(commit.id, case: :lower)} " <>
        "reason=#{inspect(reason)} writer=#{inspect(writer)}"
    )

    Commonplace.Trust.DenialCounter.increment()

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      local_write_denial_metadata(:enforce, commit, reason, writer)
    )

    Commonplace.Dataflow.PubSub.broadcast_red(
      commit.doc_uuid,
      {:trust, :local_write_denied,
       %{doc_uuid: commit.doc_uuid, signer_id: commit.signer_id, reason: reason, writer: writer}}
    )

    {:error, {:trust_rejected, reason}}
  end

  # CX-t3xv §3 — the shape of a denial as it reaches the audit trail.
  #
  # HASH, NEVER PAYLOAD. `content_digest/1` is the only thing that ever
  # looks at `commit.update`, and it returns a sha256 + a byte count. A
  # denial record that carried the refused bytes would launder them into
  # the store through their own refusal record: the gate says no, and
  # then the audit of that "no" writes the content anyway. Refused by
  # construction, pinned by `AuditRecordShapeTest`.
  defp denial_metadata(mode, commit, reason) do
    %{
      mode: mode,
      doc_uuid: commit.doc_uuid,
      commit_id: commit.id,
      # Advisory: what the commit CLAIMED, not a verified principal.
      signer_id: commit.signer_id,
      cert_cids: cert_cids_of(commit),
      content_digest: Commonplace.Trust.AuditLog.content_digest(commit.update),
      reason: reason
    }
  end

  defp local_write_denial_metadata(mode, commit, reason, writer) do
    mode
    |> denial_metadata(commit, reason)
    |> Map.put(:writer, writer)
  end

  defp writer_identity(opts) do
    case Keyword.fetch(opts, :writer) do
      :error ->
        %{"status" => "not_provided"}

      {:ok, nil} ->
        %{"status" => "absent"}

      {:ok, {module, function}} when is_atom(module) and is_atom(function) ->
        %{
          "status" => "identified",
          "module" => inspect(module),
          "function" => Atom.to_string(function)
        }

      {:ok, invalid} ->
        %{"status" => "invalid", "value" => inspect(invalid)}
    end
  end

  # Cert-chain SUMMARY only — the leaf cid the commit presented, never
  # the certificate bodies.
  defp cert_cids_of(%Commit{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :capability_proof) do
      nil -> []
      cid -> [cid]
    end
  end

  defp cert_cids_of(_), do: []

  defp namespace_check(commit, opts, state) do
    case validator_for(opts, state).(commit) do
      :ok -> :ok
      {:error, reason} -> {:error, {:namespace, reason}}
    end
  end

  defp validator_for(opts, state) do
    Keyword.get(opts, :validator) ||
      fn c -> Commonplace.Store.Namespace.validate_commit_from_db(state.db, c) end
  end

  # Persist an imported commit. If the doc has no local :latest, point it
  # here; otherwise leave :latest alone (don't clobber a newer local head).
  defp do_store_imported(commit, state) do
    case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
      nil ->
        put_latest(state, commit.doc_uuid, commit.id, :imported_genesis, commit_rows(commit))

      _existing_latest ->
        # No head advance happens on this branch, so it deliberately does
        # NOT go through the choke: the commit is persisted as a sibling
        # off a shared ancestor and `:latest` is left where it was. An
        # advance dispatched here would alarm on a state nothing promoted.
        put_bare_commit_with_index(state.db, commit)
    end

    state
  end

  defp emit_namespace_rejection(commit, reason) do
    # CX-fbs6: a distinct event for reference-axis rejections so handlers can
    # tell which check caught the commit; the legacy :namespace_mismatch
    # event still fires as a catch-all so existing subscribers keep working.
    case reason do
      {:unknown_reference, outside} ->
        :telemetry.execute(
          [:commonplace, :commit, :rejected, :unknown_reference],
          %{system_time: System.system_time()},
          %{commit_id: commit.id, doc_uuid: commit.doc_uuid, outside: outside}
        )

      _ ->
        :ok
    end

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :namespace_mismatch],
      %{system_time: System.system_time()},
      %{commit_id: commit.id, doc_uuid: commit.doc_uuid, reason: reason}
    )
  end

  # ── R4(a): caller-side reads ─────────────────────────────────────────────
  #
  # These `do_*` functions hold the read logic so it can run either inside the
  # GenServer (the `handle_call` clauses above, used by remote/cross-version
  # clients via CommitStoreClient) or directly in the caller process (the
  # public functions, via resolve_db/1). Running in the caller means the
  # disk-bound CubDB btree traversal — which `CubDB.get/select` perform in the
  # calling process, not the CubDB GenServer — no longer queues behind a write
  # in this store's mailbox. Reads stay consistent: each CubDB.get takes its
  # own snapshot, exactly as before. Writes remain serialized here. (CX-tdkq.4)

  # ── CX-9hql (R4c rung-0): write-path telemetry helpers ──────────────────
  #
  # `instrumented/3` wraps a single WRITE-verb handle_call body so the
  # timing/mailbox-depth code isn't duplicated at every call site. It must
  # add negligible overhead on the hot path: no extra GenServer calls, no
  # cross-process work — `Process.info(self(), ...)` and
  # `System.monotonic_time/0` are both cheap same-process reads.

  defp instrumented(verb, doc_uuid, fun) do
    queue_len =
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end

    {result, duration} = timed(fun)

    :telemetry.execute(
      [:commonplace, :commit_store, :call],
      %{duration: duration, queue_len: queue_len},
      %{verb: verb, doc_uuid: doc_uuid}
    )

    result
  end

  # Time a zero-arg function, returning `{result, elapsed_native_time}`.
  defp timed(fun) do
    start = System.monotonic_time()
    result = fun.()
    {result, System.monotonic_time() - start}
  end

  # Every emission from this module runs inside the GenServer's
  # serialized section, hence `site: :server` (the rung-1 signal). The
  # hoisted caller-side build/sign timings are emitted by
  # `CommitStoreClient` with `site: :caller` (CX-3erd follow-up).
  defp emit_write_cpu(verb, doc_uuid, build_ns, sign_ns, validate_ns, persist_ns) do
    :telemetry.execute(
      [:commonplace, :commit_store, :write_cpu],
      %{build: build_ns, sign: sign_ns, validate: validate_ns, persist: persist_ns},
      %{verb: verb, doc_uuid: doc_uuid, site: :server}
    )
  end

  defp resolve_db(server) do
    case :persistent_term.get({__MODULE__, :db, server}, nil) do
      nil -> GenServer.call(server, :get_db)
      db -> db
    end
  end

  defp do_get_commit(db, commit_id) do
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> :none
      commit -> {:ok, commit}
    end
  end

  defp ensure_tombstone_indexes_available(db, tombstone) do
    Enum.reduce_while(tombstone.commit_ids, :ok, fn commit_id, :ok ->
      case CubDB.get(db, {:sla_tombstone_for_commit, commit_id}) do
        nil -> {:cont, :ok}
        existing_id when existing_id == tombstone.id -> {:cont, :ok}
        existing_id -> {:halt, {:error, {:sla_tombstone_conflict, commit_id, existing_id}}}
      end
    end)
  end

  defp configured_eviction_anchor(cfg, anchor_id) do
    case Map.get(cfg, :eviction_anchors, Map.get(cfg, "eviction_anchors", [])) do
      entries when is_list(entries) ->
        Enum.find_value(entries, {:error, :eviction_anchor_not_configured}, fn entry ->
          case Commonplace.Trust.EvictionAnchor.from_config(entry) do
            {:ok, %{id: ^anchor_id} = anchor} -> {:ok, anchor}
            _other -> nil
          end
        end)

      _other ->
        {:error, :invalid_eviction_anchor_config}
    end
  end

  defp do_get_execute_clean(db, fp, commit_id) do
    case CubDB.get(db, {:execute_clean, fp, commit_id}) do
      nil -> :miss
      bool when is_boolean(bool) -> {:ok, bool}
    end
  end

  defp do_latest_commit(db, doc_uuid) do
    # CX-o8tx: emit telemetry per latest_commit read so the reflog
    # amortization tests can prove that clean subtrees were short-circuited
    # without a read. Production cost is negligible when no handler is
    # attached.
    :telemetry.execute(
      [:commonplace, :commit, :latest_read],
      %{system_time: System.system_time()},
      %{doc_uuid: doc_uuid}
    )

    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      commit_id -> {:ok, CubDB.get(db, {:commit, commit_id})}
    end
  end

  defp do_commit_log(db, doc_uuid, opts) do
    limit = Keyword.get(opts, :limit, 100)

    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> []
      commit_id -> collect_log(db, commit_id, limit, [], walk_opts(opts))
    end
  end

  defp do_commit_log_from(db, commit_id, opts) do
    limit = Keyword.get(opts, :limit, 100)
    collect_log(db, commit_id, limit, [], walk_opts(opts))
  end

  defp walk_opts(opts), do: %{until_snapshot: Keyword.get(opts, :until_snapshot, false)}

  defp do_all_doc_uuids(db) do
    # CX-mg8s: same wrong bound as do_all_commit_ids_for_doc had. Not
    # currently firing — doc uuids are ASCII UUID strings, so the first
    # byte is a hex character and never 0xFF — but it is the identical
    # latent defect and would start dropping rows the moment a non-string
    # key is used here. Fixed rather than left as a trap.
    CubDB.select(db,
      min_key: {:latest, ""},
      max_key: {:latest, @max_key_binary}
    )
    |> Enum.map(fn {{:latest, uuid}, _commit_id} -> uuid end)
    |> MapSet.new()
  end

  # Chit cids are raw 32-byte sha256 binaries, so the CX-mg8s bound rule
  # applies: the upper bound must EXCEED every possible cid, and
  # @max_key_binary (64 bytes of 0xFF) does — a 32-byte cid of all-0xFF
  # is a PREFIX of it and therefore sorts lower.
  defp do_all_chit_cids(db) do
    CubDB.select(db,
      min_key: {:chit, <<>>},
      max_key: {:chit, @max_key_binary}
    )
    |> Enum.map(fn {{:chit, cid}, _chit} -> cid end)
  end

  defp do_all_doc_uuids_bounded(db, limit) do
    uuids =
      CubDB.select(db,
        min_key: {:latest, ""},
        max_key: {:latest, @max_key_binary}
      )
      |> Stream.map(fn {{:latest, uuid}, _commit_id} -> uuid end)
      |> Enum.take(limit + 1)

    if length(uuids) > limit do
      {:error, {:limit_exceeded, limit}}
    else
      {:ok, MapSet.new(uuids)}
    end
  end

  defp do_population_scan(db) do
    acc0 = %{
      p_latest: MapSet.new(),
      ids_from_structs: MapSet.new(),
      doc_commit_ids: %{}
    }

    # UNBOUNDED select — no min_key/max_key, so no range bound can truncate the
    # high end (plan #14155's common-mode concern). Route by key SHAPE via
    # `route_population_row/3`; ignore every other keyspace. This is a READ: the
    # routing lives in named function clauses rather than an inline `fn` whose
    # `{:latest}` clause would begin a line with `{{:latest,` and trip
    # `InvariantChokeTest`'s head-pointer-WRITE source scan (the R1 choke pin).
    db
    |> CubDB.select()
    |> Enum.reduce(acc0, fn {key, value}, acc -> route_population_row(key, value, acc) end)
  end

  # `{:commit, id}` is a 2-tuple (the struct); we take the KEY id and never look
  # at the value's `.doc_uuid`. `{:doc_commit}` rows are GROUPED per doc so
  # orphans can later be partitioned by their commit set (genesis-only vs
  # beyond-genesis — plan #14171/#14173). All three are READS of the keyspace.
  defp route_population_row({:commit, id}, _commit, acc) do
    %{acc | ids_from_structs: MapSet.put(acc.ids_from_structs, id)}
  end

  defp route_population_row({:doc_commit, doc_uuid, id}, _v, acc) do
    %{
      acc
      | doc_commit_ids:
          Map.update(acc.doc_commit_ids, doc_uuid, MapSet.new([id]), &MapSet.put(&1, id))
    }
  end

  defp route_population_row({:latest, doc_uuid}, _commit_id, acc) do
    %{acc | p_latest: MapSet.put(acc.p_latest, doc_uuid)}
  end

  defp route_population_row(_other_key, _value, acc), do: acc

  # Same shape as `do_population_scan/1`, and for the same reasons: one
  # UNBOUNDED select, routing by key SHAPE in NAMED function clauses rather
  # than an inline `fn`. The naming is not style — an inline clause would
  # begin a line with `{{:latest,` and trip `InvariantChokeTest`'s
  # head-pointer-WRITE source scan (the R1 choke pin) on what is a READ.
  defp do_import_population(db) do
    db
    |> CubDB.select()
    |> Enum.reduce(%{owned: MapSet.new(), heads: %{}}, fn {key, value}, acc ->
      route_import_row(key, value, acc)
    end)
  end

  defp route_import_row({:doc_commit, doc_uuid, _id}, _v, acc) do
    %{acc | owned: MapSet.put(acc.owned, doc_uuid)}
  end

  defp route_import_row({:latest, doc_uuid}, commit_id, acc) do
    %{acc | heads: Map.put(acc.heads, doc_uuid, commit_id)}
  end

  defp route_import_row(_other_key, _value, acc), do: acc

  defp do_bd_issue_doc_uuids(db) do
    CubDB.select(db,
      min_key: {:bd_issue_doc, ""},
      max_key: {:bd_issue_doc, @max_key_binary}
    )
    |> Enum.reduce(MapSet.new(), fn
      {{:bd_issue_doc, doc_uuid}, true}, acc -> MapSet.put(acc, doc_uuid)
    end)
  end

  defp do_bd_issue_doc_supersessions(db) do
    CubDB.select(db,
      min_key: {:bd_issue_doc_superseded, ""},
      max_key: {:bd_issue_doc_superseded, @max_key_binary}
    )
    |> Map.new(fn {{:bd_issue_doc_superseded, doc_uuid}, reason} -> {doc_uuid, reason} end)
  end

  # CX-mg8s: the upper bound must EXCEED every possible commit id, and
  # `<<255>>` does not. Commit ids are raw 32-byte binaries, and Erlang
  # compares binaries lexicographically with a shorter prefix sorting
  # LOWER — so `<<255>>` is a PREFIX of `<<255, ...31 more>>` and
  # therefore SMALLER than it. Every id beginning with byte 0xFF sorted
  # above the old bound and was silently skipped: ~1/256 of all commits,
  # measured live as 2 missing out of 1063 on a real doc. The bound
  # looked obviously correct, which is why it survived; a binary longer
  # than any id is the actual requirement.
  defp do_all_commit_ids_for_doc(db, doc_uuid) do
    case CubDB.get(db, @doc_commit_index_state_key) do
      @doc_commit_index_ready ->
        {ids, index_rows_read} =
          CubDB.select(db,
            min_key: {:doc_commit, doc_uuid, ""},
            max_key: {:doc_commit, doc_uuid, @max_key_binary}
          )
          |> Enum.reduce({MapSet.new(), 0}, fn
            {{:doc_commit, ^doc_uuid, id}, true}, {acc, count} ->
              {MapSet.put(acc, id), count + 1}
          end)

        # The readiness point-read above is part of this call's cost. Report it
        # alongside the range rows so acceptance measures the whole lookup.
        :telemetry.execute(
          [:commonplace, :commit_store, :doc_commit_index_read],
          %{rows_read: index_rows_read + 1, index_rows_read: index_rows_read},
          %{doc_uuid: doc_uuid}
        )

        ids

      state ->
        require Logger

        Logger.error(
          "CommitStore: doc commit index unavailable for doc_uuid=#{inspect(doc_uuid)}; " <>
            "state=#{inspect(state)}; refusing silent full-scan fallback"
        )

        raise "doc commit index unavailable for doc_uuid=#{inspect(doc_uuid)}: #{inspect(state)}"
    end
  end

  defp do_doc_has_commit?(db, doc_uuid, commit_id) do
    case CubDB.get(db, @doc_commit_index_state_key) do
      @doc_commit_index_ready ->
        CubDB.get(db, {:doc_commit, doc_uuid, commit_id}) == true

      state ->
        require Logger

        Logger.error(
          "CommitStore: doc commit index unavailable for doc_uuid=#{inspect(doc_uuid)}; " <>
            "state=#{inspect(state)}; refusing silent membership=false"
        )

        raise "doc commit index unavailable for doc_uuid=#{inspect(doc_uuid)}: #{inspect(state)}"
    end
  end

  defp do_is_ancestor(_db, nil, _descendant_id), do: false

  defp do_is_ancestor(db, ancestor_id, descendant_id),
    do: walk_ancestors(db, ancestor_id, descendant_id)

  defp do_find_common_ancestor(db, uuid_a, uuid_b) do
    ids_a = collect_commit_ids(db, uuid_a)
    walk_to_ancestor(db, uuid_b, ids_a)
  end

  # CX-3erd: the build/sign pipeline itself now lives in
  # `CommitBuilder.build/6` — the SAME implementation the caller-side
  # hoisted path (`CommitStoreClient`) uses. This retained
  # server-serialized path just calls it and persists inline (already
  # running inside this GenServer's handle_call, so no extra CAS is
  # needed — the mailbox itself is the serialization).
  # ── THE R1 CHOKE (CX-jfok) ───────────────────────────────────────────
  #
  # The ONE function in this codebase that writes `{:latest, doc_uuid}`.
  # Every head advance — every one, from any handler, on any path —
  # funnels through here. A NEW head-advance site MUST call this rather
  # than writing the pointer itself, and that is not a convention: the
  # source-scan test in
  # `test/commonplace/store/invariant_choke_test.exs` reads this file and
  # fails on any `{:latest, _}` write outside this function.
  #
  # Why a choke and not a list of call sites: per the 2026-08-05
  # resting-state invariants design (§4 build-shape item 2), an
  # enumeration of promoters is a claim that rots silently — "exactly N
  # sites" is true when counted and a further one arrives as silence. A
  # future promoter inherits validation by construction, the same move
  # Gate A made.
  #
  # `extra_rows` (commit rows, and the piggy-backed genesis row on the
  # paths that mint one) are written in the SAME `put_multi` as the head
  # pointer. That atomicity is the store's standing contract (see the
  # moduledoc): a commit row and the advance that promotes it land
  # together or not at all. Callers must therefore pass their rows here
  # rather than writing them separately around this call.
  #
  # The dispatch is a fire-and-forget cast to a NAME, deliberately: it is
  # the only thing added to the synchronous write path, it must never
  # raise into it, and it must never wait. Alarm-mode validation runs
  # out-of-GenServer and post-advance (§7 R2). Block-promotion, when it
  # exists, does NOT belong here in this shape — see
  # `Commonplace.Invariants.Dispatcher`'s moduledoc on R9.
  defp put_latest(state, doc_uuid, commit_id, source, extra_rows \\ []) do
    head_row = accepted_heads_row_for_advance(state.db, doc_uuid, commit_id, extra_rows)
    CubDB.put_multi(state.db, extra_rows ++ [head_row, {{:latest, doc_uuid}, commit_id}])
    dispatch_advance(state, doc_uuid, commit_id, source)
    :ok
  end

  # The accepted-head-set seam (advance side). Every `:latest` advance
  # goes through `put_latest/5`, so computing the new head row here means
  # all six advance sites maintain the frontier in the SAME put_multi that
  # moves `:latest` — no head-set write outside this seam and the bare
  # path below. The advancing commit dominates its parent and merge
  # parents, so the new frontier drops them and gains the new id. The
  # commit is in `extra_rows` for fresh writes and in the store for
  # `set_latest` (which passes none); if neither has it, the frontier
  # still gains the id and prunes nothing (the backfill reconciles).
  defp accepted_heads_row_for_advance(db, doc_uuid, commit_id, extra_rows) do
    dominated =
      case find_commit_in_rows(extra_rows, commit_id) || CubDB.get(db, {:commit, commit_id}) do
        nil -> MapSet.new()
        commit -> dominated_heads(commit)
      end

    accepted_heads_row(db, doc_uuid, commit_id, dominated)
  end

  # The accepted-head-set seam (bare-write side). `ensure_genesis` and
  # sibling `import_commit` persist commits without advancing `:latest`
  # (see `put_bare_commit_with_index/2`); both carry the full commit, so
  # the frontier delta is exact.
  defp accepted_heads_row_bare(db, commit) do
    accepted_heads_row(db, commit.doc_uuid, commit.id, dominated_heads(commit))
  end

  # (old_frontier − dominated) ∪ {new_id}. One row per doc holds the whole
  # small frontier, so the update is a single put — atomic with the
  # accompanying `:latest`/commit rows in the caller's put_multi.
  defp accepted_heads_row(db, doc_uuid, new_id, dominated) do
    old = CubDB.get(db, {:accepted_heads, doc_uuid}) || MapSet.new()
    new = old |> MapSet.difference(dominated) |> MapSet.put(new_id)
    {{:accepted_heads, doc_uuid}, new}
  end

  # BUILD-1 §3 backfill: the FULL-set write path (vs accepted_heads_row's
  # incremental delta). The backfill derives a doc's whole frontier
  # (`AcceptedHeads.of/2`) and writes it directly. Choke-sanctioned
  # alongside `accepted_heads_row` — see `accepted_heads_choke_test`'s
  # allowlist. Never used on the hot path; only by the one-time backfill.
  defp accepted_heads_backfill_row(doc_uuid, set), do: {{:accepted_heads, doc_uuid}, set}

  defp dominated_heads(commit) do
    [commit.parent_id | commit.merge_parents || []]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp find_commit_in_rows(extra_rows, commit_id) do
    Enum.find_value(extra_rows, fn
      {{:commit, ^commit_id}, commit} -> commit
      _ -> nil
    end)
  end

  # Every `{:commit, _}` row in this store is produced here with its index
  # row structurally attached. Writers consume this pair as a unit; the index
  # is derived from the row, never from a head advance's subject.
  defp commit_rows(%{id: id, doc_uuid: doc_uuid} = commit) do
    rows = [{{:commit, id}, commit}, {{:doc_commit, doc_uuid, id}, true}]

    if Map.get(commit.metadata, :bd_issue_doc_created) == true do
      rows ++ [{{:bd_issue_doc, doc_uuid}, true}]
    else
      rows
    end
  end

  # `ensure_genesis` and sibling import deliberately remain bare commit
  # writes. The marker covers their only non-atomic risk: a process crash
  # between writing the commit and its attached index row. Missing call sites
  # are covered structurally by commit_rows/1, not inferred from this marker.
  defp put_bare_commit_with_index(db, commit) do
    [commit_row | attached_rows] = commit_rows(commit)

    CubDB.put(
      db,
      @doc_commit_index_state_key,
      {:dirty, @doc_commit_index_version, commit.doc_uuid}
    )

    CubDB.put(db, elem(commit_row, 0), elem(commit_row, 1))

    CubDB.put_multi(
      db,
      attached_rows ++
        [
          accepted_heads_row_bare(db, commit),
          {@doc_commit_index_state_key, @doc_commit_index_ready}
        ]
    )
  end

  defp ensure_doc_commit_index(db) do
    case CubDB.get(db, @doc_commit_index_state_key) do
      @doc_commit_index_ready -> :ok
      prior_state -> rebuild_doc_commit_index(db, prior_state)
    end
  end

  defp rebuild_doc_commit_index(db, prior_state) do
    require Logger

    CubDB.put(
      db,
      @doc_commit_index_state_key,
      {:rebuilding, @doc_commit_index_version, prior_state}
    )

    removed_index_rows = delete_doc_commit_index_rows(db)

    {pending, _pending_count, commit_count, doc_uuids} =
      CubDB.select(db,
        min_key: {:commit, ""},
        max_key: {:commit, @max_key_binary}
      )
      |> Enum.reduce({[], 0, 0, MapSet.new()}, fn
        {{:commit, id}, %{doc_uuid: doc_uuid}}, {pending, pending_count, count, docs} ->
          row = {{:doc_commit, doc_uuid, id}, true}
          pending = [row | pending]
          pending_count = pending_count + 1

          if pending_count == @doc_commit_index_backfill_chunk do
            CubDB.put_multi(db, pending)
            {[], 0, count + 1, MapSet.put(docs, doc_uuid)}
          else
            {pending, pending_count, count + 1, MapSet.put(docs, doc_uuid)}
          end
      end)

    if pending != [], do: CubDB.put_multi(db, pending)

    # Rebuild-completeness (plan #14426): the struct pass above derives
    # rows from `.doc_uuid` — a first-writer trace, wrong for fork
    # lineage — so a rebuild that stopped here would ERASE the
    # chain-derived membership the (a) backfill wrote and silently
    # manufacture the doctrine violation back. The index's definition
    # includes chain membership from `:latest`; a rebuild must reproduce
    # ALL of it. Runs before the ready flip: ready means complete.
    {:ok, _chain_report} = Commonplace.Store.DocCommitBackfill.run_on_db(db)

    CubDB.put(db, @doc_commit_index_state_key, @doc_commit_index_ready)

    if commit_count > 0 or prior_state != nil do
      Logger.warning(
        "CommitStore: doc commit index #{index_state_label(prior_state)}; " <>
          "startup backfill repaired commit_rows=#{commit_count} " <>
          "doc_uuids=#{MapSet.size(doc_uuids)} removed_index_rows=#{removed_index_rows} " <>
          "scope=entire_commit_range"
      )
    end

    :ok
  end

  defp index_state_label(nil), do: "missing"
  defp index_state_label(state), do: "interrupted (state=#{inspect(state)})"

  defp delete_doc_commit_index_rows(db) do
    CubDB.select(db,
      min_key: {:doc_commit, "", ""},
      max_key: {:doc_commit, @max_key_binary, @max_key_binary}
    )
    |> Stream.map(fn {key, _value} -> key end)
    |> Stream.chunk_every(@doc_commit_index_backfill_chunk)
    |> Enum.reduce(0, fn keys, count ->
      CubDB.delete_multi(db, keys)
      count + length(keys)
    end)
  end

  defp dispatch_advance(%{invariant_dispatcher: nil}, _doc_uuid, _commit_id, _source), do: :ok

  defp dispatch_advance(%{invariant_dispatcher: dispatcher}, doc_uuid, commit_id, source) do
    # `GenServer.cast/2` to an unregistered name is already a no-op, and
    # to a live one it never blocks. The rescue/catch is for the residue:
    # a `:global`/`:via` tuple whose registry is down raises, and a
    # head-advance must not fail because the alarm's mailbox is missing.
    GenServer.cast(
      dispatcher,
      {:advance, %{doc_uuid: doc_uuid, commit_id: commit_id, source: source}}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # A store started before this field existed (or by a hand-rolled state
  # map in a test) simply does not dispatch.
  defp dispatch_advance(_state, _doc_uuid, _commit_id, _source), do: :ok

  defp do_write_commit(verb, state, doc_uuid, update, parent_id, metadata, opts) do
    built = CommitBuilder.build(state.db, doc_uuid, update, parent_id, metadata, opts)

    # CX-qat5.3: local-write gate — post-build/sign (the commit id and
    # signature are final), pre-persist. Mirrors import_validation's
    # trust_check (see that function below); see local_write_gate_check/3
    # for the knob semantics and genesis exemption.
    case local_write_gate_check(built.commit, state, opts) do
      :ok ->
        {_, persist_ns} =
          timed(fn ->
            extra_rows =
              case built.genesis do
                %Commit{} = g -> commit_rows(g)
                nil -> []
              end ++ commit_rows(built.commit)

            put_latest(state, doc_uuid, built.commit.id, :write_commit, extra_rows)
          end)

        emit_write_cpu(verb, doc_uuid, built.build_ns, built.sign_ns, 0, persist_ns)

        :telemetry.execute(
          [:commonplace, :commit, :create],
          %{system_time: System.system_time()},
          %{doc_uuid: doc_uuid}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "commits:#{doc_uuid}",
          {:commit, doc_uuid, built.commit.id, built.commit.metadata}
        )

        # Also broadcast on the blue:UUID topic so UI subscribers (WikiLive,
        # TreeLive) see live updates from CommandRouter-initiated writes (MCP,
        # CLI) — not just edits that already flow through Document.Server.
        # CX-4im. Eventually the blue/commits topic duality should be unified;
        # see the CX-4im notes for the refactor plan.
        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "blue:#{doc_uuid}",
          {:commit, doc_uuid, built.commit.id, built.commit.metadata}
        )

        built.commit

      {:error, _reason} = error ->
        emit_write_cpu(verb, doc_uuid, built.build_ns, built.sign_ns, 0, 0)
        error
    end
  end

  defp collect_commit_ids(db, doc_uuid) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> MapSet.new()
      commit_id -> collect_ids(db, commit_id, MapSet.new())
    end
  end

  defp collect_ids(_db, nil, acc), do: acc

  defp collect_ids(db, commit_id, acc) do
    acc = MapSet.put(acc, commit_id)

    case CubDB.get(db, {:commit, commit_id}) do
      nil -> acc
      commit -> collect_ids(db, commit.parent_id, acc)
    end
  end

  defp walk_to_ancestor(db, doc_uuid, ancestor_ids) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      commit_id -> find_in_chain(db, commit_id, ancestor_ids)
    end
  end

  defp find_in_chain(_db, nil, _ids), do: :none

  defp find_in_chain(db, commit_id, ancestor_ids) do
    if MapSet.member?(ancestor_ids, commit_id) do
      {:ok, CubDB.get(db, {:commit, commit_id})}
    else
      case CubDB.get(db, {:commit, commit_id}) do
        nil -> :none
        commit -> find_in_chain(db, commit.parent_id, ancestor_ids)
      end
    end
  end

  defp collect_attestation_chain(_db, nil, _limit, acc), do: Enum.reverse(acc)
  defp collect_attestation_chain(_db, _id, 0, acc), do: Enum.reverse(acc)

  defp collect_attestation_chain(db, att_id, limit, acc) do
    case CubDB.get(db, {:attestation, att_id}) do
      nil -> Enum.reverse(acc)
      att -> collect_attestation_chain(db, att.prev_attestation_id, limit - 1, [att | acc])
    end
  end

  defp collect_log(_db, nil, _limit, acc, _w), do: Enum.reverse(acc)
  defp collect_log(_db, _id, 0, acc, _w), do: Enum.reverse(acc)

  defp collect_log(db, commit_id, limit, acc, w) do
    case CubDB.get(db, {:commit, commit_id}) do
      nil ->
        Enum.reverse(acc)

      commit ->
        acc = [commit | acc]

        # CX-ggdv: `until_snapshot` stops the walk AT the snapshot,
        # inclusive. The snapshot is a self-contained state encoding, so
        # its ancestors are unreachable-by-construction for any reader
        # that trims to the latest snapshot — fetching them is pure cost.
        if w.until_snapshot and snapshot_commit?(commit) do
          Enum.reverse(acc)
        else
          collect_log(db, commit.parent_id, limit - 1, acc, w)
        end
    end
  end

  defp snapshot_commit?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :snapshot} -> true
      _ -> false
    end
  end

  defp walk_ancestors(_db, _ancestor_id, nil), do: false

  defp walk_ancestors(db, ancestor_id, current_id) do
    case CubDB.get(db, {:commit, current_id}) do
      nil ->
        false

      commit ->
        cond do
          commit.parent_id == ancestor_id -> true
          commit.parent_id == nil -> false
          true -> walk_ancestors(db, ancestor_id, commit.parent_id)
        end
    end
  end

  # CX-xrds: deepened from the original take-1 probe. Streams every
  # entry (touching each key cheaply — no deserialization beyond what
  # `CubDB.select` already forces) so corruption located anywhere in the
  # file is caught, not just at the head. Bounded by TIME, not count,
  # via `Application.get_env(:commonplace, :corruption_probe_timeout_ms,
  # 5_000)`: a raise during the scan is real corruption, but a timeout
  # just means the store is large — we favor availability and treat a
  # timed-out (partial) scan as healthy rather than lossily archiving a
  # store that may be fine. See the moduledoc "CubDB crash recovery"
  # section for the full rationale.
  defp probe_integrity(db) do
    timeout_ms = Application.get_env(:commonplace, :corruption_probe_timeout_ms, 5_000)
    started_at = System.monotonic_time(:millisecond)
    entries_walked = :atomics.new(1, signed: false)

    task =
      Task.async(fn ->
        try do
          db
          |> CubDB.select()
          |> Enum.each(fn {_key, _value} -> :atomics.add_get(entries_walked, 1, 1) end)

          :ok
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    result =
      if timeout_ms == 0 do
        # A configured zero budget is useful for deterministic fixture tests and
        # means exactly what it says: do not wait for any scan work to finish.
        Task.shutdown(task, :brutal_kill)
        nil
      else
        Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    walked = :atomics.get(entries_walked, 1)

    case result do
      {:ok, :ok} ->
        require Logger

        Logger.info(
          "CubDB integrity probe completed: entries_walked=#{walked} " <>
            "elapsed_ms=#{elapsed_ms} budget_ms=#{timeout_ms}; coverage complete"
        )

        :ok

      {:ok, {:error, _reason} = error} ->
        error

      nil ->
        require Logger

        Logger.warning(
          "CubDB integrity probe cut short: entries_walked=#{walked} " <>
            "elapsed_ms=#{elapsed_ms} budget_ms=#{timeout_ms}; covered fraction UNKNOWN — " <>
            "this is a LOWER BOUND on work done, not a percentage; treating store as healthy"
        )

        :ok
    end
  end

  defp archive_corrupt_db(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    archive_path = "#{path}.corrupt.#{timestamp}"
    File.rename!(path, archive_path)
    File.mkdir_p!(path)
    archive_path
  end

  # CX-hoj: the CAS write paths (`write_snapshot_cas/5`,
  # `write_prebuilt_commit_cas/2`) call `maybe_sign_commit/1` with no
  # context deliberately — today only node-signed system kinds
  # (`:snapshot`/`:merge`) route through them. If a commit of any other
  # kind reaches one of these bare calls, it would silently inherit
  # ambient identity (global key or node key) with no per-call
  # signing_context to say otherwise. Surface that loudly instead.
  defp warn_if_non_system_cas(%Commit{metadata: metadata, doc_uuid: doc_uuid, id: id}, via)
       when via in [:snapshot_cas, :prebuilt_cas] do
    kind = Map.get(metadata, :kind)

    unless kind in [:snapshot, :merge] do
      Logger.warning(
        "CommitStore: non-system-kind commit (kind=#{inspect(kind)}) reached #{via} " <>
          "unsigned-context CAS path — this path is meant only for node-signed " <>
          "system commits (doc_uuid=#{doc_uuid})"
      )

      :telemetry.execute(
        [:commonplace, :commit, :ambient_signed],
        %{system_time: System.system_time()},
        %{doc_uuid: doc_uuid, commit_id: id, via: :cas}
      )
    end

    :ok
  end

  # CX-3erd: signing itself now lives in `CommitBuilder.maybe_sign_commit/2`
  # — the SAME implementation `do_write_commit/6` (via `CommitBuilder.build/6`)
  # and the caller-side hoisted path both use. The CAS write paths keep
  # calling it directly (bare, no signing_context) since they sit above
  # this build pipeline (see the module-level "Signing" section).
  defp maybe_sign_commit(commit), do: CommitBuilder.maybe_sign_commit(commit)
end
