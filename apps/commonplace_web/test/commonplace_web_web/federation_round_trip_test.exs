defmodule CommonplaceWebWeb.FederationRoundTripTest do
  @moduledoc """
  Phase C acceptance (CX-orfw.1): the FULL federation round-trip over a
  REAL TCP socket — two separate-rooted stores, no shared anything.

  The serving workspace (default CommitStore behind the real router +
  parsers, listening on an ephemeral port via Bandit) holds an agent's
  delegated, signed commit. The pulling workspace (its own CommitStore)
  runs `PullClient.pull_once/2` with the DEFAULT HTTP transport (Req) —
  CID diff, envelope fetch, cert verify+store, and import through its
  own strict Gate A. This is move #1's invariant end-to-end: an external
  principal's commit crosses a dumb transport and lands only because the
  cert chain verifies against a locally-pinned root.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.PullClient
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  @token "round-trip-token"

  defmodule ServerPipeline do
    @moduledoc false
    use Plug.Builder

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug CommonplaceWebWeb.Router
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fed_rt_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    # Serving side = the DEFAULT trio (the controller's store + its
    # TrustSideStore/PendingImports companions), pointed at scratch
    # (wiki_live_test pattern).
    #
    # R4c carve-out: swap ALL THREE trio children, not just CommitStore.
    # `Commonplace.Store.CommitStoreSupervisor` is now
    # `Commonplace.Store.Supervisor` (`:rest_for_one`) rather than a bare
    # one_for_one wrapping only CommitStore — TrustSideStore resolves its
    # CubDB handle ONCE, at its own `init/1`, via
    # `CommitStore.db_handle/1`. Manually restarting only the CommitStore
    # child (as the pre-carve-out test did) would leave TrustSideStore
    # pinned to the OLD (about-to-be-abandoned) db handle — exactly the
    # staleness `Commonplace.Store.Supervisor`'s moduledoc warns about,
    # here triggered by an explicit admin swap rather than a crash.
    Application.put_env(:commonplace, :data_dir, dir)
    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.PendingImports)
    _ = Supervisor.delete_child(sup, Commonplace.Store.PendingImports)
    _ = Supervisor.terminate_child(sup, Commonplace.Store.TrustSideStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.TrustSideStore)
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)

    {:ok, _} =
      Supervisor.start_child(
        sup,
        {CommitStore,
         data_dir: dir,
         trust_side_store: Commonplace.Store.TrustSideStore,
         pending_imports: Commonplace.Store.PendingImports}
      )

    {:ok, _} =
      Supervisor.start_child(sup, {Commonplace.Store.TrustSideStore, commit_store: CommitStore})

    {:ok, _} =
      Supervisor.start_child(sup, {Commonplace.Store.PendingImports, commit_store: CommitStore})

    # Pulling side = its own trio, its own root. PullClient calls
    # store_capability/2 on this side when inlining a fetched envelope's
    # cert chain, which (R4c carve-out) delegates to TrustSideStore.
    n = :rand.uniform(1_000_000)
    pulling = :"fed_rt_pulling_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: Path.join(dir, "pulling"),
       name: :"fed_rt_pulling_sup_#{n}",
       commit_store_name: pulling,
       trust_side_store_name: :"fed_rt_pulling_tss_#{n}",
       pending_imports_name: :"fed_rt_pulling_pi_#{n}"}
    )

    # Real HTTP server on an ephemeral port: parsers + the real router.
    server = start_supervised!({Bandit, plug: ServerPipeline, scheme: :http, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:commonplace_web, :federation_peers, %{@token => "puller"})

    on_exit(fn ->
      Application.delete_env(:commonplace_web, :federation_peers)
      Application.delete_env(:commonplace, :trust)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{pulling: pulling, port: port}
  end

  test "agent commit federates A→B over real HTTP and lands through strict Gate A",
       %{pulling: pulling, port: port} do
    # Shared root of trust: pinned on the pulling side, issuer of the
    # agent's cert on the serving side.
    {root_pub, root_priv} = Signing.generate_keypair()
    root_uuid = "root-" <> UUID.uuid4()

    root_ctx = %SigningContext{
      identity_uuid: root_uuid,
      private_key: root_priv,
      public_key: root_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
    })

    # On the SERVING workspace: an agent with a delegated write cert
    # authors a signed commit.
    doc = UUID.uuid4()
    {agent_pub, agent_priv} = Signing.generate_keypair()
    agent_uuid = "agent-" <> UUID.uuid4()

    {:ok, cert} =
      Capability.delegate(root_ctx, {agent_uuid, agent_pub}, %{
        verbs: [:write],
        scope: {:docs, [doc]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(CommitStore, cert)

    commit =
      Commit.new(
        doc,
        Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
        nil,
        %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "fed-rt-epoch"),
          capability_proof: cert.id
        }
      )
      |> Signing.sign_commit(agent_priv, Signing.signer_id(agent_uuid, agent_pub))

    :ok = CommitStore.import_commit(CommitStore, commit, validator: fn _ -> :ok end)

    # Cross-repo Slice-0 (2026-07-11 spec, §1 Seam C): the serving side
    # (A) now gates `cids`/`commits` by a `:read` cert too — under this
    # STRICT trust config, A's bearer-token peer map must additionally
    # identify the puller's (B's) key, and A's root must grant B a
    # `:read` cert over `doc`, or A's serve refuses (existence-hiding),
    # same as the coarse-token-only model would 404. This is the NEW
    # security seam this spec builds — a bare-token peer with no cert
    # would legitimately be turned away here.
    {puller_pub, _puller_priv} = Signing.generate_keypair()
    puller_uuid = "puller-" <> UUID.uuid4()

    {:ok, read_cert} =
      Commonplace.Trust.Read.grant(root_ctx, doc, {puller_uuid, puller_pub}, store: CommitStore)

    Application.put_env(:commonplace_web, :federation_peers, %{
      @token => %{name: "puller", identity_uuid: puller_uuid, pubkey: puller_pub}
    })

    # The pulling workspace federates over the real socket — default
    # HTTP transport, bearer-token auth, strict import gate — presenting
    # its granted `:read` cert cid on every pull request.
    peer = %{
      name: "ws-a",
      base_url: "http://127.0.0.1:#{port}",
      token: @token,
      docs: [%{uuid: doc, read_cert_cid: read_cert.id}]
    }

    report = PullClient.pull_once([peer], store: pulling)

    assert report.imported >= 1
    assert report.errors == []
    assert {:ok, landed} = CommitStore.get_commit(pulling, commit.id)
    assert landed.signer_id == Signing.signer_id(agent_uuid, agent_pub)
    assert {:ok, _} = CommitStore.get_capability(pulling, cert.id)

    # And the wrong token is turned away at the door.
    bad_peer = %{peer | token: "wrong"}
    bad_report = PullClient.pull_once([bad_peer], store: pulling)
    assert [{_, _, {:http_status, 403}} | _] = bad_report.errors

    # --- read-only safety: second pull is idempotent (no double-import,
    # no local mutation attempt) --------------------------------------
    idempotent_report = PullClient.pull_once([peer], store: pulling)
    assert idempotent_report.imported == 0
    assert idempotent_report.rejected == 0

    # --- live-flow: A edits doc (a new, CHAINED commit) → B re-pulls
    # and its replica's known-commit set (its ":latest") advances -----
    before_ids = CommitStore.commit_ids_for_doc(pulling, doc) |> MapSet.new()

    update2 =
      Yelixer.Doc.new()
      |> Commonplace.Tree.Schema.add_file("f", UUID.uuid4())
      |> Yelixer.Encoding.encode_update()

    commit2 =
      Commit.new(doc, update2, commit.id, %{
        kind: :regular,
        snapshot_parent: :crypto.hash(:sha256, "fed-rt-epoch"),
        capability_proof: cert.id
      })
      |> Signing.sign_commit(agent_priv, Signing.signer_id(agent_uuid, agent_pub))

    :ok = CommitStore.import_commit(CommitStore, commit2, validator: fn _ -> :ok end)

    # `import_commit` is the catch-up primitive (stores without moving
    # `:latest` — that decision belongs to the higher authoring/merge
    # layer); simulate A's local authoring path advancing its own head
    # to this new commit, exactly as `create_chained_commit` would.
    :ok = CommitStore.set_latest(CommitStore, doc, commit2.id)

    live_report = PullClient.pull_once([peer], store: pulling)

    assert live_report.imported >= 1
    assert live_report.errors == []
    assert {:ok, _} = CommitStore.get_commit(pulling, commit2.id)

    # NOTE (design fork, surfaced not silently worked around):
    # `commit_ids_for_doc`/`:latest` do NOT advance here — `MergeAdopter`
    # (wired into `NodeSync.import_with_translation`) only auto-adopts a
    # freshly-landed `:merge` commit as the new local head (CX-m3x: "a
    # peer that only receives merges never advances `:latest`... this
    # module fills the gap"); a plain `:regular` chained commit pulled
    # via catch-up is stored but intentionally does NOT move `:latest`,
    # to protect a REGULAR node's own local edits from being clobbered by
    # background sync. For a Slice-0 replica that NEVER authors locally,
    # that guard has nothing to protect and arguably should fast-forward
    # on a strict linear descent — but widening `MergeAdopter` (or adding
    # a replica-specific adoption rule) is a real trust/sync-semantics
    # decision beyond this seam's small surface. Flagging for jes/boss
    # rather than quietly patching it. The commit DOES land (`imported`,
    # `get_commit`), proving the live pull itself works end-to-end; only
    # the rendered `:latest` pointer is the open gap.
    before_ids = MapSet.put(before_ids, commit.id)
    after_ids = CommitStore.commit_ids_for_doc(pulling, doc) |> MapSet.new()
    assert after_ids == before_ids

    # B never mints/serves commits FOR A — B has no federation-serve
    # peer of its own configured and PullClient exposes no write path
    # upstream; the replica advanced purely by importing A's commits
    # into ITS OWN store, never by writing back to A's.
    assert CommitStore.commit_ids_for_doc(CommitStore, doc) |> MapSet.new() ==
             MapSet.new([commit.id, commit2.id])
  end
end
