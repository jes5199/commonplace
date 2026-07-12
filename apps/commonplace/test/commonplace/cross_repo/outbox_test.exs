defmodule Commonplace.CrossRepo.OutboxTest do
  @moduledoc """
  B2 Seam-B (option i): the proposal outbox — an append-only log document in
  B's own repo. Uses the same in-process CommitStore setup the RedLog / cross-
  repo tests use (no Phoenix serve booted).
  """
  use ExUnit.Case

  alias Commonplace.CrossRepo.{MergeRequest, Outbox}
  alias Commonplace.Crypto.{Signing, SigningContext}

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_outbox_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({Commonplace.Store.CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    {pub, priv} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: "proposer-B", private_key: priv, public_key: pub}
    %{store: store_name, ctx: ctx, pub: pub}
  end

  defp proposal(ctx, message) do
    MergeRequest.sign(
      %{
        target_uuid: "doc-X-uuid",
        base_cid: "cidbaseHEAD",
        delta: <<1, 2, 3, 0, 255, 42>>,
        message: message
      },
      ctx
    )
  end

  test "publish two proposals then list returns them in publish order, each verifying",
       %{store: store, ctx: ctx, pub: pub} do
    outbox = "outbox-#{UUID.uuid4()}"

    mr1 = proposal(ctx, "first proposal")
    mr2 = proposal(ctx, "second proposal")

    assert :ok == Outbox.publish(outbox, mr1, ctx, store)
    assert :ok == Outbox.publish(outbox, mr2, ctx, store)

    listed = Outbox.list(outbox, store)
    assert length(listed) == 2
    assert Enum.map(listed, & &1.message) == ["first proposal", "second proposal"]

    assert [mr1, mr2] == listed
    for mr <- listed, do: assert(:ok == MergeRequest.verify(mr, pub))
  end

  test "an empty outbox lists nothing", %{store: store} do
    assert [] == Outbox.list("outbox-#{UUID.uuid4()}", store)
  end

  test "a malformed entry in the log is skipped by list without crashing",
       %{store: store, ctx: ctx, pub: pub} do
    outbox = "outbox-#{UUID.uuid4()}"

    good = proposal(ctx, "well-formed proposal")
    assert :ok == Outbox.publish(outbox, good, ctx, store)

    # Inject a garbage line directly into the underlying log array, the same
    # way publish appends, but with a value from_wire cannot decode.
    inject_raw_entry(outbox, store, "this-is-not-a-valid-wire-entry")

    listed = Outbox.list(outbox, store)
    assert length(listed) == 1
    assert hd(listed) == good
    assert :ok == MergeRequest.verify(hd(listed), pub)
  end

  # Append an arbitrary (possibly malformed) string to the outbox log doc,
  # bypassing Outbox.publish so we can simulate a corrupt entry.
  defp inject_raw_entry(uuid, store, raw) do
    doc = Yelixer.Doc.new(client_id: :erlang.phash2(uuid, 0xFFFF_FFFF))
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "proposals", :array)

    doc =
      case Commonplace.Store.CommitStoreClient.latest_commit(store, uuid) do
        {:ok, commit} ->
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          doc
      end

    doc = Yelixer.Types.Array.push(doc, "proposals", [raw])
    update = Yelixer.Encoding.encode_update(doc)
    Commonplace.Store.CommitStoreClient.create_chained_commit(store, uuid, update)
    :ok
  end
end
