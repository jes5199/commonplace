# OTHER — "the other server": the HOST that OWNS doc D and grants a
# scoped :read to MAIN, then keeps editing D so MAIN's replica updates
# live.
#
# A plain OS process (NO --sname, NO cookie, NO epmd, NO BEAM
# distribution). Its only tie to MAIN is the federation HTTP surface,
# which is (a) bearer-token gated at the door (FederationAuth) and
# (b) :read-cert gated per doc (FederationController) with existence-
# hiding on denial.
#
# Lifecycle:
#   1. Boot a strict store in its own data_dir; mint OTHER's root.
#   2. Create doc D (granted) and doc E (NOT granted) — both real docs.
#   3. Wait for MAIN's root pubkey (handshake file), then mint a
#      cross-root :read cert  {verbs:[:read], scope:{:docs,[D]}}  whose
#      AUDIENCE is MAIN's root key. E is deliberately left out of scope.
#   4. Serve the federation endpoints (Bandit) and publish the manifest.
#   5. Edit D three times on a ~2s timer — each a signed OTHER commit —
#      so MAIN visibly watches its replica change.
#
#   elixir -S mix run --no-start other.exs <dir> <shared> <port>

[data_dir, shared, port_s] = System.argv()
port = String.to_integer(port_s)
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.{Signing, SigningContext}
alias Commonplace.Document.ContentType
alias Commonplace.Store.{CommitStore, SecretStore}
alias Commonplace.Trust
alias Yelixer.{Doc, Encoding}

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)
# The CommitStore TRIO (R4c): CommitStore + TrustSideStore (owns capability
# rows) + PendingImports. store_capability delegates to TrustSideStore, so the
# companion must be running.
{:ok, _} = Commonplace.Store.Supervisor.start_link(data_dir: data_dir)
{:ok, _} = SecretStore.start_link(data_dir: data_dir, name: SecretStore)
{:ok, _} = CommonplaceWebWeb.FederationPeerBudget.start_link([])

session_log = Path.join(shared, "session.log")

say = fn msg ->
  IO.puts("[OTHER] " <> msg)
  File.write!(session_log, "#{System.system_time(:millisecond)} [OTHER] #{msg}\n", [:append])
end

# --- 1. OTHER's root of trust (strict — every commit is accountable) ---
{root_pub, root_priv} = Signing.generate_keypair()
# NOTE: the identity_uuid is "peer:other" on purpose — that is exactly the
# anchor key `PeerTrust.merge_peer_anchors(name: "other")` will pin it under
# on MAIN, so MAIN's WRITE-import gate (which fetches trusted_identities by
# the commit's signer identity_uuid) recognizes OTHER's root-signed commits.
root_uuid = "peer:other"
root_ctx = %SigningContext{identity_uuid: root_uuid, private_key: root_priv, public_key: root_pub}

Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
})

# --- 2. two real docs: D (will be granted) and E (never granted) ---
doc_d = UUID.uuid4()
doc_e = UUID.uuid4()

# keep D's Doc struct in-process so edits accumulate; each commit carries
# the full CRDT state (idempotent on replay — Yjs dedupes by client/clock).
mk_text = fn name, text ->
  Doc.new()
  |> ContentType.create(:text, name)
  |> ContentType.insert_text(0, text)
end

doc_d_state = mk_text.("note.md", "initial")
_ = CommitStore.create_commit(CommitStore, doc_d, Encoding.encode_update(doc_d_state), nil,
      %{kind: :regular}, signing_context: root_ctx)
say.("created doc D #{String.slice(doc_d, 0, 8)}… content=\"initial\" (root-signed)")

doc_e_state = mk_text.("secret.md", "TOP SECRET — MAIN was never granted this")
_ = CommitStore.create_commit(CommitStore, doc_e, Encoding.encode_update(doc_e_state), nil,
      %{kind: :regular}, signing_context: root_ctx)
say.("created doc E #{String.slice(doc_e, 0, 8)}… (exists, but will NOT be granted to MAIN)")

# --- 3. handshake: read MAIN's root pubkey, mint the scoped :read cert ---
main_pub_path = Path.join(shared, "main_pub.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(main_pub_path), do: {:halt, :ok}, else: (Process.sleep(250); {:cont, nil})
end)

main = File.read!(main_pub_path) |> Jason.decode!()
main_id = main["identity_uuid"]
{:ok, main_pub} = Signing.decode_key(main["root_pub_b64"])

{:ok, read_cert} =
  Trust.Read.grant(root_ctx, doc_d, {main_id, main_pub}, store: CommitStore)

say.("minted :read cert for MAIN over D ONLY  {verbs:[:read], scope:{:docs,[D]}}  cid=#{Base.encode16(read_cert.id, case: :lower) |> String.slice(0, 12)}…")

# --- 4. serve federation over HTTP (bearer-token gated at the door) ---
token = Base.url_encode64(:crypto.strong_rand_bytes(12))
# Identity-bound peer: the :read-cert gate resolves WHO is asking from THIS
# server-side entry (never a client-claimed value).
Application.put_env(:commonplace_web, :federation_peers, %{
  token => %{name: "main", identity_uuid: main_id, pubkey: main_pub}
})

defmodule CrossRepoDemo.Pipeline do
  use Plug.Builder
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug CommonplaceWebWeb.Router
end

{:ok, _} = Bandit.start_link(plug: CrossRepoDemo.Pipeline, scheme: :http, port: port)
say.("federation surface up on http://127.0.0.1:#{port} (bearer + :read-cert gated)")

manifest = %{
  port: port,
  token: token,
  root_uuid: root_uuid,
  root_pub_b64: Signing.encode_key(root_pub),
  doc_d: doc_d,
  doc_e: doc_e,
  read_cert_cid_b64: Base.encode64(read_cert.id)
}

File.write!(Path.join(shared, "manifest.json"), Jason.encode!(manifest))
File.write!(Path.join(shared, "other_ready"), "ok")
say.("published manifest — MAIN may now subscribe")

# --- 5. edit D three times so MAIN's replica visibly updates ---
Process.sleep(2500)

state =
  Enum.reduce(1..3, doc_d_state, fn n, doc ->
    Process.sleep(2000)
    text = ContentType.get_content(doc)
    doc = ContentType.insert_text(doc, String.length(text), " update #{n}")
    _ = CommitStore.create_chained_commit(CommitStore, doc_d, Encoding.encode_update(doc),
          %{kind: :regular}, signing_context: root_ctx)
    say.("wrote: #{ContentType.get_content(doc)}")
    doc
  end)

_ = state
say.("done editing — serving until MAIN finishes")
Process.sleep(:infinity)
