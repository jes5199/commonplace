defmodule CommonplaceWebWeb.FederationController do
  @moduledoc """
  The federation HTTP surface (phase C, CX-orfw): pull-based commit
  exchange between separate-rooted workspaces — the thin transport the
  trust arc was built to make sufficient.

  Three endpoints, mirroring `NodeSync.catch_up`'s shape over HTTP:

    * `GET  /federation/docs/:uuid/cids`    — the doc's commit-CID set,
      for the puller's diff.
    * `POST /federation/docs/:uuid/commits` — requested CIDs → envelopes
      (commit + inlined cert chain + known revocations,
      `Envelope.for_commit/2` — CX-bepn design §6).
    * `POST /federation/import`             — envelope in: certs AND
      revocations are verified (id + sig — self-verifying values) and
      stored, then the commit goes through `import_commit` — Gate A
      UNCHANGED, the only door. Revocation AUTHORITY is never checked
      here (§7.6 — that's `Trust.VerifyChain`'s job, at verify time).
      The per-peer deferral budget 429s a peer that keeps sending
      commits which defer on `:awaiting_capability`, bounding its
      pending-queue contribution (CX-orfw.1 scope note).

  Nothing here weakens or substitutes for the import gate: a request
  that passes bearer auth still lands ONLY what Gate A verifies.

  ## Cross-repo Slice-0 `:read`-cert gate (2026-07-11 spec, §1 Seam C) — THE SECURITY SEAM

  `cids/2` and `commits/2` are read-scope-gated: beyond the bearer-token
  "may you talk to this endpoint" check, the requester must additionally
  hold a `:read` capability covering the requested doc, or the response
  is IDENTICAL to a non-existent doc (existence-hiding — the same
  discipline read-scoping already uses at `tools/cat.ex`). This reuses
  `Trust.reader_authorized?`/`cert_grants_read?` UNCHANGED — no new trust
  logic, just a new call site with the requester's SERVER-RESOLVED
  identity (`conn.assigns.federation_peer`, set by `FederationAuth` from
  the authenticated bearer token — NEVER the client-supplied `cert_cids`
  param, which names only the CERT the client presents, not a claim of
  WHO they are).
  """
  use CommonplaceWebWeb, :controller

  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust
  alias CommonplaceWebWeb.FederationPeerBudget

  def cids(conn, %{"uuid" => uuid} = params) do
    if read_authorized?(conn, uuid, params) do
      cids =
        CommitStoreClient.commit_ids_for_doc(CommitStoreClient, uuid)
        |> Enum.map(&Base.encode64/1)

      json(conn, %{cids: cids})
    else
      # Existence-hiding: identical shape to a doc this peer never had
      # any CIDs for — a denied request must be indistinguishable from
      # a request for a UUID that doesn't exist.
      json(conn, %{cids: []})
    end
  end

  def commits(conn, %{"uuid" => uuid, "cids" => cids} = params) when is_list(cids) do
    if read_authorized?(conn, uuid, params) do
      {envelopes, missing} =
        Enum.reduce(cids, {[], []}, fn b64, {envs, miss} ->
          with {:ok, id} <- Base.decode64(b64),
               {:ok, commit} <- CommitStoreClient.get_commit(CommitStoreClient, id) do
            {[Envelope.for_commit(CommitStoreClient, commit) | envs], miss}
          else
            _ -> {envs, [b64 | miss]}
          end
        end)

      json(conn, %{envelopes: Enum.reverse(envelopes), missing: Enum.reverse(missing)})
    else
      # Existence-hiding: every requested CID reports "missing", exactly
      # what an unauthorized peer sees for a doc that doesn't exist.
      json(conn, %{envelopes: [], missing: cids})
    end
  end

  def import(conn, %{"envelope" => encoded}) when is_binary(encoded) do
    peer = conn.assigns.federation_peer

    with {:ok, %{commit: commit, certs: certs, revocations: revocations}} <-
           Envelope.decode(encoded),
         :ok <- Envelope.verify_certs(certs),
         :ok <- Envelope.verify_revocations(revocations) do
      if FederationPeerBudget.over_budget?(peer.name) do
        conn
        |> put_status(429)
        |> json(%{result: "over_deferral_budget"})
      else
        Enum.each(certs, &CommitStoreClient.store_capability(CommitStoreClient, &1))
        # CX-bepn (design §6): store sig-consistent revocations on
        # arrival; authority is validated only at verify time (§7.6).
        Enum.each(revocations, &CommitStoreClient.store_revocation(CommitStoreClient, &1))
        respond_import(conn, peer, CommitStoreClient.import_commit(CommitStoreClient, commit))
      end
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{result: "bad_envelope", reason: to_string(reason)})
    end
  end

  defp respond_import(conn, _peer, :ok), do: json(conn, %{result: "ok"})

  defp respond_import(conn, peer, {:error, {:trust_rejected, :awaiting_capability}}) do
    # Queued in pending_imports — count it against this peer's budget.
    FederationPeerBudget.record_deferral(peer.name)
    json(conn, %{result: "deferred"})
  end

  defp respond_import(conn, _peer, {:error, reason}) do
    json(conn, %{result: "rejected", reason: inspect(reason)})
  end

  # The requester presents its `:read` cert CID(s) (base64) via the
  # `cert_cids` param — a plain list (POST body) or comma-separated query
  # string (GET). This is ONLY the cert being presented; WHO is
  # presenting it comes exclusively from `conn.assigns.federation_peer`
  # (server-resolved by `FederationAuth` from the authenticated bearer
  # token), never from this param — the audience-binding anti-theft
  # guarantee `Trust.reader_authorized?` already enforces only holds if
  # the identity/pub it's called with is unspoofable.
  defp read_authorized?(conn, uuid, params) do
    peer = conn.assigns.federation_peer
    cert_cids = decode_cert_cids(Map.get(params, "cert_cids"))
    cfg = Trust.config()

    Trust.reader_authorized?(
      peer.identity_uuid,
      peer.pubkey,
      cert_cids,
      uuid,
      cfg,
      CommitStoreClient
    )
  end

  defp decode_cert_cids(nil), do: []
  defp decode_cert_cids(""), do: []

  defp decode_cert_cids(str) when is_binary(str) do
    str |> String.split(",", trim: true) |> decode_cert_cids()
  end

  defp decode_cert_cids(list) when is_list(list) do
    Enum.flat_map(list, fn b64 ->
      case Base.decode64(b64) do
        {:ok, cid} -> [cid]
        :error -> []
      end
    end)
  end
end
