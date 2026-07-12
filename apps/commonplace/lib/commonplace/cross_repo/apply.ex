defmodule Commonplace.CrossRepo.Apply do
  @moduledoc """
  Cross-repo B2 — Seam C: the editorial APPLY GATE (spec §0, §1 "Seam C", §3
  LBD-2/3/4, §4.3, §6).

  A merge-request (`Commonplace.CrossRepo.MergeRequest`) is INERT DATA — a
  signed PROPOSAL, not a capability. On its own it changes nothing about A's
  document. This module is the ONE place A turns an accepted proposal into an
  edit, and it does so as **an ordinary A-write**: A verifies WHO sent the
  proposal (attribution), then re-authors the embodied delta as A's OWN signed
  commit through A's NORMAL write path. Two cleanly-separated judgments (spec
  §5): *who sent this* (B's carried signature vs the key A pinned for B) ⟂ *may
  this content be written* (A's own write-gate on the after-content).

  ## The two load-bearing properties

    1. **THE BINDING (attribution is trustworthy).** The proposer's expected
       public key is resolved SERVER-SIDE from A's OWN pinned config —
       `Commonplace.Trust.config/0`'s `trusted_identities[mr.proposer_id]` (the
       key A pinned for B, exactly like Slice-0's server-resolved audience
       binding). The pubkey is NEVER taken from the proposal itself or any
       caller-claimed value. If A has not pinned `mr.proposer_id`,
       `{:error, :unknown_proposer}` — A only applies proposals from roots it
       explicitly trusts. A signature that does not verify against the pinned
       key → `{:error, :bad_proposal}`.

    2. **THE APPLY = AN ORDINARY A-WRITE (no bespoke gate — LBD-2).** On a
       verified proposal, A reconstructs the target, applies `mr.delta` as a
       Yjs update on A's CURRENT head, and authors A's own commit via
       `CommitStoreClient.create_chained_commit/5`, signed by A's identity under
       A's write-cert (`Commonplace.MUD.SignedWrite.opts_for/2`). This is the
       SAME path `Move`/`VerbSource`/the outbox use, so Gate A, the
       `LocalWriteGate`, and the RCE code-doc classifier all fire UNCHANGED —
       B cannot smuggle privilege through a proposal any more than A could grant
       it to itself by typing. If A's write-gate refuses the apply (e.g. the
       delta would mint a code/verb doc and A lacks `:execute`), that refusal is
       returned verbatim and the proposal is NOT marked applied. We never sign
       as B, never thread B's identity as authority.

  ## Provenance (advisory, not authority — spec §1 Seam C, LBD)

  The applied commit's metadata carries `%{cross_repo_proposer: mr.proposer_id}`
  — attribution only (the principal-vs-hand distinction). The SIGNER and the
  authority are A; the field merely names where the content came from.

  ## Idempotency (LBD-4)

  A proposal is content-addressed (`proposal_id/1` = SHA-256 of
  `MergeRequest.to_wire/1`). An applied-set — a public named ETS table keyed by
  `{store, proposal_id}` — records what has already been applied, so re-reading
  the same proposal from B's replicated outbox does NOT double-write. A repeat
  returns `{:ok, :already_applied}` without a second commit.
  """

  alias Commonplace.CrossRepo.{MergeRequest, Outbox}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust

  @applied_table :cross_repo_applied_proposals

  @doc """
  Editorial APPLY of a verified merge-request.

    * `mr` — the signed `%MergeRequest{}` to apply.
    * `a_signing_context` — A's OWN `%SigningContext{}` (A's identity + key).
      The commit is authored and signed by THIS context — never by B.
    * `store` — the commit store (name or pid), default `CommitStoreClient`.
    * `opts`:
        * `:cert_cids` — A's held capability CIDs, threaded to
          `SignedWrite.opts_for/2` so the apply carries A's write-cert.
        * `:trust_config` — override the pinned-config used for the binding
          (defaults to `Trust.config/0`; A's real pinned anchors).

  Returns:
    * `{:ok, commit}` on a fresh apply (one new A-signed commit on the target),
    * `{:ok, :already_applied}` on a repeat (no second commit),
    * `{:error, :unknown_proposer}` if A has not pinned `mr.proposer_id`,
    * `{:error, :bad_proposal}` if the signature does not verify against the
      pinned key,
    * `{:error, reason}` if A's own write-gate refuses the re-authored commit
      (the RCE/write fence firing exactly as for a hand edit).
  """
  @spec apply_proposal(MergeRequest.t(), SigningContext.t(), term(), keyword()) ::
          {:ok, Commonplace.Store.Commit.t()} | {:ok, :already_applied} | {:error, atom() | tuple()}
  def apply_proposal(
        %MergeRequest{} = mr,
        %SigningContext{} = a_signing_context,
        store \\ CommitStoreClient,
        opts \\ []
      ) do
    cfg = Keyword.get(opts, :trust_config) || Trust.config()

    with {:ok, pinned_keys} <- resolve_pinned_keys(cfg, mr.proposer_id),
         :ok <- verify_or_refuse(mr, pinned_keys) do
      pid = proposal_id(mr)

      if already_applied?(store, pid) do
        {:ok, :already_applied}
      else
        case author_apply_commit(mr, a_signing_context, store, opts) do
          %Commonplace.Store.Commit{} = commit ->
            mark_applied(store, pid)
            {:ok, commit}

          {:error, _reason} = error ->
            # A's OWN write-gate (or CAS) refused the re-authored commit. Do NOT
            # mark applied — the proposal was not written. Surface the refusal.
            error
        end
      end
    end
  end

  @doc """
  Editorial REJECT: record the proposal id in the rejected-set and touch the
  target NOT AT ALL. Minimal by design (spec §3 LBD-4 — reject → no commit).
  Returns `:ok`.
  """
  @spec reject(MergeRequest.t(), term(), keyword()) :: :ok
  def reject(%MergeRequest{} = mr, store \\ CommitStoreClient, _opts \\ []) do
    ensure_table()
    :ets.insert(@applied_table, {{store_key(store), {:rejected, proposal_id(mr)}}, true})
    :ok
  end

  @doc """
  Thin editorial entry point: list every proposal in `outbox_uuid` and, per the
  caller's `decision_fn.(mr) :: :accept | :reject`, apply or reject each.

  Returns a list of `{mr, result}` in outbox order — the human-curated CLI is
  the intended surface, but this makes the accept/reject loop scriptable for
  tests and agents. (A full CLI command is a follow-up, not this run.)
  """
  @spec review(String.t(), (MergeRequest.t() -> :accept | :reject), SigningContext.t(), term(), keyword()) ::
          [{MergeRequest.t(), term()}]
  def review(outbox_uuid, decision_fn, %SigningContext{} = a_signing_context, store \\ CommitStoreClient, opts \\ [])
      when is_binary(outbox_uuid) and is_function(decision_fn, 1) do
    outbox_uuid
    |> Outbox.list(store)
    |> Enum.map(fn mr ->
      result =
        case decision_fn.(mr) do
          :accept -> apply_proposal(mr, a_signing_context, store, opts)
          :reject -> reject(mr, store, opts)
        end

      {mr, result}
    end)
  end

  @doc """
  Stable, content-addressed id of a proposal — SHA-256 of its full wire form
  (`MergeRequest.to_wire/1`, which includes the signature). The idempotency key.
  """
  @spec proposal_id(MergeRequest.t()) :: binary()
  def proposal_id(%MergeRequest{} = mr) do
    :crypto.hash(:sha256, MergeRequest.to_wire(mr))
  end

  # ── THE BINDING — pinned pubkey resolved from A's OWN config ─────────────
  #
  # `trusted_identities` values are base64-encoded raw keys (a single string or
  # a list of them — `Trust.verify_against_pinned/2` accepts both). Decode to
  # raw bytes for `MergeRequest.verify/2`. An unpinned proposer, or a pin that
  # decodes to nothing, is `:unknown_proposer` — A refuses to attribute.
  defp resolve_pinned_keys(cfg, proposer_id) do
    case Map.fetch(cfg.trusted_identities, proposer_id) do
      {:ok, pinned} ->
        keys =
          pinned
          |> List.wrap()
          |> Enum.flat_map(fn encoded ->
            case Signing.decode_key(encoded) do
              {:ok, key} -> [key]
              {:error, _} -> []
            end
          end)

        case keys do
          [] -> {:error, :unknown_proposer}
          _ -> {:ok, keys}
        end

      :error ->
        {:error, :unknown_proposer}
    end
  end

  defp verify_or_refuse(%MergeRequest{} = mr, pinned_keys) do
    if Enum.any?(pinned_keys, fn key -> MergeRequest.verify(mr, key) == :ok end) do
      :ok
    else
      {:error, :bad_proposal}
    end
  end

  # ── THE APPLY — an ordinary A-write through the normal signed-write path ──
  defp author_apply_commit(%MergeRequest{} = mr, a_signing_context, store, opts) do
    doc = load_target(mr.target_uuid, store)
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, mr.delta)
    update = Yelixer.Encoding.encode_update(doc)

    cert_cids = Keyword.get(opts, :cert_cids, [])

    {metadata, commit_opts} =
      SignedWrite.opts_for(mr.target_uuid,
        signing_context: a_signing_context,
        cert_cids: cert_cids,
        store: store
      )

    # Advisory provenance — attribution, NOT authority. A non-empty metadata map
    # requires a `:kind` tag (`Store.Commit`); the no-cert branch of `opts_for`
    # leaves metadata `%{}`, so stamp `:regular` unless a capability_proof
    # already set it.
    metadata =
      metadata
      |> Map.put(:cross_repo_proposer, mr.proposer_id)
      |> Map.put_new(:kind, :regular)

    CommitStoreClient.create_chained_commit(store, mr.target_uuid, update, metadata, commit_opts)
  end

  # Reconstruct the target's CURRENT head into a fresh Yjs doc (LBD-3:
  # apply-on-HEAD; `base_cid` is recorded on the proposal for A's review, not a
  # gate). Mirrors `Outbox.load_doc/2` / `RedLog.load/2`: apply the latest
  # commit's (full-state) update; a nonexistent doc yields an empty doc.
  defp load_target(uuid, store) do
    doc = Yelixer.Doc.new()

    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        doc
    end
  end

  # ── Applied-set (idempotency) ────────────────────────────────────────────
  defp already_applied?(store, proposal_id) do
    ensure_table()
    :ets.member(@applied_table, {store_key(store), proposal_id})
  end

  defp mark_applied(store, proposal_id) do
    ensure_table()
    :ets.insert(@applied_table, {{store_key(store), proposal_id}, true})
    :ok
  end

  # Lazily create the public named table; a concurrent creator loses the race
  # with an ArgumentError, which we swallow (the table already exists).
  defp ensure_table do
    case :ets.whereis(@applied_table) do
      :undefined ->
        try do
          :ets.new(@applied_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end

    @applied_table
  end

  defp store_key(store), do: store
end
