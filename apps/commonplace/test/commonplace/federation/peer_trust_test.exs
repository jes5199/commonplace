defmodule Commonplace.Federation.PeerTrustTest do
  @moduledoc """
  Cross-repo Slice-0 (2026-07-11 spec, §1 Seam B / §5 "Verify") — B pins
  A's root by folding the federation peer's `root_pubkey` into
  `Trust.config/0`'s `trusted_identities`. `Trust.VerifyChain.verify_chain`
  + `verify_against_pinned` are UNCHANGED; this only proves the WIRING:
  a peer's root ends up as a real anchor, and the verifier still tells a
  genuinely-A-signed commit from a tampered/non-pinned one.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.Signing
  alias Commonplace.Federation.PeerTrust
  alias Commonplace.Store.Commit

  describe "merge_peer_anchors/2" do
    test "folds an identity-bound peer's root_pubkey into trusted_identities" do
      cfg = %{accept_unsigned: false, trusted_identities: %{}}

      peers = [
        %{name: "repo-a", root_pubkey: "encoded-a-root", base_url: "u", token: "t", docs: []}
      ]

      merged = PeerTrust.merge_peer_anchors(cfg, peers)

      assert merged.trusted_identities == %{"peer:repo-a" => "encoded-a-root"}
    end

    test "skips a peer with no root_pubkey (not identity-bound)" do
      cfg = %{accept_unsigned: false, trusted_identities: %{"already" => "k"}}
      peers = [%{name: "no-root-peer", base_url: "u", token: "t", docs: []}]

      merged = PeerTrust.merge_peer_anchors(cfg, peers)

      assert merged.trusted_identities == %{"already" => "k"}
    end
  end

  describe "the self-contained cross-root verifier, with a peer's root pinned via PeerTrust" do
    test "a commit signed by A's pinned root verifies; a tampered/non-pinned signer is rejected" do
      {a_root_pub, a_root_priv} = Signing.generate_keypair()
      {imposter_pub, imposter_priv} = Signing.generate_keypair()

      cfg =
        PeerTrust.merge_peer_anchors(
          %{accept_unsigned: false, trusted_identities: %{}},
          [
            %{
              name: "repo-a",
              root_pubkey: Signing.encode_key(a_root_pub),
              base_url: "u",
              token: "t",
              docs: []
            }
          ]
        )

      doc = "doc-1"

      commit =
        Commit.new(doc, <<1, 2, 3>>, nil, %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "e")
        })
        |> Signing.sign_commit(a_root_priv, Signing.signer_id("repo-a-root", a_root_pub))

      tampered =
        Commit.new(doc, <<1, 2, 3>>, nil, %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "e")
        })
        |> Signing.sign_commit(imposter_priv, Signing.signer_id("repo-a-root", imposter_pub))

      pinned_key = Signing.decode_key(cfg.trusted_identities["peer:repo-a"]) |> elem(1)

      assert Signing.verify_commit(commit, pinned_key) == :ok
      assert {:error, _} = Signing.verify_commit(tampered, pinned_key)
    end
  end
end
