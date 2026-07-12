# MAIN — "my main server": the SUBSCRIBER in a SEPARATE trust domain.
#
# A plain OS process (NO --sname, NO cookie, NO epmd, NO BEAM
# distribution). OTHER is just a URL. MAIN pins exactly ONE thing —
# OTHER's root pubkey — and everything else is proven on arrival.
#
# Lifecycle:
#   1. Boot its own strict store; mint MAIN's root; publish MAIN's root
#      pubkey to the handshake dir (OTHER needs it to mint the cert).
#   2. Wait for OTHER's manifest; PIN OTHER's root (PeerTrust) so its
#      root-signed D commits land through the UNCHANGED Gate A.
#   3. Configure OTHER as a federation peer and start PullClient's
#      periodic poll loop, presenting MAIN's :read cert for D.
#   4. Each observe tick: reconstruct D's replicated content and print it
#      — as OTHER's 3 edits land, the replica visibly updates.
#   5. Attempt to pull E (never granted): the serve existence-hides it.
#
#   elixir -S mix run --no-start main.exs <dir> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.Signing
alias Commonplace.Document.ContentType
alias Commonplace.Federation.{PeerTrust, PullClient}
alias Commonplace.Store.CommitStore
alias Commonplace.Tree.DocBuilder

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)
# The CommitStore TRIO (R4c): CommitStore + TrustSideStore + PendingImports.
# PullClient stores inbound certs (TrustSideStore) and defers out-of-order
# imports (PendingImports), so the full trio must run.
{:ok, _} = Commonplace.Store.Supervisor.start_link(data_dir: data_dir)

session_log = Path.join(shared, "session.log")

say = fn msg ->
  IO.puts("[MAIN] " <> msg)
  File.write!(session_log, "#{System.system_time(:millisecond)} [MAIN] #{msg}\n", [:append])
end

# --- 1. MAIN's root; publish its pubkey for OTHER's cert audience ---
{main_pub, _main_priv} = Signing.generate_keypair()
main_id = "peer:main"

File.write!(Path.join(shared, "main_pub.json"),
  Jason.encode!(%{identity_uuid: main_id, root_pub_b64: Signing.encode_key(main_pub)}))

say.("published my root pubkey — waiting for OTHER's manifest")

# --- 2. wait for OTHER, PIN its root ---
manifest_path = Path.join(shared, "manifest.json")

Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(Path.join(shared, "other_ready")) and File.exists?(manifest_path),
    do: {:halt, :ok},
    else: (Process.sleep(250); {:cont, nil})
end)

manifest = File.read!(manifest_path) |> Jason.decode!()
base_url = "http://127.0.0.1:#{manifest["port"]}"
doc_d = manifest["doc_d"]
doc_e = manifest["doc_e"]
{:ok, read_cert_cid} = Base.decode64(manifest["read_cert_cid_b64"])

# Identity-bound peer: root_pubkey is what PeerTrust pins.
peer_anchor = %{name: "other", root_pubkey: manifest["root_pub_b64"]}

trust_cfg =
  PeerTrust.merge_peer_anchors(
    %{accept_unsigned: false, trusted_identities: %{main_id => Signing.encode_key(main_pub)}},
    [peer_anchor]
  )

Application.put_env(:commonplace, :trust, trust_cfg)
say.("pinned OTHER's root (anchor \"peer:other\"); OTHER is just a URL: #{base_url}")

# --- 3. subscribe: PullClient poll loop, presenting MAIN's :read cert for D ---
peer = %{
  name: "other",
  base_url: base_url,
  token: manifest["token"],
  root_pubkey: manifest["root_pub_b64"],
  docs: [%{uuid: doc_d, read_cert_cid: read_cert_cid}]
}

{:ok, _pull} = PullClient.start_link(peers: [peer], interval_ms: 1000, store: CommitStore, name: :cross_repo_pull)
say.("PullClient subscribed to D @1000ms, presenting :read cert")

# Fast-forward the replica head to the tip of OTHER's advertised chain.
# The PullClient GenServer LANDS every commit, but `import_with_translation`
# deliberately does not advance a puller's `:latest` for plain linear commits
# (CX-m3x preserves local heads; only merges self-adopt). MAIN never writes D
# locally, so there is no head to clobber — advancing to the received tip is a
# plain, safe fast-forward (exactly what a linear catch-up does). Each of
# OTHER's commits carries full CRDT state, so even a partial chain reconstructs
# the complete text.
fetch_remote_cids = fn ->
  case Req.get(base_url <> "/federation/docs/#{doc_d}/cids",
         headers: [{"authorization", "Bearer " <> manifest["token"]}],
         params: [cert_cids: Base.encode64(read_cert_cid)],
         retry: false) do
    {:ok, %Req.Response{status: 200, body: %{"cids" => cids}}} -> cids
    _ -> []
  end
end

advance_head = fn ->
  commits =
    fetch_remote_cids.()
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

read_d = fn ->
  advance_head.()

  case DocBuilder.reconstruct_doc(CommitStore, doc_d) do
    {:ok, doc} -> ContentType.get_content(doc)
    :none -> nil
  end
end

# --- 4. observe the live-updating replica ---
seen =
  Enum.reduce(1..18, MapSet.new(), fn _, seen ->
    # READ-ONLY observation — the PullClient GenServer above is the sole
    # syncer (a second concurrent puller would race it into a double-import).
    content = read_d.()

    seen =
      if is_binary(content) and not MapSet.member?(seen, content) do
        say.("D now: #{content}")
        MapSet.put(seen, content)
      else
        seen
      end

    Process.sleep(700)
    seen
  end)

# --- 5. the ungranted doc E: existence-hidden by the :read-cert gate ---
e_peer = %{peer | docs: [doc_e]}
_ = PullClient.pull_once([e_peer], store: CommitStore)
e_cids = CommitStore.commit_ids_for_doc(CommitStore, doc_e)

e_hidden = MapSet.size(e_cids) == 0

if e_hidden do
  say.("E: denied/not-found (existence-hidden — no :read cert)")
else
  say.("E: LEAKED #{MapSet.size(e_cids)} commit(s) — existence-hiding FAILED")
end

# --- verdict ---
final = read_d.() || ""
propagated = Enum.all?(["update 1", "update 2", "update 3"], &String.contains?(final, &1))

say.("")
say.("final D replica: #{final}")
say.("distinct D contents observed on MAIN: #{MapSet.size(seen)}")

pass = propagated and e_hidden

if pass do
  say.("DEMO PASSED — cross-trust-root LIVE read replica: MAIN pinned OTHER's root,")
  say.("subscribed to D, and watched its replica update as OTHER edited — E stayed hidden.")
  File.write!(Path.join(shared, "main_done"), "0")
  System.halt(0)
else
  say.("DEMO FAILED — see above (propagated=#{propagated} e_hidden=#{e_hidden})")
  File.write!(Path.join(shared, "main_done"), "1")
  System.halt(1)
end
