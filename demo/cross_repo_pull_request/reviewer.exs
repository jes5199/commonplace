# REVIEWER — the SOVEREIGN repo that OWNS doc D.
#
# A cross-repo PULL REQUEST, end to end, as two plain OS processes (NO
# --sname, NO cookie, NO epmd, NO BEAM distribution). The PROPOSER is just a
# URL. A merge-request is INERT DATA — a signed delta B would LIKE applied —
# and it grants ZERO authority over D. REVIEWER stays sovereign: it verifies
# WHO sent a proposal (attribution vs its pinned key for the proposer), then
# re-authors an accepted delta as ITS OWN signed commit through its normal
# write path. A forged/unauthorized proposal cannot force a change.
#
# Lifecycle:
#   1. Boot a strict store in its own data_dir; mint REVIEWER's root
#      ("peer:reviewer"). Create doc D = "spec v1", a signed REVIEWER commit.
#   2. Two-phase $SHARED handshake: publish REVIEWER's pubkey; wait for
#      PROPOSER's pubkey; grant PROPOSER a scoped :read cert on D (audience =
#      PROPOSER's root) so PROPOSER may replicate D; serve federation (Bandit,
#      bearer + :read-cert gated); publish reviewer_manifest.
#   3. Wait for proposer_manifest; PIN PROPOSER's root; subscribe (PullClient
#      @1000ms) to PROPOSER's OUTBOX, presenting the :read cert PROPOSER
#      granted REVIEWER on the outbox; fast-forward the outbox replica head.
#   4. Each poll: Outbox.list the replicated outbox and, per proposal,
#      Apply.apply_proposal(mr, PROPOSER_pubkey, reviewer_ctx). Print loudly:
#      applied (REVIEWER-signed, provenance=proposer) or refused (forged).
#
#   elixir -S mix run --no-start reviewer.exs <dir> <shared> <port>

[data_dir, shared, port_s] = System.argv()
port = String.to_integer(port_s)
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.{Signing, SigningContext}
alias Commonplace.CrossRepo.{Apply, Outbox}
alias Commonplace.Document.ContentType
alias Commonplace.Federation.{PeerTrust, PullClient}
alias Commonplace.Store.{CommitStore, SecretStore}
alias Commonplace.Tree.DocBuilder
alias Commonplace.Trust
alias Yelixer.{Doc, Encoding}

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)
# The CommitStore TRIO (R4c): CommitStore + TrustSideStore (capability rows) +
# PendingImports — PullClient stores inbound certs and defers out-of-order
# imports, so the full trio must run.
{:ok, _} = Commonplace.Store.Supervisor.start_link(data_dir: data_dir)
{:ok, _} = SecretStore.start_link(data_dir: data_dir, name: SecretStore)
{:ok, _} = CommonplaceWebWeb.FederationPeerBudget.start_link([])

session_log = Path.join(shared, "session.log")

say = fn msg ->
  IO.puts("[REVIEWER] " <> msg)
  File.write!(session_log, "#{System.system_time(:microsecond)} [REVIEWER] #{msg}\n", [:append])
end

# --- 1. REVIEWER's root + doc D = "spec v1" (root-signed) ---
{root_pub, root_priv} = Signing.generate_keypair()
root_uuid = "peer:reviewer"
root_ctx = %SigningContext{identity_uuid: root_uuid, private_key: root_priv, public_key: root_pub}

Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
})

doc_d = UUID.uuid4()

doc_d_state =
  Doc.new()
  |> ContentType.create(:text, "spec.md")
  |> ContentType.insert_text(0, "spec v1")

_ = CommitStore.create_commit(CommitStore, doc_d, Encoding.encode_update(doc_d_state), nil,
      %{kind: :regular}, signing_context: root_ctx)
say.("I OWN doc D #{String.slice(doc_d, 0, 8)}… content=\"spec v1\" (REVIEWER-signed)")

# --- 2a. handshake phase 1: publish REVIEWER's pubkey; wait for PROPOSER's ---
File.write!(Path.join(shared, "reviewer_pub.json"),
  Jason.encode!(%{identity_uuid: root_uuid, root_pub_b64: Signing.encode_key(root_pub)}))
