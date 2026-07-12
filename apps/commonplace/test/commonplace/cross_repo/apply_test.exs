defmodule Commonplace.CrossRepo.ApplyTest do
  @moduledoc """
  B2 Seam-C: the editorial APPLY GATE (spec §6). Proves the trust seams:

    * NO-AUTHORITY — a proposal alone changes target X by nothing.
    * THE BINDING — the proposer pubkey is server-resolved by A (the key of the
      peer whose outbox the proposal came from) and supplied to the apply gate;
      a nil source key / a sig that doesn't verify against the supplied key is
      refused. It is NEVER taken from the proposal.
    * APPLY = ORDINARY A-WRITE — accept yields exactly ONE new commit, signed by
      A (not B), whose content reflects the delta; runs under
      `local_write_gate: :enforce` with A holding authority.
    * PROVENANCE — the commit carries `mr.proposer_id` advisory; authority is A.
    * IDEMPOTENCY — applying twice yields one commit + `{:ok, :already_applied}`.

  Uses the in-process `Store.Supervisor` (mirrors LocalWriteGateTest) so the
  enforce/CAS write path has its companion stores; no Phoenix serve is booted.
  """
  use ExUnit.Case, async: false

  alias Commonplace.CrossRepo.{Apply, MergeRequest, Outbox}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_b2_apply_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"b2_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"b2_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"b2_tss_#{n}",
       pending_imports_name: :"b2_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      restore(:trust, old_trust)
      restore(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    # A — the disposing repo (authors the apply).
    {a_pub, a_priv} = Signing.generate_keypair()
    a_identity = "aaaaaaaa-0000-0000-0000-000000000001"
    a_ctx = %SigningContext{identity_uuid: a_identity, private_key: a_priv, public_key: a_pub}

    # B — the proposing repo (signs the merge-request).
    {b_pub, b_priv} = Signing.generate_keypair()
    b_identity = "bbbbbbbb-0000-0000-0000-000000000002"
    b_ctx = %SigningContext{identity_uuid: b_identity, private_key: b_priv, public_key: b_pub}

    %{
      store: name,
      a_ctx: a_ctx,
      a_identity: a_identity,
      a_pub: a_pub,
      b_ctx: b_ctx,
      b_identity: b_identity,
      b_pub: b_pub
    }
  end

  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, v), do: Application.put_env(:commonplace, key, v)

  # Pin the given identity=>pubkey map. `accept_unsigned:` controls strictness.
  defp put_trust(trusted, accept_unsigned) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: accept_unsigned,
      trusted_identities: trusted
    })
  end

  defp pin(id, pub), do: {id, Signing.encode_key(pub)}

  # Create target doc X (text) with an initial A-authored commit; return the
  # base_cid (X's head) after that write.
  defp create_target_x(store, a_ctx, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "page.md")
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)

    commit =
      CommitStoreClient.create_chained_commit(store, uuid, update, %{kind: :regular},
        signing_context: a_ctx
      )

    {uuid, commit.id}
  end

  # Read X's current text content by replaying its head.
  defp read_x(store, uuid) do
    doc = Yelixer.Doc.new()

    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        ContentType.get_content(doc)

      :none ->
        nil
    end
  end

  # B authors a delta that inserts `insert` at `index` on top of X's head.
  defp delta_inserting(store, x_uuid, index, insert) do
    doc = Yelixer.Doc.new()

    doc =
      case CommitStoreClient.latest_commit(store, x_uuid) do
        {:ok, commit} ->
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          doc
      end

    doc = ContentType.insert_text(doc, index, insert)
    Yelixer.Encoding.encode_update(doc)
  end

  defp build_proposal(store, x_uuid, base_cid, b_ctx, index, insert, message) do
    MergeRequest.sign(
      %{
        target_uuid: x_uuid,
        base_cid: base_cid,
        delta: delta_inserting(store, x_uuid, index, insert),
        message: message
      },
      b_ctx
    )
  end

  # ── NO-AUTHORITY invariant ────────────────────────────────────────────────
  test "a proposal, on its own, changes target X by nothing (no authority)",
       %{store: store, a_ctx: a_ctx, b_ctx: b_ctx, b_identity: b_identity, b_pub: b_pub} do
    put_trust(Map.new([pin(b_identity, b_pub)]), true)

    {x, base} = create_target_x(store, a_ctx, "hello")
    head_before = elem(CommitStoreClient.latest_commit(store, x), 1).id

    mr = build_proposal(store, x, base, b_ctx, 5, " world", "add world")

    # Publishing to B's own outbox, and listing it, touches X not at all.
    outbox = "outbox-#{UUID.uuid4()}"
    :ok = Outbox.publish(outbox, mr, b_ctx, store)
    assert [_] = Outbox.list(outbox, store)

    assert read_x(store, x) == "hello"
    assert elem(CommitStoreClient.latest_commit(store, x), 1).id == head_before
  end

  # ── THE BINDING ───────────────────────────────────────────────────────────
  test "a nil source-peer pubkey (A has no pin for this source) is refused with :unknown_proposer",
       %{store: store, a_ctx: a_ctx, b_ctx: b_ctx, a_identity: a_id, a_pub: a_pub} do
    # A pinned itself, but has NO pinned key for the source peer B.
    put_trust(Map.new([pin(a_id, a_pub)]), true)

    {x, base} = create_target_x(store, a_ctx, "hello")
    mr = build_proposal(store, x, base, b_ctx, 5, " world", "add world")

    # No server-resolved source-peer key → refuse. The self-claimed
    # `mr.proposer_id` is IRRELEVANT to the binding.
    assert {:error, :unknown_proposer} = Apply.apply_proposal(mr, nil, a_ctx, store)
    assert read_x(store, x) == "hello"
  end

  test "a WRONG source-peer pubkey (sig doesn't verify) is refused with :bad_proposal",
       %{store: store, a_ctx: a_ctx, b_ctx: b_ctx} do
    # A supplies a DIFFERENT pubkey than B actually signed with.
    {wrong_pub, _wrong_priv} = Signing.generate_keypair()

    {x, base} = create_target_x(store, a_ctx, "hello")
    mr = build_proposal(store, x, base, b_ctx, 5, " world", "add world")

    assert {:error, :bad_proposal} = Apply.apply_proposal(mr, wrong_pub, a_ctx, store)
    assert read_x(store, x) == "hello"
  end

  # ── APPLY = ORDINARY A-WRITE (under enforce) + PROVENANCE ─────────────────
  test "accept authors exactly ONE A-signed commit under enforce; content = delta; provenance names B",
       %{
         store: store,
         a_ctx: a_ctx,
         a_identity: a_id,
         a_pub: a_pub,
         b_ctx: b_ctx,
         b_identity: b_id,
         b_pub: b_pub
       } do
    # Strict + enforce, A holds authority (pinned root). B's key is server-
    # resolved by A and supplied to the apply gate (not pinned by identity_uuid).
    put_trust(Map.new([pin(a_id, a_pub)]), false)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {x, base} = create_target_x(store, a_ctx, "hello")
    head_before = elem(CommitStoreClient.latest_commit(store, x), 1).id

    mr = build_proposal(store, x, base, b_ctx, 5, " world", "please apply")

    assert {:ok, commit} = Apply.apply_proposal(mr, b_pub, a_ctx, store)

    # Exactly ONE new commit, chained onto the prior head.
    assert commit.parent_id == head_before
    assert commit.id != head_before

    # Signed by A, NOT by B.
    assert commit.signature != nil
    {:ok, signer_identity, _fp} = Signing.parse_signer_id(commit.signer_id)
    assert signer_identity == a_id
    refute signer_identity == b_id

    # Content reflects the delta.
    assert read_x(store, x) == "hello world"

    # PROVENANCE: advisory proposer, authority is A.
    assert commit.metadata.cross_repo_proposer == b_id
  end

  test "a :write-authorized A still passes A's write-gate exactly as a hand edit (enforce)",
       %{store: store, a_ctx: a_ctx, a_identity: a_id, a_pub: a_pub, b_ctx: b_ctx, b_pub: b_pub} do
    put_trust(Map.new([pin(a_id, a_pub)]), false)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {x, base} = create_target_x(store, a_ctx, "abc")
    mr = build_proposal(store, x, base, b_ctx, 3, "def", "extend")

    assert {:ok, _commit} = Apply.apply_proposal(mr, b_pub, a_ctx, store)
    assert read_x(store, x) == "abcdef"
  end

  # ── IDEMPOTENCY ───────────────────────────────────────────────────────────
  test "applying the same proposal twice yields one commit + :already_applied",
       %{store: store, a_ctx: a_ctx, a_identity: a_id, a_pub: a_pub, b_ctx: b_ctx, b_pub: b_pub} do
    put_trust(Map.new([pin(a_id, a_pub)]), false)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {x, base} = create_target_x(store, a_ctx, "hello")
    mr = build_proposal(store, x, base, b_ctx, 5, " world", "once")

    assert {:ok, commit} = Apply.apply_proposal(mr, b_pub, a_ctx, store)
    head_after_first = elem(CommitStoreClient.latest_commit(store, x), 1).id
    assert head_after_first == commit.id

    # Second apply of the SAME proposal: no second commit.
    assert {:ok, :already_applied} = Apply.apply_proposal(mr, b_pub, a_ctx, store)
    assert elem(CommitStoreClient.latest_commit(store, x), 1).id == head_after_first
    assert read_x(store, x) == "hello world"
  end

  # ── REJECT ────────────────────────────────────────────────────────────────
  test "reject records the proposal but touches the target by nothing",
       %{store: store, a_ctx: a_ctx, b_ctx: b_ctx} do
    {x, base} = create_target_x(store, a_ctx, "hello")
    head_before = elem(CommitStoreClient.latest_commit(store, x), 1).id

    mr = build_proposal(store, x, base, b_ctx, 5, " world", "nope")
    assert :ok = Apply.reject(mr, store)

    assert read_x(store, x) == "hello"
    assert elem(CommitStoreClient.latest_commit(store, x), 1).id == head_before
  end

  # ── review/5 editorial loop ───────────────────────────────────────────────
  test "review applies accepted and skips rejected proposals from an outbox",
       %{store: store, a_ctx: a_ctx, a_identity: a_id, a_pub: a_pub, b_ctx: b_ctx, b_identity: b_id, b_pub: b_pub} do
    # NOTE: B's pin here is a TEST-FIXTURE artifact only — this in-process store
    # hosts BOTH A's target and B's outbox, so B must be trusted to WRITE its own
    # outbox under enforce. In reality B's outbox lives on B's store. It plays NO
    # part in the binding: A authenticates via the `b_pub` it supplies to review.
    put_trust(Map.new([pin(a_id, a_pub), pin(b_id, b_pub)]), false)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {x, base} = create_target_x(store, a_ctx, "hello")

    accept_mr = build_proposal(store, x, base, b_ctx, 5, " world", "ACCEPT")
    reject_mr = build_proposal(store, x, base, b_ctx, 0, "REJECTED-", "REJECT")

    outbox = "outbox-#{UUID.uuid4()}"
    :ok = Outbox.publish(outbox, accept_mr, b_ctx, store)
    :ok = Outbox.publish(outbox, reject_mr, b_ctx, store)

    decision = fn mr -> if mr.message == "ACCEPT", do: :accept, else: :reject end
    # A server-resolves the owning peer's (B's) key for this outbox and threads it.
    results = Apply.review(outbox, b_pub, decision, a_ctx, store)

    assert [{_, {:ok, %Commonplace.Store.Commit{}}}, {_, :ok}] = results
    # Only the accepted delta landed.
    assert read_x(store, x) == "hello world"
  end
end
