defmodule CommonplaceWebWeb.FederationControllerTest do
  @moduledoc """
  Phase C federation endpoints (CX-orfw): CID listing, envelope serving,
  and the import door — bearer-token gated, with the per-peer deferral
  budget bounding the `:awaiting_capability` pending-queue contribution
  (the flood-DoS scope note on CX-orfw.1).

  Auth here is transport hygiene ("may you talk to this endpoint");
  authorization-to-LAND stays Gate A's (`import_commit` unchanged) —
  the import test below is the phase-B keystone re-proven over HTTP.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  @token "fed-test-token"
  @peer "peer-a"

  setup do
    # Point the default CommitStore at a scratch dir (wiki_live_test pattern).
    dir = Path.join(System.tmp_dir!(), "cp_fed_ctrl_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # R4c carve-out: swap ALL THREE trio children, not just CommitStore —
    # see the identical comment in federation_round_trip_test.exs for why
    # (TrustSideStore/PendingImports resolve their handle/reference ONCE,
    # at their own init/1; leaving them running after a CommitStore swap
    # would pin them to the OLD, about-to-be-abandoned instance).
    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.PendingImports)
    _ = Supervisor.delete_child(sup, Commonplace.Store.PendingImports)
    _ = Supervisor.terminate_child(sup, Commonplace.Store.TrustSideStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.TrustSideStore)
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)

    {:ok, _pid} =
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

    Application.put_env(:commonplace_web, :federation_peers, %{@token => @peer})

    on_exit(fn ->
      Application.delete_env(:commonplace_web, :federation_peers)
      Application.delete_env(:commonplace_web, :federation_deferral_budget)
      Application.delete_env(:commonplace, :trust)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      File.rm_rf!(dir)
    end)

    CommonplaceWebWeb.FederationPeerBudget.reset()

    %{dir: dir}
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()

    %{
      uuid: id,
      pub: pub,
      priv: priv,
      ctx: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
      signer: Signing.signer_id(id, pub)
    }
  end

  # A root pinned strict, delegating :write over `docs` to an agent.
  defp strict_delegation(docs) do
    root = ident("root-" <> UUID.uuid4())
    agent = ident("agent-" <> UUID.uuid4())

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{root.uuid => Signing.encode_key(root.pub)}
    })

    {:ok, cert} =
      Capability.delegate(root.ctx, {agent.uuid, agent.pub}, %{
        verbs: [:write],
        scope: {:docs, docs},
        caveats: %{not_before: nil, not_after: nil}
      })

    {root, agent, cert}
  end

  # A federation-shaped commit: REAL Yjs update bytes (the default
  # namespace validator decodes them) and a stamped snapshot_parent
  # (required on :regular imports); parent_id nil ⇒ empty namespace ⇒
  # reference check passes for a doc the receiver doesn't have yet.
  defp agent_commit(agent, doc, cert) do
    update = Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema())

    Commit.new(doc, update, nil, %{
      kind: :regular,
      snapshot_parent: :crypto.hash(:sha256, "fed-epoch-" <> doc),
      capability_proof: cert.id
    })
    |> Signing.sign_commit(agent.priv, agent.signer)
  end

  describe "auth" do
    test "no token → 403", %{conn: conn} do
      assert conn |> get(~p"/federation/docs/some-doc/cids") |> response(403)
    end

    test "wrong token → 403", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer nope")
      assert conn |> get(~p"/federation/docs/some-doc/cids") |> response(403)
    end

    test "federation disabled (no peers configured) → 403 even with a token", %{conn: conn} do
      Application.delete_env(:commonplace_web, :federation_peers)
      assert conn |> authed() |> get(~p"/federation/docs/some-doc/cids") |> response(403)
    end
  end

  describe "GET /federation/docs/:uuid/cids" do
    test "lists the doc's commit CIDs base64-encoded", %{conn: conn} do
      doc = UUID.uuid4()
      c1 = CommitStore.create_commit(CommitStore, doc, <<1>>, nil)
      c2 = CommitStore.create_chained_commit(CommitStore, doc, <<2>>)

      resp = conn |> authed() |> get(~p"/federation/docs/#{doc}/cids") |> json_response(200)

      # The chain includes the auto-wired deterministic genesis commit —
      # a federation puller needs the full chain, so it IS served.
      genesis = Commit.genesis(doc)

      assert Enum.sort(resp["cids"]) ==
               Enum.sort([Base.encode64(c1.id), Base.encode64(c2.id), Base.encode64(genesis.id)])
    end
  end

  describe "POST /federation/docs/:uuid/commits" do
    test "serves envelopes for requested CIDs, omitting unknown ones", %{conn: conn} do
      doc = UUID.uuid4()
      c1 = CommitStore.create_commit(CommitStore, doc, <<1>>, nil)

      resp =
        conn
        |> authed()
        |> post(~p"/federation/docs/#{doc}/commits", %{
          "cids" => [Base.encode64(c1.id), Base.encode64(:crypto.hash(:sha256, "missing"))]
        })
        |> json_response(200)

      assert [envelope] = resp["envelopes"]
      assert {:ok, %{commit: commit}} = Envelope.decode(envelope)
      assert commit.id == c1.id
      assert resp["missing"] == [Base.encode64(:crypto.hash(:sha256, "missing"))]
    end
  end

  describe "cross-repo Slice-0 :read-cert gate (2026-07-11 spec, §1 Seam C — THE SECURITY SEAM)" do
    # A strict trust config with a pinned root — the requesting peer is
    # NOT itself pinned, so it must present a valid, audience-bound
    # `:read` cert or be refused.
    defp strict_root do
      root = ident("root-" <> UUID.uuid4())

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{root.uuid => Signing.encode_key(root.pub)}
      })

      root
    end

    defp identity_bound_peer(pub, opts \\ []) do
      %{
        name: Keyword.get(opts, :name, @peer),
        identity_uuid: Keyword.get(opts, :identity_uuid, @peer),
        pubkey: pub
      }
    end

    test "read-scope: A grants B a :read cert for doc X only — X is served, unscoped Y is refused",
         %{conn: conn} do
      root = strict_root()
      reader = ident("reader-" <> UUID.uuid4())

      Application.put_env(:commonplace_web, :federation_peers, %{
        @token => identity_bound_peer(reader.pub)
      })

      doc_x = UUID.uuid4()
      doc_y = UUID.uuid4()
      _ = CommitStore.create_commit(CommitStore, doc_x, <<1>>, nil)
      _ = CommitStore.create_commit(CommitStore, doc_y, <<2>>, nil)

      {:ok, cert} =
        Commonplace.Trust.Read.grant(root.ctx, doc_x, {reader.uuid, reader.pub},
          store: CommitStore
        )

      cert_b64 = Base.encode64(cert.id)

      # X: served (granted).
      resp_x =
        conn
        |> authed()
        |> get(~p"/federation/docs/#{doc_x}/cids?cert_cids=#{cert_b64}")
        |> json_response(200)

      assert resp_x["cids"] != []

      # Y: NOT covered by the cert — existence-hiding, identical shape to
      # a doc that was never configured/known at all (same 200, empty cids).
      resp_y =
        conn
        |> authed()
        |> get(~p"/federation/docs/#{doc_y}/cids?cert_cids=#{cert_b64}")
        |> json_response(200)

      assert resp_y == %{"cids" => []}

      # A genuinely-nonexistent doc gets the SAME shape — proving the
      # denial is indistinguishable from "doesn't exist".
      resp_nonexistent =
        conn
        |> authed()
        |> get(~p"/federation/docs/#{UUID.uuid4()}/cids?cert_cids=#{cert_b64}")
        |> json_response(200)

      assert resp_nonexistent == resp_y
    end

    test "existence-hiding: no cert presented at all on a gated doc → same empty shape, both endpoints",
         %{
           conn: conn
         } do
      _root = strict_root()
      reader = ident("reader-" <> UUID.uuid4())

      Application.put_env(:commonplace_web, :federation_peers, %{
        @token => identity_bound_peer(reader.pub)
      })

      doc = UUID.uuid4()
      c1 = CommitStore.create_commit(CommitStore, doc, <<1>>, nil)

      resp_cids = conn |> authed() |> get(~p"/federation/docs/#{doc}/cids") |> json_response(200)
      assert resp_cids == %{"cids" => []}

      resp_commits =
        conn
        |> authed()
        |> post(~p"/federation/docs/#{doc}/commits", %{"cids" => [Base.encode64(c1.id)]})
        |> json_response(200)

      assert resp_commits == %{"envelopes" => [], "missing" => [Base.encode64(c1.id)]}
    end

    test "audience anti-theft: a :read cert addressed to a DIFFERENT identity is refused", %{
      conn: conn
    } do
      root = strict_root()
      legit_reader = ident("legit-" <> UUID.uuid4())
      thief = ident("thief-" <> UUID.uuid4())

      doc = UUID.uuid4()
      _ = CommitStore.create_commit(CommitStore, doc, <<1>>, nil)

      # Cert minted for legit_reader's key...
      {:ok, cert} =
        Commonplace.Trust.Read.grant(root.ctx, doc, {legit_reader.uuid, legit_reader.pub},
          store: CommitStore
        )

      # ...but the CALLING peer authenticates as `thief` (a different
      # server-resolved identity/key) and merely PRESENTS the cert cid.
      Application.put_env(:commonplace_web, :federation_peers, %{
        @token => identity_bound_peer(thief.pub, identity_uuid: thief.uuid)
      })

      resp =
        conn
        |> authed()
        |> get(~p"/federation/docs/#{doc}/cids?cert_cids=#{Base.encode64(cert.id)}")
        |> json_response(200)

      assert resp == %{"cids" => []}
    end

    test "a pinned (trusted_identities) peer is served without needing a cert at all", %{
      conn: conn
    } do
      root = strict_root()
      # The peer itself is pinned as a trusted identity — the `reader_authorized?`
      # short-circuit, unchanged.
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{
          root.uuid => Signing.encode_key(root.pub),
          @peer => Signing.encode_key(root.pub)
        }
      })

      Application.put_env(:commonplace_web, :federation_peers, %{
        @token => identity_bound_peer(root.pub)
      })

      doc = UUID.uuid4()
      _ = CommitStore.create_commit(CommitStore, doc, <<1>>, nil)

      resp = conn |> authed() |> get(~p"/federation/docs/#{doc}/cids") |> json_response(200)
      assert resp["cids"] != []
    end
  end

  describe "POST /federation/import" do
    test "keystone over HTTP: delegated agent commit with inlined cert lands under strict",
         %{conn: conn} do
      {_root, agent, cert} = strict_delegation(["fed-doc-1"])
      commit = agent_commit(agent, "fed-doc-1", cert)
      envelope = Envelope.encode(commit, [cert])

      resp =
        conn
        |> authed()
        |> post(~p"/federation/import", %{"envelope" => envelope})
        |> json_response(200)

      assert resp["result"] == "ok"
      assert {:ok, _} = CommitStore.get_commit(CommitStore, commit.id)
    end

    test "out-of-scope commit is rejected, not stored", %{conn: conn} do
      {_root, agent, cert} = strict_delegation(["fed-doc-1"])
      commit = agent_commit(agent, "other-doc", cert)

      resp =
        conn
        |> authed()
        |> post(~p"/federation/import", %{"envelope" => Envelope.encode(commit, [cert])})
        |> json_response(200)

      assert resp["result"] == "rejected"
      assert resp["reason"] =~ "capability_insufficient"
      assert :none = CommitStore.get_commit(CommitStore, commit.id)
    end

    test "an envelope cert with a bad signature → 422, nothing stored", %{conn: conn} do
      {_root, agent, cert} = strict_delegation(["fed-doc-1"])
      forged_cert = %{cert | sig: :crypto.strong_rand_bytes(64)}
      commit = agent_commit(agent, "fed-doc-1", cert)

      conn
      |> authed()
      |> post(~p"/federation/import", %{"envelope" => Envelope.encode(commit, [forged_cert])})
      |> json_response(422)

      assert :none = CommitStore.get_capability(CommitStore, cert.id)
    end

    test "garbage envelope → 422", %{conn: conn} do
      conn
      |> authed()
      |> post(~p"/federation/import", %{"envelope" => "definitely not an envelope"})
      |> json_response(422)
    end

    test "deferral budget: over-budget peer gets 429 before touching the queue", %{conn: conn} do
      Application.put_env(:commonplace_web, :federation_deferral_budget, {1, 60_000})
      {_root, agent, cert} = strict_delegation(["fed-doc-1"])

      # Envelope WITHOUT the cert → strict gate defers on :awaiting_capability.
      c1 = agent_commit(agent, "fed-doc-1", cert)

      resp =
        conn
        |> authed()
        |> post(~p"/federation/import", %{"envelope" => Envelope.encode(c1, [])})
        |> json_response(200)

      assert resp["result"] == "deferred"

      # Second deferring import in the same window: budget exhausted → 429.
      update2 =
        Yelixer.Doc.new()
        |> Commonplace.Tree.Schema.add_file("f", UUID.uuid4())
        |> Yelixer.Encoding.encode_update()

      c2 =
        Commit.new("fed-doc-1", update2, nil, %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "fed-epoch-2"),
          capability_proof: cert.id
        })
        |> Signing.sign_commit(agent.priv, agent.signer)

      conn
      |> authed()
      |> post(~p"/federation/import", %{"envelope" => Envelope.encode(c2, [])})
      |> json_response(429)

      assert :none = CommitStore.get_commit(CommitStore, c2.id)
    end
  end
end
