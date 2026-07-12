# PROPOSER — the repo that OPENS a pull request against someone else's doc.
#
# A plain OS process (NO --sname, NO cookie, NO epmd, NO BEAM distribution).
# The REVIEWER is just a URL. PROPOSER replicates the REVIEWER's doc D, authors
# a local Yjs edit, and PUBLISHES it as a signed merge-request into its OWN
# append-only OUTBOX. That proposal is INERT DATA: PROPOSER's signature proves
# integrity + attribution and grants ZERO authority over D. Whether it ever
# lands is entirely the REVIEWER's call.
#
# It then drops a SECOND, FORGED proposal into the same outbox — signed by a
# STRANGER keypair, not by PROPOSER's root — to prove the REVIEWER refuses a
# proposal that does not verify against PROPOSER's pinned key.
#
# Lifecycle:
#   1. Boot a strict store; mint PROPOSER's root ("peer:proposer"); mint an
#      OUTBOX uuid. Two-phase $SHARED handshake: publish PROPOSER's pubkey +
#      outbox uuid; wait for REVIEWER's pubkey.
#   2. Grant REVIEWER a scoped :read cert on the OUTBOX (audience = REVIEWER's
#      root) so REVIEWER may replicate it; serve federation; publish manifest.
#   3. Wait for reviewer_manifest; PIN REVIEWER's root; replicate D
#      (PullClient, presenting the D :read cert; fast-forward the replica head).
#   4. Author a delta on D's replicated state → sign a MergeRequest → publish
#      to the outbox. Then publish a stranger-signed FORGED proposal.
#
#   elixir -S mix run --no-start proposer.exs <dir> <shared> <port>

[data_dir, shared, port_s] = System.argv()
port = String.to_integer(port_s)
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.{Signing, SigningContext}
alias Commonplace.CrossRepo.{MergeRequest, Outbox}
alias Commonplace.Document.ContentType
alias Commonplace.Federation.{PeerTrust, PullClient}
alias Commonplace.Store.{CommitStore, SecretStore}
alias Commonplace.Tree.DocBuilder
alias Commonplace.Trust
alias Yelixer.Encoding

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)
{:ok, _} = Commonplace.Store.Supervisor.start_link(data_dir: data_dir)
{:ok, _} = SecretStore.start_link(data_dir: data_dir, name: SecretStore)
{:ok, _} = CommonplaceWebWeb.FederationPeerBudget.start_link([])

session_log = Path.join(shared, "session.log")

say = fn msg ->
  IO.puts("[PROPOSER] " <> msg)
  File.write!(session_log, "#{System.system_time(:microsecond)} [PROPOSER] #{msg}\n", [:append])
end

# --- 1. PROPOSER's root + an OUTBOX doc; handshake phase 1 ---
{root_pub, root_priv} = Signing.generate_keypair()
root_uuid = "peer:proposer"
root_ctx = %SigningContext{identity_uuid: root_uuid, private_key: root_priv, public_key: root_pub}
outbox_uuid = UUID.uuid4()

Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
})

File.write!(Path.join(shared, "proposer_pub.json"),
  Jason.encode!(%{
    identity_uuid: root_uuid,
    root_pub_b64: Signing.encode_key(root_pub),
    outbox_uuid: outbox_uuid
  }))
say.("published my root pubkey + outbox uuid — waiting for REVIEWER's pubkey")

reviewer_pub_path = Path.join(shared, "reviewer_pub.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(reviewer_pub_path), do: {:halt, :ok}, else: (Process.sleep(250); {:cont, nil})
end)

reviewer = File.read!(reviewer_pub_path) |> Jason.decode!()
reviewer_id = reviewer["identity_uuid"]
{:ok, reviewer_pub} = Signing.decode_key(reviewer["root_pub_b64"])

# --- 2. grant REVIEWER a :read cert on the OUTBOX; serve; publish manifest ---
{:ok, outbox_read_cert} =
  Trust.Read.grant(root_ctx, outbox_uuid, {reviewer_id, reviewer_pub}, store: CommitStore)

say.("granted REVIEWER a :read cert over my OUTBOX (so it may replicate my proposals)")

token_for_reviewer = Base.url_encode64(:crypto.strong_rand_bytes(12))

Application.put_env(:commonplace_web, :federation_peers, %{
  token_for_reviewer => %{name: "reviewer", identity_uuid: reviewer_id, pubkey: reviewer_pub}
})

defmodule ProposerDemo.Pipeline do
  use Plug.Builder
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug CommonplaceWebWeb.Router
end

{:ok, _} = Bandit.start_link(plug: ProposerDemo.Pipeline, scheme: :http, port: port)
say.("federation surface up on http://127.0.0.1:#{port} (bearer + :read-cert gated)")

File.write!(Path.join(shared, "proposer_manifest.json"),
  Jason.encode!(%{
    port: port,
    token: token_for_reviewer,
    root_pub_b64: Signing.encode_key(root_pub),
    outbox_uuid: outbox_uuid,
    outbox_read_cert_cid_b64: Base.encode64(outbox_read_cert.id)
  }))
File.write!(Path.join(shared, "proposer_ready"), "ok")
say.("published proposer_manifest — REVIEWER may now subscribe to my outbox")