say.("published my root pubkey — waiting for PROPOSER's")

proposer_pub_path = Path.join(shared, "proposer_pub.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(proposer_pub_path), do: {:halt, :ok}, else: (Process.sleep(250); {:cont, nil})
end)

proposer = File.read!(proposer_pub_path) |> Jason.decode!()
proposer_id = proposer["identity_uuid"]
{:ok, proposer_pub} = Signing.decode_key(proposer["root_pub_b64"])

# --- 2b. grant PROPOSER a scoped :read cert on D so it can replicate D ---
{:ok, d_read_cert} =
  Trust.Read.grant(root_ctx, doc_d, {proposer_id, proposer_pub}, store: CommitStore)

say.("granted PROPOSER a :read cert over D  {verbs:[:read], scope:{:docs,[D]}}  (so it may replicate D)")

# --- 2c. serve federation (bearer + :read-cert gated). The token I hand
# PROPOSER is identity-bound to PROPOSER server-side (never client-claimed). ---
token_for_proposer = Base.url_encode64(:crypto.strong_rand_bytes(12))

Application.put_env(:commonplace_web, :federation_peers, %{
  token_for_proposer => %{name: "proposer", identity_uuid: proposer_id, pubkey: proposer_pub}
})

defmodule ReviewerDemo.Pipeline do
  use Plug.Builder
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug CommonplaceWebWeb.Router
end

{:ok, _} = Bandit.start_link(plug: ReviewerDemo.Pipeline, scheme: :http, port: port)
say.("federation surface up on http://127.0.0.1:#{port} (bearer + :read-cert gated)")

File.write!(Path.join(shared, "reviewer_manifest.json"),
  Jason.encode!(%{
    port: port,
    token: token_for_proposer,
    root_pub_b64: Signing.encode_key(root_pub),
    doc_d: doc_d,
    d_read_cert_cid_b64: Base.encode64(d_read_cert.id)
  }))
File.write!(Path.join(shared, "reviewer_ready"), "ok")
say.("published reviewer_manifest — PROPOSER may now replicate D")

# --- 3. wait for proposer_manifest; PIN PROPOSER's root; subscribe to OUTBOX ---
proposer_manifest_path = Path.join(shared, "proposer_manifest.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(Path.join(shared, "proposer_ready")) and File.exists?(proposer_manifest_path),
    do: {:halt, :ok},
    else: (Process.sleep(250); {:cont, nil})
end)

pm = File.read!(proposer_manifest_path) |> Jason.decode!()
proposer_base = "http://127.0.0.1:#{pm["port"]}"
outbox_uuid = pm["outbox_uuid"]
{:ok, outbox_read_cert_cid} = Base.decode64(pm["outbox_read_cert_cid_b64"])

trust_cfg =
  PeerTrust.merge_peer_anchors(
    %{accept_unsigned: false, trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}},
    [%{name: "proposer", root_pubkey: proposer["root_pub_b64"]}]
  )

Application.put_env(:commonplace, :trust, trust_cfg)
say.("pinned PROPOSER's root (anchor \"peer:proposer\"); PROPOSER is just a URL: #{proposer_base}")

outbox_peer = %{
  name: "proposer",
  base_url: proposer_base,
  token: pm["token"],
  root_pubkey: proposer["root_pub_b64"],
  docs: [%{uuid: outbox_uuid, read_cert_cid: outbox_read_cert_cid}]
}

{:ok, _pull} =
  PullClient.start_link(peers: [outbox_peer], interval_ms: 1000, store: CommitStore, name: :reviewer_pull)

say.("subscribed to PROPOSER's OUTBOX @1000ms, presenting the :read cert PROPOSER granted me")

