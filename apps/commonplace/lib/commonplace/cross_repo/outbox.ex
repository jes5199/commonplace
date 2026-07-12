defmodule Commonplace.CrossRepo.Outbox do
  @moduledoc """
  Cross-repo B2 — Seam B, option (i): the PROPOSAL OUTBOX.

  The outbox is an APPEND-ONLY LOG DOCUMENT that lives in the PROPOSER's (B's)
  OWN repo. B publishes a merge-request by appending its wire form
  (`MergeRequest.to_wire/1`) to this doc as an ordinary signed write under B's
  OWN authority — there is NO cross-repo authority involved here. A later reads
  the proposals by REPLICATING this doc (Slice-0 machinery, run in reverse) and
  `from_wire`-decoding each entry; that read side is not built in this module.

  Structurally this mirrors `Commonplace.Dataflow.RedLog`: a Yjs `Array`
  document that accumulates opaque log lines, persisted with
  `create_chained_commit`. Each entry is one Base64 wire string (a full,
  re-verifiable proposal INCLUDING its signature). Nothing is ever removed —
  append-only.

  ## Signed write

  `publish/4` threads the proposer's `%SigningContext{}` through
  `Commonplace.MUD.SignedWrite.opts_for/2` (the project's existing
  signing-context → `{metadata, commit_opts}` helper). With no capability CIDs
  supplied it yields `{%{}, [signing_context: ctx]}` — exactly a plain signed
  write with no capability proof, which is all B needs to write a doc B owns.
  """

  alias Commonplace.CrossRepo.MergeRequest
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Store.CommitStoreClient

  @log_type "proposals"

  @doc """
  Append ONE proposal (its `MergeRequest.to_wire/1` form) to the outbox log
  document `outbox_uuid`, as a normal signed write by the proposer.

    * `mr` — the signed `%MergeRequest{}` to publish.
    * `signing_context` — the proposer's `%SigningContext{}` (B's own identity)
      or `nil` to write unsigned (test/anon use).
    * `store` — the commit store (name or pid), default `CommitStoreClient`.

  Returns `:ok`.
  """
  @spec publish(String.t(), MergeRequest.t(), SigningContext.t() | nil, term()) :: :ok
  def publish(outbox_uuid, %MergeRequest{} = mr, signing_context, store \\ CommitStoreClient)
      when is_binary(outbox_uuid) do
    doc = load_doc(outbox_uuid, store)
    entry = MergeRequest.to_wire(mr)
    doc = Yelixer.Types.Array.push(doc, @log_type, [entry])
    update = Yelixer.Encoding.encode_update(doc)

    {metadata, commit_opts} =
      SignedWrite.opts_for(outbox_uuid, signing_context: signing_context, store: store)

    CommitStoreClient.create_chained_commit(store, outbox_uuid, update, metadata, commit_opts)
    :ok
  end

  @doc """
  Read the outbox log document `outbox_uuid` and decode every entry, IN
  PUBLISH ORDER, back into `%MergeRequest{}` values.

  Malformed entries (anything `MergeRequest.from_wire/1` rejects) are skipped
  cleanly — a corrupt line never crashes the read. Returns the decoded list.
  """
  @spec list(String.t(), term()) :: [MergeRequest.t()]
  def list(outbox_uuid, store \\ CommitStoreClient) when is_binary(outbox_uuid) do
    load_doc(outbox_uuid, store)
    |> Yelixer.Types.Array.to_list(@log_type)
    |> Enum.flat_map(fn wire ->
      case MergeRequest.from_wire(wire) do
        {:ok, mr} -> [mr]
        {:error, _} -> []
      end
    end)
  end

  # Load the outbox doc from the store (or an empty one if it does not exist
  # yet), mirroring RedLog.load/2. A stable, uuid-derived client_id keeps
  # repeated load → append → commit cycles sharing one state-vector slot
  # instead of minting a fresh client per write (CX-pyi).
  defp load_doc(uuid, store) do
    doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, @log_type, :array)

    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        doc
    end
  end

  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end
end