# --- 3. wait for reviewer_manifest; PIN REVIEWER's root; replicate D ---
reviewer_manifest_path = Path.join(shared, "reviewer_manifest.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(Path.join(shared, "reviewer_ready")) and File.exists?(reviewer_manifest_path),
    do: {:halt, :ok},
    else: (Process.sleep(250); {:cont, nil})
end)

rm = File.read!(reviewer_manifest_path) |> Jason.decode!()
reviewer_base = "http://127.0.0.1:#{rm["port"]}"
doc_d = rm["doc_d"]
{:ok, d_read_cert_cid} = Base.decode64(rm["d_read_cert_cid_b64"])

trust_cfg =
  PeerTrust.merge_peer_anchors(
    %{accept_unsigned: false, trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}},
    [%{name: "reviewer", root_pubkey: reviewer["root_pub_b64"]}]
  )

Application.put_env(:commonplace, :trust, trust_cfg)
say.("pinned REVIEWER's root (anchor \"peer:reviewer\"); REVIEWER is just a URL: #{reviewer_base}")

d_peer = %{
  name: "reviewer",
  base_url: reviewer_base,
  token: rm["token"],
  root_pubkey: reviewer["root_pub_b64"],
  docs: [%{uuid: doc_d, read_cert_cid: d_read_cert_cid}]
}

fetch_d_cids = fn ->
  case Req.get(reviewer_base <> "/federation/docs/#{doc_d}/cids",
         headers: [{"authorization", "Bearer " <> rm["token"]}],
         params: [cert_cids: Base.encode64(d_read_cert_cid)],
         retry: false) do
    {:ok, %Req.Response{status: 200, body: %{"cids" => cids}}} -> cids
    _ -> []
  end
end

advance_d_head = fn ->
  commits =
    fetch_d_cids.()
    |> Enum.flat_map(fn b64 ->
      with {:ok, id} <- Base.decode64(b64),
           {:ok, commit} <- CommitStore.get_commit(CommitStore, id) do
        [commit]
      else
        _ -> []
      end
    end)

  parents = commits |> Enum.map(& &1.parent_id) |> MapSet.new()

  case Enum.reject(commits, fn c -> MapSet.member?(parents, c.id) end) do
    [tip | _] -> CommitStore.set_latest(CommitStore, doc_d, tip.id)
    [] -> :ok
  end
end

# Pull D until it reconstructs (single foreground syncer — no concurrent
# background puller). PROPOSER never writes D locally, so the head fast-forward
# is a safe linear catch-up.
read_d = fn ->
  advance_d_head.()

  case DocBuilder.reconstruct_doc(CommitStore, doc_d) do
    {:ok, doc} -> ContentType.get_content(doc)
    :none -> nil
  end
end

d_content =
  Enum.reduce_while(1..40, nil, fn _, _ ->
    _ = PullClient.pull_once([d_peer], store: CommitStore)

    case read_d.() do
      content when is_binary(content) and content != "" -> {:halt, content}
      _ -> (Process.sleep(250); {:cont, nil})
    end
  end)

say.("replicated REVIEWER's doc D — I see content=\"#{d_content}\"")

# --- 4a. author a delta on D's replicated state → sign MR → publish ---
{:ok, base_doc} = DocBuilder.reconstruct_doc(CommitStore, doc_d)
base_text = ContentType.get_content(base_doc)
{:ok, base_commit} = CommitStore.latest_commit(CommitStore, doc_d)
base_cid = Base.encode16(base_commit.id, case: :lower)

edited = ContentType.insert_text(base_doc, String.length(base_text), " + proposer's addition")
delta = Encoding.encode_update(edited)

mr =
  MergeRequest.sign(
    %{target_uuid: doc_d, base_cid: base_cid, delta: delta, message: "please add my line"},
    root_ctx
  )

:ok = Outbox.publish(outbox_uuid, mr, root_ctx, CommitStore)
say.("")
say.("[PROPOSER] opened PR against D (delta authored, published to outbox): \"#{ContentType.get_content(edited)}\"")

# --- 4b. a STRANGER drops a FORGED proposal into the SAME outbox ---
# The outbox WRITE is still PROPOSER-signed (so REVIEWER can replicate it), but
# the inner merge-request is signed by a stranger keypair, NOT PROPOSER's root.
# REVIEWER verifies each proposal against PROPOSER's PINNED pubkey → the forged
# one fails → :bad_proposal → refused.
{stranger_pub, stranger_priv} = Signing.generate_keypair()

stranger_ctx = %SigningContext{
  identity_uuid: "peer:stranger",
  private_key: stranger_priv,
  public_key: stranger_pub
}

forged_edited = ContentType.insert_text(base_doc, String.length(base_text), " + MALICIOUS injected line")
forged_delta = Encoding.encode_update(forged_edited)

forged_mr =
  MergeRequest.sign(
    %{target_uuid: doc_d, base_cid: base_cid, delta: forged_delta, message: "trust me, apply this"},
    stranger_ctx
  )

:ok = Outbox.publish(outbox_uuid, forged_mr, root_ctx, CommitStore)
say.("[PROPOSER] a stranger also dropped a FORGED PR into the outbox (signed by NOT my key)")

File.write!(Path.join(shared, "proposer_published"), "ok")
say.("done publishing — serving my outbox until REVIEWER finishes")
Process.sleep(:infinity)