# Fast-forward the OUTBOX replica head to the tip of PROPOSER's advertised
# chain each poll. The PullClient GenServer LANDS every commit, but
# import_with_translation deliberately does not advance a puller's :latest for
# plain linear commits (CX-m3x preserves local heads). REVIEWER never writes
# the outbox locally, so advancing to the received tip is a safe fast-forward.
fetch_outbox_cids = fn ->
  case Req.get(proposer_base <> "/federation/docs/#{outbox_uuid}/cids",
         headers: [{"authorization", "Bearer " <> pm["token"]}],
         params: [cert_cids: Base.encode64(outbox_read_cert_cid)],
         retry: false) do
    {:ok, %Req.Response{status: 200, body: %{"cids" => cids}}} -> cids
    _ -> []
  end
end

advance_outbox_head = fn ->
  commits =
    fetch_outbox_cids.()
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
    [tip | _] -> CommitStore.set_latest(CommitStore, outbox_uuid, tip.id)
    [] -> :ok
  end
end

read_d = fn ->
  case DocBuilder.reconstruct_doc(CommitStore, doc_d) do
    {:ok, doc} -> ContentType.get_content(doc)
    :none -> nil
  end
end

# --- 4. observe the outbox; apply / refuse each proposal (REVIEWER is sole
# syncer via the background PullClient; this foreground loop only reads +
# applies to D, which REVIEWER OWNS). ---
init = %{handled: MapSet.new(), before_shot: false, applied_ok: false, refused_forged: false}

result =
  Enum.reduce(1..24, init, fn _, acc ->
    advance_outbox_head.()
    proposals = Outbox.list(outbox_uuid, CommitStore)

    acc =
      if proposals != [] and not acc.before_shot do
        say.("")
        say.("MONEY-SHOT #1 (proposal is DATA): I SEE #{length(proposals)} proposal(s) in PROPOSER's outbox,")
        say.("  but D is STILL \"#{read_d.()}\" — a published proposal has changed NOTHING yet.")
        %{acc | before_shot: true}
      else
        acc
      end

    acc =
      Enum.reduce(proposals, acc, fn mr, acc ->
        pid = Apply.proposal_id(mr)

        if MapSet.member?(acc.handled, pid) do
          acc
        else
          acc = %{acc | handled: MapSet.put(acc.handled, pid)}

          case Apply.apply_proposal(mr, proposer_pub, root_ctx, CommitStore, cert_cids: []) do
            {:ok, %Commonplace.Store.Commit{} = commit} ->
              content = read_d.()
              prov = Map.get(commit.metadata, :cross_repo_proposer)
              say.("")
              say.("[REVIEWER] APPLIED PR (msg=\"#{mr.message}\") → D now: \"#{content}\"")
              say.("  MONEY-SHOT #2 (REVIEWER sovereign): commit signer=REVIEWER (peer:reviewer), provenance=#{prov}")
              say.("  authority≠attribution — I re-authored the delta as MY OWN commit.")
              %{acc | applied_ok: content =~ "proposer's addition" and prov == "peer:proposer"}

            {:ok, :already_applied} ->
              acc

            {:error, reason} when reason in [:bad_proposal, :unknown_proposer] ->
              say.("")
              say.("[REVIEWER] REFUSED forged/unauthorized PR (#{reason}) — D UNCHANGED, still \"#{read_d.()}\"")
              say.("  MONEY-SHOT #3: a PR cannot force a merge. Authority stays with MY write-gate.")
              %{acc | refused_forged: true}

            {:error, other} ->
              say.("[REVIEWER] apply error: #{inspect(other)}")
              acc
          end
        end
      end)

    Process.sleep(700)
    acc
  end)

# --- verdict ---
say.("")
say.("final D: \"#{read_d.()}\"")
pass = result.before_shot and result.applied_ok and result.refused_forged

if pass do
  say.("DEMO PASSED — cross-repo PULL REQUEST: PROPOSER opened a signed delta, REVIEWER stayed")
  say.("sovereign (applied the valid PR as ITS OWN commit, refused the forged one). All 3 money-shots.")
  File.write!(Path.join(shared, "reviewer_done"), "0")
  System.halt(0)
else
  say.("DEMO FAILED — money-shots: #1(proposal-is-data)=#{result.before_shot} " <>
       "#2(applied-sovereign)=#{result.applied_ok} #3(forged-refused)=#{result.refused_forged}")
  File.write!(Path.join(shared, "reviewer_done"), "1")
  System.halt(1)
end
